#!/usr/bin/env bash

if [ "${PICOTOOLS_BOX_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_BOX_SH_LOADED=1

picotools_box_top() {
  local width="${1:-60}"
  local rule

  printf -v rule '%*s' "$((width - 2))" ''
  rule=${rule// /─}
  printf '┌%s┐\n' "$rule"
}

picotools_box_bottom() {
  local width="${1:-60}"
  local rule

  printf -v rule '%*s' "$((width - 2))" ''
  rule=${rule// /─}
  printf '└%s┘\n' "$rule"
}

picotools_box_separator() {
  local width="${1:-60}"
  local rule

  printf -v rule '%*s' "$((width - 2))" ''
  rule=${rule// /─}
  printf '├%s┤\n' "$rule"
}

picotools_box_width_for_lines() {
  local min_width="${1:-0}"
  local line max_content_width=0

  shift || true
  for line in "$@"; do
    if [ "${#line}" -gt "$max_content_width" ]; then
      max_content_width=${#line}
    fi
  done

  max_content_width=$((max_content_width + 4))
  if [ "$max_content_width" -lt "$min_width" ]; then
    printf '%s\n' "$min_width"
    return 0
  fi

  printf '%s\n' "$max_content_width"
}

picotools_box_line() {
  local content="$1"
  local width="${2:-60}"
  local inner_width=$((width - 4))
  local padding

  if [ "${#content}" -gt "$inner_width" ]; then
    if [ "$inner_width" -gt 3 ]; then
      content="${content:0:$((inner_width - 3))}..."
    else
      content="${content:0:$inner_width}"
    fi
  fi

  padding=$((inner_width - ${#content}))
  printf '│ %s%*s │\n' "$content" "$padding" ""
}
