#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/progress.sh"

DOWNLOAD_TIMEOUT=45
MAX_PARALLEL=3
SCRIPT_TIMEOUT=480
MIN_FREQ_TO_KEEP=2
MAX_SEGMENTS_FOR_RARE=4

AD_KEYWORDS="ad|ads|advert|adserver|adtech|track|tracking|analytics|metric|pixel"
AD_KEYWORDS="$AD_KEYWORDS|doubleclick|googlesyndication|googleadservices|pubmatic|taboola|outbrain"
AD_KEYWORDS="$AD_KEYWORDS|teads|adform|criteo|openx|rubicon|appnexus|amazon-adsystem"
AD_KEYWORDS="$AD_KEYWORDS|scorecardresearch|quantserve|bluekai|krxd|lijit|popup|popunder"
AD_KEYWORDS="$AD_KEYWORDS|banner|sponsor|affiliate|marketing"

( sleep $SCRIPT_TIMEOUT; echo "❌ 超时"; pkill -P $$ 2>/dev/null || true ) &
TIMER_PID=$!
cleanup() { kill $TIMER_PID 2>/dev/null || true; rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT

echo "========================================"
echo "  AdBlock Rules Merger"
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

# ---- 下载（串行，不用 wait -n，避免死锁）----
extract_from_file() {
  local input="$1"
  [ -s "$input" ] || return
  grep -oP '^\s*@?@?\|\|[a-zA-Z0-9._-]+\^?' "$input" 2>/dev/null | sed 's/^@*||//; s/\^$//' || true
  grep -E '^\s*(0\.0\.0\.0|127\.0\.0\.1|::)\s+' "$input" 2>/dev/null | awk '{print $2}' || true
  grep -E '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$' "$input" 2>/dev/null || true
}
export -f extract_from_file

for i in "${!URLS[@]}"; do
  url="${URLS[$i]}"
  idx=$((i + 1))
  out="$TMPDIR/dl_${idx}.txt"
  if curl -sL --connect-timeout 10 --max-time $DOWNLOAD_TIMEOUT -o "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
    bytes=$(wc -c < "$out")
    extract_from_file "$out" > "$TMPDIR/ext_${idx}.txt" 2>/dev/null || true
    count=$(wc -l < "$TMPDIR/ext_${idx}.txt" 2>/dev/null || echo 0)
    progress_step "✅ ${bytes} bytes, ${count} 域名" "$url"
  else
    progress_step "❌ 跳过" "$url"
    rm -f "$out"
  fi
done

# ---- 合并所有提取结果 ----
progress_step "合并提取结果" ""
cat "$TMPDIR"/ext_*.txt 2>/dev/null > "$TMPDIR/all_domains.txt" || true
EXTRACTED=$(wc -l < "$TMPDIR/all_domains.txt" 2>/dev/null || echo 0)
echo "  提取域名总数（含重复）: $EXTRACTED"

# ---- 单次 awk 完成统计+筛选 ----
progress_step "统计 & 筛选（单次 awk）" ""

cat > "$TMPDIR/process.awk" << 'AWKEOF'
BEGIN {
  minfreq = 2; maxseg = 4
  kw = "ad|ads|advert|adserver|adtech|track|tracking|analytics|metric|pixel"
  kw = kw "|doubleclick|googlesyndication|googleadservices|pubmatic|taboola|outbrain"
  kw = kw "|teads|adform|criteo|openx|rubicon|appnexus|amazon-adsystem"
  kw = kw "|scorecardresearch|quantserve|bluekai|krxd|lijit|popup|popunder"
  kw = kw "|banner|sponsor|affiliate|marketing"
}
{
  d = ""
  if (match($0, /^\s*@?@?\|\|[a-zA-Z0-9._-]+\^?/)) {
    d = substr($0, RSTART, RLENGTH); gsub(/^@*||/, "", d); sub(/\^$/, "", d)
  }
  else if (match($0, /^\s*(0\.0\.0\.0|127\.0\.0\.1|::)\s+/)) {
    d = $2; if (d !~ /^[a-zA-Z0-9._-]+$/) d = ""
  }
  else if ($0 ~ /^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$/) {
    d = $0
  }
  if (d != "" && length(d) <= 63 && d !~ /^[\._-]|[\._-]$/) count[d]++
}
END {
  kept = 0; dropped = 0
  for (d in count) {
    c = count[d]
    segs = gsub(/\./, ".", d) + 1
    if (c >= minfreq) { print "||" d "^"; kept++; continue }
    if (segs > maxseg) { dropped++; continue }
    if (tolower(d) ~ kw) { print "||" d "^"; kept++; continue }
    if (segs <= 2) { print "||" d "^"; kept++; continue }
    dropped++
  }
  print "[STATS] kept=" kept " dropped=" dropped > "/dev/stderr"
}
AWKEOF

cat "$TMPDIR/all_domains.txt" | awk -f "$TMPDIR/process.awk" 2> "$TMPDIR/stats.txt" \
  | sort -u > "$DISTDIR/merged.txt.tmp" 2>/dev/null || true

FINAL=$(wc -l < "$DISTDIR/merged.txt.tmp" 2>/dev/null || echo 0)
echo "  $(cat "$TMPDIR/stats.txt" 2>/dev/null)"

# ---- 输出最终文件 ----
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
