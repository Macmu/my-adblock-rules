#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/progress.sh"

# ========== 配置 ==========
DOWNLOAD_TIMEOUT=45
RETRY_MAX=3
RETRY_DELAY=2
SCRIPT_TIMEOUT=480

# 噪音过滤开关：1=开启，0=关闭（建议开启）
ENABLE_NOISE_FILTER=1

# 是否在文件头部添加来源统计
ADD_SOURCE_STATS=1

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
echo "  AdBlock Rules Merger (简化版)"
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

TOTAL_EXTRACTED=0
declare -A SOURCE_COUNTS

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

        # 去除注释行
        sed -i '/^[[:space:]]*!/d' "$ext" 2>/dev/null || true

        sort -u -o "$ext" "$ext" 2>/dev/null || true
        count=$(wc -l < "$ext" 2>/dev/null || echo 0)
        TOTAL_EXTRACTED=$((TOTAL_EXTRACTED + count))
        SOURCE_COUNTS["$url"]=$count
        progress_step "✅ ${bytes} bytes, ${count} 条" "$url"
    else
        progress_step "❌ 跳过（重试 ${RETRY_MAX} 次失败）" "$url"
        rm -f "$out"
        SOURCE_COUNTS["$url"]=0
    fi
done

# ========== 合并与去重（仅保留合法性检查和噪音过滤） ==========
progress_step "合并去重" "共 ${TOTAL_EXTRACTED} 条原始规则"

# 使用 awk 进行最终过滤：仅做基本合法性检查和噪音清理
cat > "$TMPDIR/filter.awk" << 'AWKEOF'
{
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line == "") next

    # 判断是否为白名单（@@ 开头）
    is_whitelist = (line ~ /^@@/) ? 1 : 0

    # 提取基础键（||domain^）
    if (match(line, /\|\|[a-zA-Z0-9*._-]+\^/)) {
        key = substr(line, RSTART, RLENGTH)
        domain = substr(key, 3, length(key)-3)

        # ---- 域名合法性检查 ----
        # 必须包含至少一个点且顶级域名长度≥2
        if (domain !~ /^[a-zA-Z0-9*.-]+\.[a-zA-Z]{2,}$/) next
        # 长度限制（防止超长垃圾域名）
        if (length(domain) > 100) next
        # 必须包含至少一个字母（过滤纯数字域名）
        if (domain !~ /[a-zA-Z]/) next

        # ---- 噪音过滤（可选） ----
        if (noise_filter) {
            total_len = length(domain)
            letter_count = 0
            for (i=1; i<=total_len; i++) {
                ch = substr(domain, i, 1)
                if (ch ~ /[a-zA-Z]/) letter_count++
            }
            # 规则1：域名长度 >15 且字母占比 <20%
            if (total_len > 15 && letter_count / total_len < 0.2) next
            # 规则2：纯数字或数字+短横组合且长度 >10
            if (domain ~ /^[0-9\-]+$/ && total_len > 10) next
            # 规则3：连续相同字符超过4个
            if (domain ~ /(.)\1{4,}/) next
        }

        # 输出原始行（保留修饰符和 @@）
        print line
    }
}
AWKEOF

# 执行过滤并输出到临时文件
awk -v noise_filter="$ENABLE_NOISE_FILTER" -f "$TMPDIR/filter.awk" \
    "$TMPDIR"/ext_*.txt > "$TMPDIR/merged_raw.txt" 2>/dev/null || true

# 如果过滤后为空（极端情况），则回退为直接合并
if [ ! -s "$TMPDIR/merged_raw.txt" ]; then
    echo "⚠️ 过滤后无输出，回退到原始合并"
    cat "$TMPDIR"/ext_*.txt 2>/dev/null | sort -u > "$TMPDIR/merged_raw.txt"
fi

# 最终去重
sort -u -o "$TMPDIR/merged_raw.txt" "$TMPDIR/merged_raw.txt"

# 分离黑白名单（仅用于统计和输出注释）
grep -E '^@@' "$TMPDIR/merged_raw.txt" > "$TMPDIR/whitelist.txt" || true
grep -vE '^@@' "$TMPDIR/merged_raw.txt" > "$TMPDIR/blacklist.txt" || true

BLACK_COUNT=$(wc -l < "$TMPDIR/blacklist.txt" 2>/dev/null || echo 0)
WHITE_COUNT=$(wc -l < "$TMPDIR/whitelist.txt" 2>/dev/null || echo 0)
FINAL=$((BLACK_COUNT + WHITE_COUNT))

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
    if [ "$ADD_SOURCE_STATS" -eq 1 ]; then
        echo "# ==================== 来源统计 ===================="
        for url in "${!SOURCE_COUNTS[@]}"; do
            count="${SOURCE_COUNTS[$url]}"
            echo "#   $count 条 - $url"
        done
        echo "# ================================================="
        echo ""
    fi
    echo "# ==================== 黑名单 ===================="
    if [ -s "$TMPDIR/blacklist.txt" ]; then
        cat "$TMPDIR/blacklist.txt"
    fi
    echo ""
    if [ -s "$TMPDIR/whitelist.txt" ]; then
        echo "# ==================== 白名单 ===================="
        cat "$TMPDIR/whitelist.txt"
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
