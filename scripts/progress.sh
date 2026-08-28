#!/bin/bash
PROG_FIFO=""
PROG_TOTAL=0
PROG_CURRENT=0
PROG_START=0

progress_init() {
  PROG_TOTAL=$1
  PROG_CURRENT=0
  PROG_START=$(date +%s)
  PROG_FIFO=$(mktemp -u /tmp/prog_XXXXXX)
  mkfifo "$PROG_FIFO" 2>/dev/null || true
  (
    while true; do
      read -r line 2>/dev/null < "$PROG_FIFO" || break
      case "$line" in
        STEP:*)
          data="${line#STEP:}"
          PROG_CURRENT=$((PROG_CURRENT + 1))
          status=$(echo "$data" | cut -d'|' -f1)
          detail=$(echo "$data" | cut -d'|' -f2-)
          _progress_render "$PROG_CURRENT" "$status" "$detail"
          ;;
        DONE) break ;;
      esac
    done
  ) &
}

_progress_render() {
  local cur="$1" status="$2" detail="$3"
  local cols=40
  local pct=0
  [ "$PROG_TOTAL" -gt 0 ] && pct=$((cur * 100 / PROG_TOTAL))
  local filled=$((pct * cols / 100))
  [ $filled -gt $cols ] && filled=$cols
  local bar=""
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  for ((i = filled; i < cols; i++)); do bar+="░"; done
  local elapsed=$(($(date +%s) - PROG_START))
  local min=$((elapsed / 60)) sec=$((elapsed % 60))
  printf "\r\033[K  [%3d%%] %s 步骤 %d/%d  %02d:%02d  %s\n         ↳ %s\n" \
    "$pct" "$bar" "$cur" "$PROG_TOTAL" "$min" "$sec" "$status" "$detail"
}

progress_step() {
  [ -n "$PROG_FIFO" ] && echo "STEP:$1|$2" > "$PROG_FIFO" 2>/dev/null || true
}

progress_done() {
  [ -n "$PROG_FIFO" ] && echo "DONE" > "$PROG_FIFO" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -f "$PROG_FIFO" 2>/dev/null || true
}
