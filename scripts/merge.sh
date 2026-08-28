#!/bin/bash
# ============================================================
#  AdBlock Rules Merger - 智能精简版
#  策略：按频次 + 启发式筛选，不硬卡数量
# ============================================================

set -euo pipefail

# ---- 配置 ----
DOWNLOAD_TIMEOUT=45          # 单个文件下载超时（秒）
MAX_PARALLEL=3               # 最大并发下载数
SCRIPT_TIMEOUT=420           # 脚本总超时 7 分钟
MIN_FREQ_TO_KEEP=2           # 出现次数 ≥ 此值的无条件保留
MAX_SEGMENTS_FOR_RARE=4      # 罕见域名最多允许几段（超过则丢弃）

# 广告/追踪关键词（命中则保留）
AD_KEYWORDS="ad|ads|advert|adserver|adtech|track|tracking|analytics|metric|pixel"
AD_KEYWORDS="$AD_KEYWORDS|doubleclick|googlesyndication|googleadservices|pubmatic|taboola|outbrain"
AD_KEYWORDS="$AD_KEYWORDS|teads|adform|criteo|openx|rubicon|appnexus|amazon-adsystem"
AD_KEYWORDS="$AD_KEYWORDS|scorecardresearch|quantserve|bluekai|krxd|lijit|media"
AD_KEYWORDS="$AD_KEYWORDS|popup|popunder|banner|sponsor|affiliate"

# ---- 超时保护 ----
(
  sleep $SCRIPT_TIMEOUT
  echo "❌ 脚本超过 ${SCRIPT_TIMEOUT}s，强制终止"
  pkill -P $$ 2>/dev/null || true
) &
TIMER_PID=$!

cleanup() { kill $TIMER_PID 2>/dev/null || true; rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---- 初始化 ----
echo "========================================"
echo "  AdBlock Rules Merger (智能精简版)"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
DISTDIR="$WORKDIR/dist"
mkdir -p "$DISTDIR"
TMPDIR=$(mktemp -d)

# ---- 下载函数 ----
download_url() {
  local idx="$1" url="$2" out="$TMPDIR/src_$idx.txt"
  echo -n "  [$idx] "
  if curl -sL --connect-timeout 10 --max-time $DOWNLOAD_TIMEOUT -o "$out" "$url" 2>/dev/null \
     && [ -s "$out" ]; then
    local bytes=$(wc -c < "$out")
    echo "✅ ${bytes} bytes"
    # 立即提取域名，减少内存占用
    extract_domains "$out" >> "$TMPDIR/extracted_all.txt" 2>/dev/null || true
  else
    echo "❌ 跳过"
  fi
}
export -f download_url
export TMPDIR AD_KEYWORDS

# 从单个规则文件提取域名（输出：一行一个域名）
extract_domains() {
  local input="$1"
  [ -f "$input" ] || return
  # 1) ||domain^ 或 @@||domain^
  grep -oP '^\s*@?@?\|\|[a-zA-Z0-9._-]+\^?' "$input" 2>/dev/null \
    | sed 's/^@*||//; s/\^$//'
  # 2) hosts: 0.0.0.0 / 127.0.0.1 / ::  domain
  grep -E '^\s*(0\.0\.0\.0|127\.0\.0\.1|::)\s+' "$input" 2>/dev/null | awk '{print $2}'
  # 3) 纯域名行
  grep -E '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$' "$input" 2>/dev/null
}
export -f extract_domains

# ---- 读取 sources.txt ----
[ -f "$WORKDIR/sources.txt" ] || { echo "❌ 找不到 sources.txt"; exit 1; }

: > "$TMPDIR/extracted_all.txt"

idx=0
while IFS= read -r line; do
  url=$(echo "$line" | tr -d '\r' | xargs)
  [ -z "$url" ] && continue
  case "$url" in \#*) continue ;; esac
  idx=$((idx + 1))
  echo "下载: [$idx] $url"
  download_url "$idx" "$url" &
  while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]; do wait -n 2>/dev/null || true; done
