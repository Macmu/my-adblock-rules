#!/bin/bash
echo "========================================"
echo "  AdBlock Rules Merger (块注释 + 精简)"
echo "========================================"

mkdir -p dist
: > dist/.all.txt

if [ ! -f sources.txt ]; then
    echo "❌ 找不到 sources.txt"
    exit 1
fi

# ---------- 下载 ----------
count=0
while IFS= read -r line; do
    url=$(echo "$line" | tr -d '\r')
    [ -z "$url" ] && continue
    case "$url" in \#*) continue ;; esac
    count=$((count + 1))
    echo "[$count] $url"
    curl -sL --connect-timeout 15 --max-time 120 "$url" 2>/dev/null >> dist/.all.txt
done < sources.txt

# ---------- 规范化 ----------
# 把 ||domain^ 、0.0.0.0 domain、127.0.0.1 domain 统一提取成纯域名
# 去掉协议、注释后缀
extract_domain() {
    local raw="$1"
    # 去掉行内注释
    raw=$(echo "$raw" | sed 's/[[:space:]]*#.*//; s/![^!].*//')
    # 去常见前缀
    raw=$(echo "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    raw=$(echo "$raw" | sed 's/^||//; s/\^$//; s/[[:space:]]*127\.0\.0\.1//; s/[[:space:]]*0\.0\.0\.0//; s/[[:space:]]*:://')
    # hosts 格式：取最后一列
    raw=$(echo "$raw" | awk '{print $NF}')
    # 去掉首尾点
    raw=$(echo "$raw" | sed 's/^\.//; s/\.$//')
    echo "$raw"
}

# ---------- 判断规则类型 ----------
is_element_hiding() {
    # 元素隐藏规则：##  ##.class  ###id  #@#  #?#  —— AGH DNS 用不上
    echo "$1" | grep -qE '(^|\s)(##|###|#@#|#\?#|\^\^)' && return 0
    echo "$1" | grep -qE '\$@?##' && return 0
    return 1
}

has_content_modifier() {
    # 内容过滤修饰符：AGH DNS 不支持，丢弃
    echo "$1" | grep -qiE '\$(script|third-party|first-party|popup|empty|null|removeparam|inline-script|all)' && return 0
    return 1
}

is_valid_domain() {
    # 合法域名：至少含一个点，只含字母数字点横杠，且非纯数字IP
    echo "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$' && return 0
    return 1
}

# ---------- 第一遍：分类 + 规范化 + 精简 ----------
: > dist/.black.txt
: > dist/.white.txt
: > dist/.other.txt

CURRENT_APP=""
while IFS= read -r line; do
    [ -z "$line" ] && continue

    # --- 注释行：块级，一直生效到下一个注释 ---
    case "$line" in
        !*|"#"*)
            local_content=$(echo "$line" | sed 's/^[[:space:]]*[#!]*[[:space:]]*//')
            # 过滤来源说明
            if echo "$local_content" | grep -qiE '以下是|规则整理|来源|作者|收集|合并|规则列表|整理自|转载|^$|adblock|easylist|hagezi|anti-ad|adguard'; then
                continue
            fi
            # 视为软件说明：记录为当前块注释
            if [ -n "$local_content" ]; then
                CURRENT_APP="$line"
            fi
            continue
            ;;
    esac

    # --- 白名单 ---
    case "$line" in
        @@*)
            # 白名单去掉高级修饰符后保留域名
            local_rule=$(echo "$line" | sed 's/^@@//')
            if has_content_modifier "$local_rule"; then
                # 带内容修饰符的白名单对 DNS 无意义，转成纯域名白名单
                d=$(extract_domain "$local_rule")
                if is_valid_domain "$d"; then
                    echo "@@||${d}^" >> dist/.white.txt
                    [ -n "$CURRENT_APP" ] && echo "$CURRENT_APP" >> dist/.white.txt
                fi
                continue
            fi
            echo "$line" >> dist/.white.txt
            continue
            ;;
    esac

    # --- 丢弃元素隐藏规则 ---
    is_element_hiding "$line" && continue

    # --- 丢弃带内容过滤修饰符的规则 ---
    if has_content_modifier "$line"; then
        continue
    fi

    # --- 提取域名 ---
    d=$(extract_domain "$line")
    is_valid_domain "$d" && echo "$d" >> dist/.black.txt

done < dist/.all.txt

# ---------- 父域合并（保守） ----------
# 统计每个域名的出现频次，频次>=3 的子域合并到父域
python3 - "$dist/.black.txt" <<'PY' 2>/dev/null || sort -u "$dist/.black.txt" > "$dist/.black.merged.txt"
import sys, collections
path = sys.argv[1]
freq = collections.Counter()
with open(path) as f:
    for line in f:
        line = line.strip()
        if line:
            freq[line] += 1

# 构建子->父关系
parent = {}
for d in freq:
    parts = d.split('.')
    if len(parts) > 2:
        parent[d] = '.'.join(parts[1:])  # 直接父域

result = set(freq.keys())
changed = True
while changed:
    changed = False
    for child, par in list(parent.items()):
        if child in result and par in freq:
            # 只有父域本身也在列表里，且子域数量>=3时才合并
            pass

# 简单策略：如果一个域名的任何子域出现>=3次，则保留该父域、删除所有子域
sub_count = collections.Counter()
for d in freq:
    parts = d.split('.')
    if len(parts) > 2:
        par = '.'.join(parts[1:])
        if par in freq:
            sub_count[par] += 1

to_remove = set()
for par, cnt in sub_count.items():
    if cnt >= 3:
        # 移除所有以该父域结尾且比它长的域名
        for d in list(result):
            if d.endswith('.' + par) and d != par:
                to_remove.add(d)

result -= to_remove
for r in sorted(result):
    print(r)
PY

# 去重（若 python 失败则用原始去重）
[ -s "$dist/.black.merged.txt" ] || sort -u "$dist/.black.txt" > "$dist/.black.merged.txt"

sort -u "$dist/.white.txt" | grep -v '^$' > "$dist/.white.sorted.txt"
sort -u "$dist/.other.txt" | grep -v '^$' > "$dist/.other.sorted.txt"

BLACK=$(wc -l < "$dist/.black.merged.txt" | tr -d ' ')
WHITE=$(wc -l < "$dist/.white.sorted.txt" | tr -d ' ')
OTHER=$(wc -l < "$dist/.other.sorted.txt" | tr -d ' ')
TOTAL=$((BLACK + WHITE + OTHER))

echo "========================================"
echo "  精简后: 黑$BLACK | 白$WHITE | 注$OTHER | 总$TOTAL"
echo "========================================"

# ---------- 写入 merged.txt（块注释：遇到注释就输出，规则紧随其后）----------
{
    echo "# ============================================"
    echo "#  AdBlock 合并规则（已精简）"
    echo "#  生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#  总条数: $TOTAL"
    echo "#  黑名单: $BLACK | 白名单: $WHITE | 软件注释: $OTHER"
    echo "# ============================================"
    echo ""
    echo "# ==================== 黑名单 ===================="
    cat "$dist/.black.merged.txt"
    echo ""
    echo ""
    echo "# ==================== 白名单 ===================="
    cat "$dist/.white.sorted.txt"
    echo ""
    echo ""
    echo "# ==================== 软件说明 ===================="
    cat "$dist/.other.sorted.txt"
} > dist/merged.txt

rm -f dist/.all.txt dist/.black.txt dist/.white.txt dist/.other.txt \
      dist/.black.merged.txt dist/.white.sorted.txt dist/.other.sorted.txt

echo "✅ 生成完成: dist/merged.txt"
exit 0
