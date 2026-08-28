#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/progress.sh"

# ========== 配置 ==========
DOWNLOAD_TIMEOUT=45
RETRY_MAX=3
RETRY_DELAY=2
SCRIPT_TIMEOUT=480
MIN_FREQ_TO_KEEP=2
MAX_SEGMENTS_FOR_RARE=4

# ========== 超时保护 ==========
timeout_handler() {
    echo "❌ 脚本超时（${SCRIPT_TIMEOUT}秒），终止" >&2
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

# ========== 重试下载 ==========
retry_curl() {
    local url="$1" out="$2"
    for ((r=1; r<=RETRY_MAX; r++)); do
        if curl -sL --connect-timeout 10 --max-time "$DOWNLOAD_TIMEOUT" -o "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
            return 0
        fi
        rm -f "$out"
        [ $r -lt $RETRY_MAX ] && sleep "$RETRY_DELAY"
    done
    return 1
}

# ========== 主流程 ==========
echo "========================================"
echo "  AdBlock Rules Merger (调试增强版)"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

WORKDIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISTDIR="$WORKDIR/dist"
mkdir -p "$DISTDIR"
TMPDIR=$(mktemp -d)
echo "临时目录: $TMPDIR"

[ -f "$WORKDIR/sources.txt" ] || { echo "❌ 找不到 sources.txt"; exit 1; }
mapfile -t URLS < <(grep -vE '^\s*(#|$)' "$WORKDIR/sources.txt" | sed 's/\r//')
TOTAL_SOURCES=${#URLS[@]}
TOTAL_STEPS=$((TOTAL_SOURCES + 2))
progress_init $TOTAL_STEPS
progress_step "初始化" "共 $TOTAL_SOURCES 个规则源"

# 用于累计提取的总行数
TOTAL_EXTRACTED=0

for i in "${!URLS[@]}"; do
    url="${URLS[$i]}"
    idx=$((i + 1))
    out="$TMPDIR/dl_${idx}.txt"
    ext="$TMPDIR/ext_${idx}.txt"
    > "$ext"

    if retry_curl "$url" "$out"; then
        bytes=$(wc -c < "$out")

        # ---------- 提取规则（兼容多种格式） ----------
        # 1. AdBlock 标准：||domain^ 可能带 @@ 和 $修饰符
        grep -E '^\s*(@@)?\|\|[a-zA-Z0-9*._-]+\^' "$out" 2>/dev/null >> "$ext" || true
        # 2. Hosts 格式
        grep -E '^\s*(0\.0\.0\.0|127\.0\.0\.1|::)\s+[a-zA-Z0-9._-]+' "$out" 2>/dev/null \
            | awk '{print "||" $2 "^"}' >> "$ext" || true
        # 3. dnsmasq 格式
        grep -E '^\s*address=/[^/]+/' "$out" 2>/dev/null \
            | sed -n 's/^address=\/\([^/]*\)\/.*/||\1^/p' >> "$ext" || true
        # 4. 纯域名行
        grep -E '^[a-zA-Z0-9*._-]+\.[a-zA-Z]{2,}$' "$out" 2>/dev/null \
            | sed 's/^/||/; s/$/^/' >> "$ext" || true
        # 5. 兜底
        grep -E '\|\|' "$out" 2>/dev/null | grep -E '\^' >> "$ext" || true

        # 初步清理：去除以 ! 开头的注释行（可能误提取）
        sed -i '/^[[:space:]]*!/d' "$ext" 2>/dev/null || true

        sort -u -o "$ext" "$ext" 2>/dev/null || true
        count=$(wc -l < "$ext" 2>/dev/null || echo 0)
        TOTAL_EXTRACTED=$((TOTAL_EXTRACTED + count))
        progress_step "✅ ${bytes} bytes, ${count} 条" "$url"
    else
        progress_step "❌ 跳过（重试 ${RETRY_MAX} 次失败）" "$url"
        rm -f "$out"
    fi
done

# ========== 智能过滤（AWK） ==========
progress_step "智能过滤" "共 ${TOTAL_EXTRACTED} 条原始规则"

# 构建关键词正则
KW_REGEX="ad|ads|advert|adserver|adtech|track|tracking|analytics|metric|pixel"
KW_REGEX="${KW_REGEX}|doubleclick|googlesyndication|googleadservices|pubmatic|taboola"
KW_REGEX="${KW_REGEX}|outbrain|teads|adform|criteo|openx|rubicon|appnexus"
KW_REGEX="${KW_REGEX}|amazon-adsystem|scorecardresearch|quantserve|bluekai|krxd"
KW_REGEX="${KW_REGEX}|lijit|popup|popunder|banner|sponsor|affiliate|marketing"

# 编写 AWK 脚本（区分黑白名单，增加合法性检查）
cat > "$TMPDIR/filter.awk" << 'AWKEOF'
{
    line = $0
    sub(/^[ \t]+/, "", line)   # 去除前导空格
    if (line == "") next

    # 判断是否为白名单（@@ 开头）
    is_whitelist = (line ~ /^@@/) ? 1 : 0

    # 提取基础键（||domain^）
    if (match(line, /\|\|[a-zA-Z0-9*._-]+\^/)) {
        key = substr(line, RSTART, RLENGTH)
        domain = substr(key, 3, length(key)-3)   # 去掉 || 和 ^

        # ---- 域名合法性检查 ----
        # 必须包含至少一个点且顶级域名长度≥2
        if (domain !~ /^[a-zA-Z0-9*.-]+\.[a-zA-Z]{2,}$/) next
        # 长度限制（防止超长垃圾域名）
        if (length(domain) > 100) next
        # 必须包含至少一个字母（过滤纯数字域名）
        if (domain !~ /[a-zA-Z]/) next

        # 根据黑白名单分别存储
        if (is_whitelist) {
            if (key in w_lines) {
                w_lines[key] = w_lines[key] "\n" line
            } else {
                w_lines[key] = line
            }
            w_count[key]++
        } else {
            if (key in b_lines) {
                b_lines[key] = b_lines[key] "\n" line
            } else {
                b_lines[key] = line
            }
            b_count[key]++
        }

        # 记录域名段数（用于过滤）
        segs = split(domain, arr, ".")
        if (is_whitelist) {
            w_seg_count[key] = segs
        } else {
            b_seg_count[key] = segs
        }
    }
}

END {
    # 处理黑名单
    kept_black = 0
    dropped_black = 0
    for (key in b_lines) {
        keep = 0
        c = b_count[key]
        segs = b_seg_count[key]

        if (c >= minfreq) keep = 1
        else if (segs <= maxseg && tolower(key) ~ kw_regex) keep = 1
        else if (segs <= 2) keep = 1

        if (keep) {
            print b_lines[key] > blacklist_file
            kept_black++
        } else {
            dropped_black++
        }
    }

    # 处理白名单（保留全部合法规则，不应用频率/关键词过滤）
    kept_white = 0
    for (key in w_lines) {
        print w_lines[key] > whitelist_file
        kept_white++
    }

    # 输出统计信息到 stderr
    printf "[STATS] 黑名单保留=%d 丢弃=%d，白名单保留=%d\n", kept_black, dropped_black, kept_white > "/dev/stderr"
}
AWKEOF

# 定义输出文件路径
BLACKLIST_FILE="$TMPDIR/blacklist.txt"
WHITELIST_FILE="$TMPDIR/whitelist.txt"
> "$BLACKLIST_FILE"
> "$WHITELIST_FILE"

# 执行 AWK 过滤
awk -v minfreq="$MIN_FREQ_TO_KEEP" \
    -v maxseg="$MAX_SEGMENTS_FOR_RARE" \
    -v kw_regex="$KW_REGEX" \
    -v blacklist_file="$BLACKLIST_FILE" \
    -v whitelist_file="$WHITELIST_FILE" \
    -f "$TMPDIR/filter.awk" \
    "$TMPDIR"/ext_*.txt 2> "$TMPDIR/stats.txt"
AWK_EXIT=$?

# 容错：AWK 失败或黑白名单均为空时回退到简单合并
if [ $AWK_EXIT -ne 0 ] || { [ ! -s "$BLACKLIST_FILE" ] && [ ! -s "$WHITELIST_FILE" ]; }; then
    echo "⚠️ AWK 过滤失败或无输出，回退到 sort -u 合并"
    cat "$TMPDIR"/ext_*.txt 2>/dev/null | sort -u > "$BLACKLIST_FILE"
    > "$WHITELIST_FILE"  # 清空白名单
    echo "[STATS] 回退模式：所有规则均视为黑名单，保留=$(wc -l < "$BLACKLIST_FILE")" > "$TMPDIR/stats.txt"
fi

# 分别去重
sort -u -o "$BLACKLIST_FILE" "$BLACKLIST_FILE" 2>/dev/null || true
sort -u -o "$WHITELIST_FILE" "$WHITELIST_FILE" 2>/dev/null || true

# 统计行数
BLACK_COUNT=$(wc -l < "$BLACKLIST_FILE" 2>/dev/null || echo 0)
WHITE_COUNT=$(wc -l < "$WHITELIST_FILE" 2>/dev/null || echo 0)
FINAL=$((BLACK_COUNT + WHITE_COUNT))

# 显示统计信息
echo "  $(cat "$TMPDIR/stats.txt" 2>/dev/null)"
echo "  最终输出：黑名单 $BLACK_COUNT 条，白名单 $WHITE_COUNT 条，总计 $FINAL 条"

# ========== 输出最终文件 ==========
progress_step "生成最终文件" "黑名单: $BLACK_COUNT，白名单: $WHITE_COUNT，总计: $FINAL"

{
    echo "# ============================================"
    echo "#  AdGuardHome DNS 过滤规则"
    echo "#  生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#  规则总数: $FINAL"
    echo "# ============================================"
    echo ""
    echo "# ==================== 黑名单 ===================="
    if [ -s "$BLACKLIST_FILE" ]; then
        cat "$BLACKLIST_FILE"
    fi
    echo ""
    if [ -s "$WHITELIST_FILE" ]; then
        echo "# ==================== 白名单 ===================="
        cat "$WHITELIST_FILE"
    fi
} > "$DISTDIR/merged.txt"

progress_done

echo ""
echo "========================================"
echo "  ✅ 完成！规则总数: $FINAL"
echo "  输出: $DISTDIR/merged.txt"
echo "========================================"
head -10 "$DISTDIR/merged.txt"
exit 0
