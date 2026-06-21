#!/usr/bin/env bash

if [ "${PICOTOOLS_BOX_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_BOX_SH_LOADED=1

picotools_box_use_unicode() {
  [ "${PICOTOOLS_BOX_ASCII:-0}" -ne 1 ] || return 1
  [ "${TERM:-}" != 'dumb' ] || return 1
  return 0
}

picotools_box_chars() {
  local part="$1"

  if picotools_box_use_unicode; then
    case "$part" in
    top_left) printf '%s' '┌' ;;
    top_right) printf '%s' '┐' ;;
    bottom_left) printf '%s' '└' ;;
    bottom_right) printf '%s' '┘' ;;
    separator_left) printf '%s' '├' ;;
    separator_right) printf '%s' '┤' ;;
    vertical) printf '%s' '│' ;;
    horizontal) printf '%s' '─' ;;
    esac
    return 0
  fi

  case "$part" in
  top_left | top_right | bottom_left | bottom_right | separator_left | separator_right)
    printf '%s' '+'
    ;;
  vertical)
    printf '%s' '|'
    ;;
  horizontal)
    printf '%s' '-'
    ;;
  esac
}

picotools_box_top() {
  local width="${1:-60}"
  local rule
  local horizontal

  printf -v rule '%*s' "$((width - 2))" ''
  horizontal=$(picotools_box_chars horizontal)
  rule=${rule// /$horizontal}
  printf '%s%s%s\n' "$(picotools_box_chars top_left)" "$rule" "$(picotools_box_chars top_right)"
}

picotools_box_bottom() {
  local width="${1:-60}"
  local rule
  local horizontal

  printf -v rule '%*s' "$((width - 2))" ''
  horizontal=$(picotools_box_chars horizontal)
  rule=${rule// /$horizontal}
  printf '%s%s%s\n' "$(picotools_box_chars bottom_left)" "$rule" "$(picotools_box_chars bottom_right)"
}

picotools_box_separator() {
  local width="${1:-60}"
  local rule
  local horizontal

  printf -v rule '%*s' "$((width - 2))" ''
  horizontal=$(picotools_box_chars horizontal)
  rule=${rule// /$horizontal}
  printf '%s%s%s\n' "$(picotools_box_chars separator_left)" "$rule" "$(picotools_box_chars separator_right)"
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
  local vertical

  if [ "${#content}" -gt "$inner_width" ]; then
    if [ "$inner_width" -gt 3 ]; then
      content="${content:0:$((inner_width - 3))}..."
    else
      content="${content:0:$inner_width}"
    fi
  fi

  padding=$((inner_width - ${#content}))
  vertical=$(picotools_box_chars vertical)
  printf '%s %s%*s %s\n' "$vertical" "$content" "$padding" "" "$vertical"
}

picotools_box_wrap_line() {
  local content="$1"
  local width="${2:-60}"
  local inner_width=$((width - 4))
  local vertical

  vertical=$(picotools_box_chars vertical)

  if [ "${#content}" -le "$inner_width" ]; then
    local padding=$((inner_width - ${#content}))
    printf '%s %s%*s %s\n' "$vertical" "$content" "$padding" "" "$vertical"
    return 0
  fi

  local remaining="$content"
  while [ "${#remaining}" -gt 0 ]; do
    local chunk="${remaining:0:$inner_width}"
    remaining="${remaining:$inner_width}"
    local padding=$((inner_width - ${#chunk}))
    printf '%s %s%*s %s\n' "$vertical" "$chunk" "$padding" "" "$vertical"
  done
}