done < "$WORKDIR/sources.txt"
wait

EXTRACTED=$(wc -l < "$TMPDIR/extracted_all.txt" 2>/dev/null || echo 0)
echo ""
echo "========================================"
echo "  提取到的域名总数（含重复）: $EXTRACTED"
echo "========================================"

# ---- 统计频次 ----
echo "统计频次..."
# 输出格式：count<TAB>domain
sort "$TMPDIR/extracted_all.txt" | uniq -c | awk '{print $1"\t"$2}' \
  | sort -rn > "$TMPDIR/freq.txt" 2>/dev/null || true

TOTAL_UNIQUE=$(wc -l < "$TMPDIR/freq.txt" 2>/dev/null || echo 0)
echo "  去重后唯一域名: $TOTAL_UNIQUE"

# ---- 智能筛选 ----
echo "智能筛选..."

# 分三档：
#   1) 高频（>= MIN_FREQ_TO_KEEP）：无条件保留
#   2) 低频但含广告关键词：保留
#   3) 其他低频：丢弃
awk -v minfreq=$MIN_FREQ_TO_KEEP \
    -v maxseg=$MAX_SEGMENTS_FOR_RARE \
    -v keywords="$AD_KEYWORDS" '
BEGIN {
  kept = 0; dropped = 0;
}
{
  split($0, parts, "\t");
  count = parts[1];
  domain = parts[2];
  if (domain == "") next;

  # 档1：高频，无条件保留
  if (count >= minfreq) {
    kept++;
    print domain;
    next;
  }

  # 低频：段数检查
  dots = gsub(/\./, ".", domain);
  segments = dots + 1;
  if (segments > maxseg) { dropped++; next; }   # 太深的子域，丢弃

  # 低频：长度检查
  if (length(domain) > 63) { dropped++; next; }

  # 低频：排除以数字为主的（IP 之类）
  if (domain ~ /^[0-9.]+$/) { dropped++; next; }

  # 档2：含广告/追踪关键词 → 保留
  if (tolower(domain) ~ keywords) {
    kept++;
    print domain;
    next;
  }

  # 档3：二级域名（常见基础域名），保留
  if (segments <= 2) { kept++; print domain; next; }

  # 其他低频长尾：丢弃
  dropped++;
}
END {
  print "[STATS] kept=" kept " dropped=" dropped > "/dev/stderr";
}
' "$TMPDIR/freq.txt" 2> "$TMPDIR/stats.txt" \
  | sort -u > "$TMPDIR/final_domains.txt" || true

FINAL=$(wc -l < "$TMPDIR/final_domains.txt" 2>/dev/null || echo 0)
echo "  保留: $FINAL 条"
cat "$TMPDIR/stats.txt" 2>/dev/null || true

# ---- 输出最终文件 ----
{
  echo "# ============================================"
  echo "#  AdGuardHome DNS 过滤规则（智能精简）"
  echo "#  生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "#  原始唯一域名: $TOTAL_UNIQUE"
  echo "#  精简后: $FINAL"
  echo "#  策略: 频次≥${MIN_FREQ_TO_KEEP} 全保留 + 广告关键词 + 二级域名"
  echo "# ============================================"
  echo ""
  echo "# ==================== 黑名单 ===================="
  sed 's/^/||/' "$TMPDIR/final_domains.txt" | sed 's/$/^/'
} > "$DISTDIR/merged.txt"

echo ""
echo "========================================"
echo "  ✅ 完成！"
echo "  原始唯一域名: $TOTAL_UNIQUE"
echo "  精简后规则: $FINAL"
echo "  输出: $DISTDIR/merged.txt"
echo "========================================"

echo ""
echo "前 10 条样例:"
head -10 "$DISTDIR/merged.txt"

exit 0
