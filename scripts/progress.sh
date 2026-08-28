#!/bin/bash
# 简单进度：直接打印，不用 fifo/后台进程
PROG_TOTAL=0
PROG_CURRENT=0
PROG_START=0

progress_init() {
  PROG_TOTAL=$1
  PROG_CURRENT=0
  PROG_START=$(date +%s)
}

progress_step() {
  PROG_CURRENT=$((PROG_CURRENT + 1))
  local status="$1"
  local detail="$2"
  local cols=40
  local pct=0
  [ "$PROG_TOTAL" -gt 0 ] && pct=$((PROG_CURRENT * 100 / PROG_TOTAL))
  local filled=$((pct * cols / 100))
  [ $filled -gt $cols ] && filled=$cols
  local bar=""
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  for ((i = filled; i < cols; i++)); do bar+="░"; done
  local elapsed=$(($(date +%s) - PROG_START))
  local min=$((elapsed / 60)) sec=$((elapsed % 60))
  printf "  [%3d%%] %s 步骤 %d/%d  %02d:%02d  %s\n         ↳ %s\n" \
    "$pct" "$bar" "$PROG_CURRENT" "$PROG_TOTAL" "$min" "$sec" "$status" "$detail"
}

progress_done() {
  local elapsed=$(($(date +%s) - PROG_START))
  local min=$((elapsed / 60)) sec=$((elapsed % 60))
  printf "✅ 完成，耗时 %02d:%02d\n" "$min" "$sec"
}
