#!/bin/bash
echo "========================================"
echo "  AdBlock Rules Merger"
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

# ---------- 判断注释是否保留 ----------
# 丢弃"来源说明"类，保留"软件说明"类
should_keep_comment() {
    local content
    content=$(echo "$1" | sed 's/^[[:space:]]*[#!]*[[:space:]]*//')
    [ -z "$content" ] && return 1
    # 包含这些词的视为来源说明，丢弃
    echo "$content" | grep -qiE '以下是|规则整理|来源|作者|收集|合并|规则列表|整理自|转载' && return 1
    return 0
}

# ---------- 分类 ----------
: > dist/.black.txt
: > dist/.white.txt
: > dist/.other.txt

while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        !*|"#"*)
            should_keep_comment "$line" && echo "$line" >> dist/.other.txt
            continue
            ;;
    esac
    case "$line" in
        @@*) echo "$line" >> dist/.white.txt ;;
        *)   echo "$line" >> dist/.black.txt ;;
    esac
done < dist/.all.txt

# ---------- 去重排序 ----------
sort -u dist/.black.txt | grep -v '^$' > dist/.black.sorted.txt
sort -u dist/.white.txt | grep -v '^$' > dist/.white.sorted.txt
sort -u dist/.other.txt | grep -v '^$' > dist/.other.sorted.txt

BLACK=$(wc -l < dist/.black.sorted.txt | tr -d ' ')
WHITE=$(wc -l < dist/.white.sorted.txt | tr -d ' ')
OTHER=$(wc -l < dist/.other.sorted.txt | tr -d ' ')
TOTAL=$((BLACK + WHITE + OTHER))

# ---------- 写入 merged.txt ----------
{
    echo "# ============================================"
    echo "#  AdBlock 合并规则"
    echo "#  生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#  总条数: $TOTAL"
    echo "#  黑名单: $BLACK | 白名单: $WHITE | 软件注释: $OTHER"
    echo "# ============================================"
    echo ""
    echo "# ==================== 黑名单 ===================="
    cat dist/.black.sorted.txt
    echo ""
    echo ""
    echo "# ==================== 白名单 ===================="
    cat dist/.white.sorted.txt
    echo ""
    echo ""
    echo "# ==================== 软件说明注释 ===================="
    cat dist/.other.sorted.txt
} > dist/merged.txt

# ---------- 清理 ----------
rm -f dist/.all.txt dist/.black.txt dist/.white.txt dist/.other.txt \
      dist/.black.sorted.txt dist/.white.sorted.txt dist/.other.sorted.txt

echo "✅ 完成！总计 $TOTAL 条 → dist/merged.txt"
exit 0
