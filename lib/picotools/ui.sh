#!/usr/bin/env bash

if [ "${PICOTOOLS_UI_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_UI_SH_LOADED=1

picotools_ui_stderr_is_pretty() {
  [ -t 2 ] || return 1
  [ "${TERM:-}" != 'dumb' ] || return 1
}

picotools_ui_color() {
  local code="$1"

  if picotools_ui_stderr_is_pretty; then
    printf '\033[%sm' "$code"
  fi
}

picotools_ui_reset() {
  picotools_ui_color '0'
}

picotools_ui_bold() {
  picotools_ui_color '1'
}

picotools_ui_dim() {
  picotools_ui_color '2'
}

picotools_ui_blue() {
  picotools_ui_color '34'
}

picotools_ui_green() {
  picotools_ui_color '32'
}

picotools_ui_yellow() {
  picotools_ui_color '33'
}

picotools_ui_cyan() {
  picotools_ui_color '36'
}

picotools_ui_section() {
  local title="$1"

  if ! picotools_ui_stderr_is_pretty; then
    return 0
  fi

  printf '\n%s%s== %s ==%s\n' "$(picotools_ui_bold)" "$(picotools_ui_cyan)" "$title" "$(picotools_ui_reset)" >&2
}

picotools_ui_step() {
  local current="$1"
  local total="$2"
  local title="$3"

  if ! picotools_ui_stderr_is_pretty; then
    return 0
  fi

  printf '%s%s[%s/%s]%s %s\n' "$(picotools_ui_bold)" "$(picotools_ui_blue)" "$current" "$total" "$(picotools_ui_reset)" "$title" >&2
}

picotools_ui_status() {
  local kind="$1"
  local message="$2"
  local label color

  case "$kind" in
  ok)
    label='OK'
    color=$(picotools_ui_green)
    ;;
  warn)
    label='WARN'
    color=$(picotools_ui_yellow)
    ;;
  info | *)
    label='INFO'
    color=$(picotools_ui_blue)
    ;;
  esac

  if picotools_ui_stderr_is_pretty; then
    printf '%s[%s]%s %s\n' "$color" "$label" "$(picotools_ui_reset)" "$message" >&2
  fi
}

picotools_ui_summary() {
  local title="$1"
  shift
  local line width
  local -a lines=("$@")

  if ! picotools_ui_stderr_is_pretty; then
    return 0
  fi

  width=$(picotools_box_width_for_lines 36 "$title" "${lines[@]}")
  printf '%s' "$(picotools_ui_blue)" >&2
  picotools_box_top "$width" >&2
  picotools_box_line "$title" "$width" >&2
  picotools_box_separator "$width" >&2
  for line in "${lines[@]}"; do
    picotools_box_line "$line" "$width" >&2
  done
  picotools_box_bottom "$width" >&2
  printf '%s' "$(picotools_ui_reset)" >&2
}

picotools_ui_run_with_progress() {
  local message="$1"
  shift
  local spinner="|/-\\"
  local pid spin_index=0
  local status=0

  if ! picotools_ui_stderr_is_pretty; then
    "$@"
    return $?
  fi

  "$@" &
  pid=$!

  printf '%s[%s]%s %s ' "$(picotools_ui_blue)" '....' "$(picotools_ui_reset)" "$message" >&2
  while kill -0 "$pid" 2>/dev/null; do
    printf '%s\b' "${spinner:spin_index++%4:1}" >&2
    sleep 0.1
  done

  if wait "$pid"; then
    printf '\b%s[%s]%s %s\n' "$(picotools_ui_green)" 'DONE' "$(picotools_ui_reset)" "$message" >&2
    return 0
  fi

  status=$?
  printf '\b%s[%s]%s %s\n' "$(picotools_ui_yellow)" 'FAIL' "$(picotools_ui_reset)" "$message" >&2
  return "$status"
}
