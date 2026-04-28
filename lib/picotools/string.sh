#!/usr/bin/env bash

if [ "${PICOTOOLS_STRING_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_STRING_SH_LOADED=1

picotools_trim_whitespace() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}
