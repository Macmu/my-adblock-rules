#!/bin/bash
echo "========================================"
echo "  AdBlock Rules Merger (单文件分类版)"
echo "========================================"

mkdir -p dist
: > dist/.all.txt

if [ ! -f sources.txt ]; then
    echo "❌ 找不到 sources.txt"
    exit 1
fi

# ---------- 下载所有规则源 ----------
count=0
while IFS= read -r line; do
    url=$(echo "$line" | tr -d '\r')
    [ -z "$url" ] && continue
    case "$url" in \#*) continue ;; esac

    count=$((count + 1))
    echo "[$count] 下载: $url"

    curl -sL --connect-timeout 15 --max-time 120 "$url" 2>/dev/null >> dist/.all.txt
    echo "    done (exit=$?)"

done < sources.txt

# ---------- 分类到三个临时文件 ----------
: > dist/.black.txt
: > dist/.white.txt
: > dist/.other.txt

while IFS= read -r line; do
    # 跳过空行
    [ -z "$line" ] && continue

    # 注释行（! 或 # 开头）-> 其他
    case "$line" in
        !*|"#"*)
            echo "$line" >> dist/.other.txt
            continue
            ;;
    esac

    # 白名单（@@ 开头）-> 白名单
    case "$line" in
        @@*)
            echo "$line" >> dist/.white.txt
            continue
            ;;
    esac

    # 其余有效规则 -> 黑名单
    echo "$line" >> dist/.black.txt

done < dist/.all.txt

# ---------- 各自去重排序 ----------
sort -u dist/.black.txt | grep -v '^$' > dist/.black.sorted.txt
sort -u dist/.white.txt | grep -v '^$' > dist/.white.sorted.txt
sort -u dist/.other.txt | grep -v '^$' > dist/.other.sorted.txt

BLACK=$(wc -l < dist/.black.sorted.txt | tr -d ' ')
WHITE=$(wc -l < dist/.white.sorted.txt | tr -d ' ')
OTHER=$(wc -l < dist/.other.sorted.txt | tr -d ' ')
TOTAL=$((BLACK + WHITE + OTHER))

echo "========================================"
echo "  黑名单: $BLACK | 白名单: $WHITE | 其他: $OTHER | 总计: $TOTAL"
echo "========================================"

# ---------- 合并写入 dist/merged.txt ----------
{
    echo "# ============================================"
    echo "#  AdBlock 合并规则"
    echo "#  生成时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#  总条数: $TOTAL"
    echo "#  黑名单: $BLACK | 白名单: $WHITE | 其他: $OTHER"
    echo "# ============================================"
    echo ""

    echo "# ==================== 黑名单 (广告/跟踪/恶意) ===================="
    cat dist/.black.sorted.txt
    echo ""
    echo ""

    echo "# ==================== 白名单 (例外规则 @@) ===================="
    cat dist/.white.sorted.txt
    echo ""
    echo ""

    echo "# ==================== 其他 (注释/软件说明/无法分类) ===================="
    cat dist/.other.sorted.txt
} > dist/merged.txt

# ---------- 清理临时文件 ----------
rm -f dist/.all.txt dist/.black.txt dist/.white.txt dist/.other.txt \
      dist/.black.sorted.txt dist/.white.sorted.txt dist/.other.sorted.txt

echo "✅ 生成完成: dist/merged.txt"
exit 0
