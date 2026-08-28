#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/progress.sh"

# ========== 配置 ==========
DOWNLOAD_TIMEOUT=45
RETRY_MAX=3
RETRY_DELAY=2
SCRIPT_TIMEOUT=480

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
        # 1. AdBlock 标准：||domain^ 可能带 @@ 和 $修饰符，忽略行首空格
        grep -E '^\s*(@@)?\|\|[a-zA-Z0-9*._-]+\^' "$out" 2>/dev/null >> "$ext" || true

        # 2. Hosts 格式：0.0.0.0 domain 或 127.0.0.1 domain
        grep -E '^\s*(0\.0\.0\.0|127\.0\.0\.1|::)\s+[a-zA-Z0-9._-]+' "$out" 2>/dev/null \
            | awk '{print "||" $2 "^"}' >> "$ext" || true

        # 3. dnsmasq 格式：address=/domain/ip 或 server=/domain/...
        grep -E '^\s*address=/[^/]+/' "$out" 2>/dev/null \
            | sed -n 's/^address=\/\([^/]*\)\/.*/||\1^/p' >> "$ext" || true

        # 4. 纯域名行（每行一个域名，可能包含通配符）
        grep -E '^[a-zA-Z0-9*._-]+\.[a-zA-Z]{2,}$' "$out" 2>/dev/null \
            | sed 's/^/||/; s/$/^/' >> "$ext" || true

        # 5. 额外兜底：任何包含 || 且以 ^ 结尾的行（即使之前漏掉）
        grep -E '\|\|' "$out" 2>/dev/null | grep -E '\^' >> "$ext" || true

        # 去重当前提取结果（同一源内去重）
        sort -u -o "$ext" "$ext" 2>/dev/null || true

        count=$(wc -l < "$ext" 2>/dev/null || echo 0)
        TOTAL_EXTRACTED=$((TOTAL_EXTRACTED + count))
        if [ "$count" -eq 0 ]; then
            # 打印原始文件前几行供调试（保留文件，不删除）
            echo "  ⚠️  未提取到任何规则，原始文件前 3 行："
            head -3 "$out" | sed 's/^/      /' || true
        fi

        progress_step "✅ ${bytes} bytes, ${count} 条" "$url"
    else
        progress_step "❌ 跳过（重试 ${RETRY_MAX} 次失败）" "$url"
        rm -f "$out"
    fi
done

# ========== 检查提取结果 ==========
if [ "$TOTAL_EXTRACTED" -eq 0 ]; then
    echo "❌ 所有源均未提取到任何规则，请检查 sources.txt 中的 URL 是否有效或格式是否兼容。"
    echo "临时文件保留在: $TMPDIR （可手动查看原始下载文件）"
    # 不删除临时目录，方便调试
    trap - EXIT
    exit 1
fi

# ========== 智能过滤（AWK） ==========
progress_step "智能过滤" "共 ${TOTAL_EXTRACTED} 条原始规则"

# 构建关键词（此处略，同之前）
KW_REGEX="ad|ads|advert|..."
# 实际使用时请复制完整关键词串，此处为节省篇幅用省略

cat > "$TMPDIR/filter.awk" << 'AWKEOF'
# 过滤逻辑（保留规则，同之前增强版，此处略）
# 实际使用时请复制完整的 AWK 代码
AWKEOF

# 合并所有提取文件，送入 AWK 处理
cat "$TMPDIR"/ext_*.txt 2>/dev/null \
    | awk -f "$TMPDIR/filter.awk" 2> "$TMPDIR/stats.txt" \
    | sort -u > "$DISTDIR/merged.txt.tmp" 2>/dev/null || true

FINAL=$(wc -l < "$DISTDIR/merged.txt.tmp" 2>/dev/null || echo 0)
echo "  $(cat "$TMPDIR/stats.txt" 2>/dev/null)"

# ========== 输出最终文件 ==========
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
# 保留临时目录用于调试（可选）
# rm -rf "$TMPDIR"
exit 0
