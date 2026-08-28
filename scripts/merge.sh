#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/progress.sh"

# ==================== 配置 ====================
DOWNLOAD_TIMEOUT=45      # 单个源下载超时（秒）
RETRY_MAX=3              # 每个源重试次数
RETRY_DELAY=2            # 重试间隔（秒）
SCRIPT_TIMEOUT=480       # 总脚本超时（秒，8分钟）
MIN_FREQ_TO_KEEP=2       # 域名出现次数 >= 此值则保留
MAX_SEGMENTS_FOR_RARE=4  # 低频域名段数 <= 此值且含广告词也保留

# ==================== 超时保护 ====================
timeout_handler() {
    echo "❌ 脚本超时（已达 ${SCRIPT_TIMEOUT} 秒），终止执行" >&2
    exit 1
}
trap timeout_handler TERM
( sleep $SCRIPT_TIMEOUT; kill -TERM $$ 2>/dev/null ) &
TIMER_PID=$!

cleanup() {
    kill $TIMER_PID 2>/dev/null || true
    rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT

# ==================== 重试下载函数 ====================
retry_curl() {
    local url="$1"
    local out="$2"
    for ((r=1; r<=RETRY_MAX; r++)); do
        if curl -sL --connect-timeout 10 --max-time "$DOWNLOAD_TIMEOUT" -o "$out" "$url" 2>/dev/null; then
            if [ -s "$out" ]; then
                return 0
            else
                # 下载成功但文件为空，视为失败
                rm -f "$out"
            fi
        fi
        if [ $r -lt $RETRY_MAX ]; then
            sleep "$RETRY_DELAY"
        fi
    done
    return 1
}

# ==================== 主流程 ====================
echo "========================================"
echo "  AdBlock Rules Merger (增强版)"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

WORKDIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISTDIR="$WORKDIR/dist"
mkdir -p "$DISTDIR"
TMPDIR=$(mktemp -d)

[ -f "$WORKDIR/sources.txt" ] || { echo "❌ 找不到 sources.txt"; exit 1; }
mapfile -t URLS < <(grep -vE '^\s*(#|$)' "$WORKDIR/sources.txt" | sed 's/\r//')
TOTAL_SOURCES=${#URLS[@]}
TOTAL_STEPS=$((TOTAL_SOURCES + 2))
progress_init $TOTAL_STEPS
progress_step "初始化" "共 $TOTAL_SOURCES 个规则源"

# ==================== 下载与提取（串行，保留完整规则） ====================
for i in "${!URLS[@]}"; do
    url="${URLS[$i]}"
    idx=$((i + 1))
    out="$TMPDIR/dl_${idx}.txt"
    ext="$TMPDIR/ext_${idx}.txt"
    > "$ext"  # 初始化空文件

    if retry_curl "$url" "$out"; then
        bytes=$(wc -c < "$out")

        # ---- 提取 AdBlock 标准规则（保留 @@ 前缀和 $ 修饰符） ----
        # 匹配：@@?||domain^ 后面可跟 $修饰符，以空格或行尾结束
        grep -oP '^\s*(@@)?\|\|[a-zA-Z0-9*._-]+\^(\$[^\s]*)?' "$out" 2>/dev/null >> "$ext" || true

        # ---- 转换 Hosts 格式（0.0.0.0 domain 或 127.0.0.1 domain） ----
        grep -E '^\s*(0\.0\.0\.0|127\.0\.0\.1|::)\s+[a-zA-Z0-9._-]+' "$out" 2>/dev/null \
            | awk '{print "||" $2 "^"}' >> "$ext" || true

        count=$(wc -l < "$ext" 2>/dev/null || echo 0)
        progress_step "✅ ${bytes} bytes, ${count} 条" "$url"
    else
        progress_step "❌ 跳过（重试 ${RETRY_MAX} 次失败）" "$url"
        rm -f "$out"
    fi
done

# ==================== 智能合并与过滤（AWK 实现） ====================
progress_step "智能合并 & 过滤" "按频率/段数/关键词筛选"

# 构建关键词正则（供 AWK 使用）
KW_REGEX="ad|ads|advert|adserver|adtech|track|tracking|analytics|metric|pixel"
KW_REGEX="${KW_REGEX}|doubleclick|googlesyndication|googleadservices|pubmatic|taboola"
KW_REGEX="${KW_REGEX}|outbrain|teads|adform|criteo|openx|rubicon|appnexus"
KW_REGEX="${KW_REGEX}|amazon-adsystem|scorecardresearch|quantserve|bluekai|krxd"
KW_REGEX="${KW_REGEX}|lijit|popup|popunder|banner|sponsor|affiliate|marketing"

cat > "$TMPDIR/filter.awk" << 'AWKEOF'
BEGIN {
    minfreq = '"$MIN_FREQ_TO_KEEP"'
    maxseg  = '"$MAX_SEGMENTS_FOR_RARE"'
    kw_regex = "'"$KW_REGEX"'"
}

{
    # 当前行可能是：||domain^ 或 ||domain^$third-party 或 @@||domain^$document
    line = $0
    if (line == "") next

    # 提取基础键：去掉 @@（如果有），取 ||...^ 部分作为去重和计数依据
    if (match(line, /\|\|[a-zA-Z0-9*._-]+\^/)) {
        key = substr(line, RSTART, RLENGTH)   # 例如：||example.com^
        # 存储该键对应的所有完整规则行（用换行符连接）
        if (key in lines) {
            lines[key] = lines[key] "\n" line
        } else {
            lines[key] = line
        }
        count[key]++

        # 计算域名段数（去掉开头的 || 和结尾的 ^）
        domain = substr(key, 3, length(key) - 3)  # 例如：example.com
        segs = split(domain, arr, ".")
        seg_count[key] = segs
    }
}

END {
    kept = 0
    dropped = 0
    for (key in lines) {
        keep = 0
        c = count[key]
        segs = seg_count[key]

        # 条件1：出现频率 >= minfreq
        if (c >= minfreq) {
            keep = 1
        }
        # 条件2：域名段数 <= maxseg 且包含广告关键词
        else if (segs <= maxseg && tolower(key) ~ kw_regex) {
            keep = 1
        }
        # 条件3：域名段数 <= 2（极短域名，如 xx.com）
        else if (segs <= 2) {
            keep = 1
        }

        if (keep) {
            print lines[key]   # 输出该基础域名对应的所有完整规则
            kept++
        } else {
            dropped++
        }
    }
    print "[STATS] 保留=" kept " 丢弃=" dropped > "/dev/stderr"
}
AWKEOF

# 合并所有提取文件，送入 AWK 处理，最后 sort -u 全局去重
cat "$TMPDIR"/ext_*.txt 2>/dev/null \
    | awk -f "$TMPDIR/filter.awk" 2> "$TMPDIR/stats.txt" \
    | sort -u > "$DISTDIR/merged.txt.tmp" 2>/dev/null || true

FINAL=$(wc -l < "$DISTDIR/merged.txt.tmp" 2>/dev/null || echo 0)
echo "  $(cat "$TMPDIR/stats.txt" 2>/dev/null)"

# ==================== 输出最终文件 ====================
progress_step "生成最终文件" "规则数: $FINAL"

{
    echo "# ============================================"
    echo "#  AdGuardHome DNS 过滤规则"
    echo "#  生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#  规则总数: $FINAL"
    echo "# ============================================"
    echo ""
    echo "# ==================== 黑名单 ===================="
    cat "$DISTDIR/merged.txt.tmp"
} > "$DISTDIR/merged.txt"

rm -f "$DISTDIR/merged.txt.tmp" 2>/dev/null || true
progress_done

echo ""
echo "========================================"
echo "  ✅ 完成！规则数: $FINAL"
echo "  输出: $DISTDIR/merged.txt"
echo "========================================"
head -10 "$DISTDIR/merged.txt"
exit 0
