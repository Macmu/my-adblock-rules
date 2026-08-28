#!/bin/bash
set -euo pipefail

# 加载进度模块
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

# 超时守护
( sleep $SCRIPT_TIMEOUT; echo "❌ 超时"; pkill -P $$ 2>/dev/null || true ) &
TIMER_PID=$!
cleanup() { kill $TIMER_PID 2>/dev/null || true; rm -rf "$TMPDIR" 2>/dev/null || true; progress_done 2>/dev/null || true; }
trap cleanup EXIT

echo "========================================"
echo "  AdBlock Rules Merger (GitHub Actions 版)"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

WORKDIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISTDIR="$WORKDIR/dist"
mkdir -p "$DISTDIR"
TMPDIR=$(mktemp -d)

extract_domains() {
  local input="$1"
  [ -s "$input" ] || return
  grep -oP '^\s*@?@?\|\|[a-zA-Z0-9._-]+\^?' "$input" 2>/dev/null | sed 's/^@*||//; s/\^$//' || true
  grep -E '^\s*(0\.0\.0\.0|127\.0\.0\.1|::)\s+' "$input" 2>/dev/null | awk '{print $2}' || true
  grep -E '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$' "$input" 2>/dev/null || true
}
export -f extract_domains

[ -f "$WORKDIR/sources.txt" ] || { echo "❌ 找不到 sources.txt"; exit 1; }
mapfile -t URLS < <(grep -vE '^\s*(#|$)' "$WORKDIR/sources.txt" | sed 's/\r//')
TOTAL_SOURCES=${#URLS[@]}
TOTAL_STEPS=$((TOTAL_SOURCES + 4))
progress_init $TOTAL_STEPS
progress_set 0 "初始化" "共 $TOTAL_SOURCES 个规则源"

# ---- 下载 ----
WORKER=0
for i in "${!URLS[@]}"; do
  url="${URLS[$i]}"
  idx=$((i + 1))
  (
    out="$TMPDIR/dl_${idx}_$$.txt"
    if curl -sL --connect-timeout 10 --max-time $DOWNLOAD_TIMEOUT -o "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
      bytes=$(wc -c < "$out")
      count=$(extract_domains "$out" | tee "$TMPDIR/ext_${idx}_$$.txt" | wc -l)
      [ -n "$PROG_FIFO" ] && echo "STEP:✅ ${bytes} bytes, ${count} 域名|$url" > "$PROG_FIFO" 2>/dev/null || true
    else
      [ -n "$PROG_FIFO" ] && echo "STEP:❌ 跳过|$url" > "$PROG_FIFO" 2>/dev/null || true
      rm -f "$out"
    fi
  ) &
  WORKER=$((WORKER + 1))
  if [ $WORKER -ge $MAX_PARALLEL ]; then wait -n 2>/dev/null || true; WORKER=$((WORKER - 1)); fi
done
wait

# ---- 合并 ----
progress_step "合并提取结果" ""
cat "$TMPDIR"/ext_*.txt 2>/dev/null > "$TMPDIR/all_domains.txt" || true
EXTRACTED=$(wc -l < "$TMPDIR/all_domains.txt" 2>/dev/null || echo 0)
progress_set $TOTAL_STEPS "合并完成" "提取域名总数（含重复）: $EXTRACTED"

# ---- 排序统计（限制内存，避免 GitHub runner OOM）----
progress_step "排序 & 统计频次" "限制内存 300M"
sort -S 300M --parallel=2 -o "$TMPDIR/sorted.txt" "$TMPDIR/all_domains.txt" 2>/dev/null || \
  sort -o "$TMPDIR/sorted.txt" "$TMPDIR/all_domains.txt" 2>/dev/null || true

awk '
{
  if ($0 == prev) { count++ }
  else {
    if (prev != "") print count "\t" prev
    prev = $0; count = 1
  }
}
END { if (prev != "") print count "\t" prev }
' "$TMPDIR/sorted.txt" 2>/dev/null | sort -t$'\t' -k1,1rn > "$TMPDIR/freq.txt" 2>/dev/null || true

TOTAL_UNIQUE=$(wc -l < "$TMPDIR/freq.txt" 2>/dev/null || echo 0)
progress_set $TOTAL_STEPS "统计完成" "唯一域名: $TOTAL_UNIQUE"

# ---- 筛选 ----
progress_step "智能筛选" "保留频次≥$MIN_FREQ_TO_KEEP + 广告关键词"
: > "$TMPDIR/final_domains.txt"
kept=0; dropped=0
while IFS=$'\t' read -r count domain; do
  [ -z "$domain" ] && continue
  if [ "$count" -ge "$MIN_FREQ_TO_KEEP" ] 2>/dev/null; then
    echo "$domain" >> "$TMPDIR/final_domains.txt"; kept=$((kept+1)); continue
  fi
  segs=$(echo "$domain" | awk -F. '{print NF}')
  if [ "$segs" -gt "$MAX_SEGMENTS_FOR_RARE" ] 2>/dev/null; then dropped=$((dropped+1)); continue; fi
  if [ "${#domain}" -gt 63 ] 2>/dev/null; then dropped=$((dropped+1)); continue; fi
  if echo "$domain" | grep -qE '^[0-9.]+$'; then dropped=$((dropped+1)); continue; fi
  if echo "$domain" | grep -qiE "$AD_KEYWORDS"; then
    echo "$domain" >> "$TMPDIR/final_domains.txt"; kept=$((kept+1)); continue
  fi
  if [ "$segs" -le 2 ] 2>/dev/null; then
    echo "$domain" >> "$TMPDIR/final_domains.txt"; kept=$((kept+1))
  else
    dropped=$((dropped+1))
  fi
done < "$TMPDIR/freq.txt"

sort -u "$TMPDIR/final_domains.txt" -o "$TMPDIR/final_domains.txt" 2>/dev/null || true
FINAL=$(wc -l < "$TMPDIR/final_domains.txt" 2>/dev/null || echo 0)

# ---- 输出 ----
progress_step "生成最终文件" "原始 $TOTAL_UNIQUE → 精简 $FINAL"
{
  echo "# ============================================"
  echo "#  AdGuardHome DNS 过滤规则（智能精简）"
  echo "#  生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "#  原始唯一域名: $TOTAL_UNIQUE"
  echo "#  精简后: $FINAL"
  echo "# ============================================"
  echo ""
  echo "# ==================== 黑名单 ===================="
  sed 's/^/||/' "$TMPDIR/final_domains.txt" | sed 's/$/^/'
} > "$DISTDIR/merged.txt"

progress_done
echo ""
echo "========================================"
echo "  ✅ 完成！"
echo "  kept=$kept dropped=$dropped"
echo "  原始唯一: $TOTAL_UNIQUE → 精简后: $FINAL"
echo "  输出: $DISTDIR/merged.txt"
echo "========================================"
head -10 "$DISTDIR/merged.txt"
exit 0
