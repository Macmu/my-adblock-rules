
#!/bin/bash
set -e

echo "========================================"
echo "  AdBlock Rules Merger"
echo "========================================"

# 输出目录
OUTPUT_DIR="dist"
OUTPUT_FILE="$OUTPUT_DIR/merged.txt"
TMP_FILE="$OUTPUT_DIR/.tmp_merged.txt"

mkdir -p "$OUTPUT_DIR"
> "$TMP_FILE"

# 读取 sources.txt
SOURCES_FILE="sources.txt"
if [ ! -f "$SOURCES_FILE" ]; then
    echo "❌ 找不到 sources.txt"
    exit 1
fi

COUNT=0
while IFS= read -r url || [ -n "$url" ]; do
    # 跳过空行和注释
    [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]] && continue
    
    ((COUNT++))
    echo "[$COUNT] 正在下载: $url"
    
    # 下载并清洗：
    # - 去掉注释行（# 或 ! 开头）
    # - 去掉空行
    # - 处理 Adblock 格式 ||domain^ → domain
    # - 处理 hosts 格式 127.0.0.1/0.0.0.0 domain → domain
    # - 去掉行内注释
    curl -sL --connect-timeout 15 --max-time 60 "$url" 2>/dev/null | \
    sed -e 's/[[:space:]]*#.*//' \
        -e 's/!.*//' \
        -e 's/||//' \
        -e 's/\^//' \
        -e 's/127\.0\.0\.1[[:space:]]*//' \
        -e 's/0\.0\.0\.0[[:space:]]*//' \
        -e 's/::[[:space:]]*//' | \
    awk 'NF {print $NF}' | \
    grep -vE '^\s*$' | \
    grep -vE '^(\.|/|\[|\*)' | \
    sed 's/^\.//' >> "$TMP_FILE" || echo "  ⚠️ 下载失败，跳过"
    
done < "$SOURCES_FILE"

# 去重、排序、输出
sort -u "$TMP_FILE" | grep -v '^$' > "$OUTPUT_FILE"
rm -f "$TMP_FILE"

RULE_COUNT=$(wc -l < "$OUTPUT_FILE")
echo "========================================"
echo "  ✅ 合并完成！共 $RULE_COUNT 条规则"
echo "  输出: $OUTPUT_FILE"
echo "========================================"
