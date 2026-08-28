#!/bin/bash
# ============================================================
#  进度显示模块 (progress.sh)
#  用法：
#    source scripts/progress.sh
#    progress_init <总步骤数>
#    progress_set <当前步骤> <状态> [详情]
#    progress_done
# ============================================================

PROG_FIFO=""
PROG_TOTAL=0
PROG_CURRENT=0
PROG_START=0

progress_init() {
  PROG_TOTAL=$1
  PROG_CURRENT=0
  PROG_START=$(date +%s)

  # 创建命名管道
  PROG_FIFO=$(mktemp -u /tmp/prog_XXXXXX)
  mkfifo "$PROG_FIFO" 2>/dev/null || true

  # 后台监控进程：读取管道，刷新进度条
  (
    while true; do
      read -r line 2>/dev/null < "$PROG_FIFO" || break
      case "$line" in
        INIT:*) PROG_TOTAL="${line#INIT:}" ;;
        SET:*)
          data="${line#SET:}"
          PROG_CURRENT=$(echo "$data" | cut -d'|' -f1)
          status=$(echo "$data" | cut -d'|' -f2)
          detail=$(echo "$data" | cut -d'|' -f3-)
          _progress_render "$PROG_CURRENT" "$status" "$detail"
          ;;
        STEP:*)
          data="${line#STEP:}"
          PROG_CURRENT=$((PROG_CURRENT + 1))
          _progress_render "$PROG_CURRENT" "$(echo "$data" | cut -d'|' -f1)" "$(echo "$data" | cut -d'|' -f2-)"
          ;;
        DONE) break ;;
      esac
    done
  ) &
  PROG_MONITOR_PID=$!
}

# 内部：渲染进度条
_progress_render() {
  local cur="$1"
  local status="$2"
  local detail="$3"
  local cols=40
  [ -z "$cols" ] && cols=40

  local pct=0
  [ "$PROG_TOTAL" -gt 0 ] && pct=$((cur * 100 / PROG_TOTAL))

  local filled=$((pct * cols / 100))
  [ $filled -gt $cols ] && filled=$cols
  local bar=""
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  for ((i = filled; i < cols; i++)); do bar+="░"; done

  local elapsed=$(($(date +%s) - PROG_START))
  local min=$((elapsed / 60))
  local sec=$((elapsed % 60))

  # 用 \r 覆盖当前行，实现"原地刷新"
  printf "\r\033[K  [%3d%%] %s 步骤 %d/%d  %02d:%02d  %s" \
    "$pct" "$bar" "$cur" "$PROG_TOTAL" "$min" "$sec" "$status"
  [ -n "$detail" ] && printf "\n         ↳ %s" "$detail"
  printf "\n"
}

progress_set() {
  [ -n "$PROG_FIFO" ] && echo "SET:$1|$2|$3" > "$PROG_FIFO" 2>/dev/null || true
}

progress_step() {
  [ -n "$PROG_FIFO" ] && echo "STEP:$1|$2" > "$PROG_FIFO" 2>/dev/null || true
}

progress_done() {
  [ -n "$PROG_FIFO" ] && echo "DONE" > "$PROG_FIFO" 2>/dev/null || true
  wait $PROG_MONITOR_PID 2>/dev/null || true
  rm -f "$PROG_FIFO" 2>/dev/null || true
  local elapsed=$(($(date +%s) - PROG_START))
  local min=$((elapsed / 60))
  local sec=$((elapsed % 60))
  printf "\n✅ 全部完成，耗时 %02d:%02d\n" "$min" "$sec"
}
