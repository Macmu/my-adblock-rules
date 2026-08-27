#!/bin/bash
echo "========================================"
echo "  AdBlock Rules Merger (simple)"
echo "========================================"

mkdir -p dist
: > dist/.tmp.txt

if [ ! -f sources.txt ]; then
    echo "❌ 找不到 sources.txt"
    exit 1
fi

count=0
while IFS= read -r line; do
    url=$(echo "$line" | tr -d '\r')
    [ -z "$url" ] && continue
    case "$url" in \#*) continue ;; esac

    count=$((count + 1))
    echo "[$count] $url"

    # 极简清洗：只做最安全的操作
    curl -sL --connect-timeout 15 --max-time 120 "$url" 2>/dev/null \
      | sed 's/#.*//; s/!.*//; s/||//g; s/\^//g' \
      | sed 's/[[:space:]]*127\.0\.0\.1[[:space:]]*//g' \
      | sed 's/[[:space:]]*0\.0\.0\.0[[:space:]]*//g' \
      | awk 'NF {print $NF}' \
      | grep -v '^\s*$' \
      >> dist/.tmp.txt

    echo "    done (exit=$?)"

done < sources.txt

echo "=== 下载的原始行数 ==="
wc -l dist/.tmp.txt

# 去重排序
sort -u dist/.tmp.txt | grep -v '^$' > dist/merged.txt
rm -f dist/.tmp.txt

lines=$(wc -l < dist/merged.txt | tr -d ' ')
echo "=== 去重后规则数: $lines ==="

if [ "$lines" -gt 0 ]; then
    echo "✅ 成功"
    exit 0
else
    echo "❌ 没有下载到任何规则"
    exit 1
fi
