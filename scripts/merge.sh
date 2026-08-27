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
    echo "❌ 找不到 $SOURCES_FILE"
    exit 1
fi

COUNT=0
FAIL=0
while IFS= read -r url || [ -n "$url" ]; do
    # 跳过空行和注释
    [[ -z "$url" ]] && continue
    [[ "$url" =~ ^[[:space:]]*# ]] && continue

    ((COUNT++))
    echo "[$COUNT] 正在下载: $url"

    # 关键改动：curl 失败时记录但不退出
    if curl -sL --connect-timeout 15 --max-time 60 "$url" 2>/dev/null | \
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
        sed 's/^\.//' >> "$TMP_FILE"; then
        echo "  ✅ 成功"
    else
        ((FAIL++))
        echo "  ⚠️ 下载失败（跳过）"
    fi

done < "$SOURCES_FILE"

# 去重、排序、输出（即使 TMP 为空也不报错）
if [ -s "$TMP_FILE" ]; then
    sort -u "$TMP_FILE" | grep -v '^$' > "$OUTPUT_FILE"
    RULE_COUNT=$(wc -l < "$OUTPUT_FILE")
    echo "========================================"
    echo "  ✅ 合并完成！共 $RULE_COUNT 条规则（成功 $COUNT，失败 $FAIL）"
    echo "  输出: $OUTPUT_FILE"
    echo "========================================"
else
    echo "❌ 没有成功下载任何规则，请检查网络或 sources.txt 中的 URL"
    exit 1
fi

rm -f "$TMP_FILE"
