#!/usr/bin/env bash

if [ "${PICOTOOLS_BOX_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_BOX_SH_LOADED=1

picotools_box_top() {
  local width="${1:-60}"
  printf '┌─'
  printf '─%.0s' $(seq 1 $((width - 2)))
  printf '┐\n'
}

picotools_box_bottom() {
  local width="${1:-60}"
  printf '└─'
  printf '─%.0s' $(seq 1 $((width - 2)))
  printf '┘\n'
}

picotools_box_separator() {
  local width="${1:-60}"
  printf '├─'
  printf '─%.0s' $(seq 1 $((width - 2)))
  printf '┤\n'
}

picotools_box_line() {
  local content="$1"
  local width="${2:-60}"
  local inner_width=$((width - 4))
  if [ ${#content} -ge "$inner_width" ]; then
    printf '│ %s │\n' "$content"
  else
    local padding=$((inner_width - ${#content}))
    printf '│ %s%*s│\n' "$content" "$padding" ""
  fi
}
