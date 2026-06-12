#!/usr/bin/env bash

if [ "${PICOTOOLS_DEBUG_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_DEBUG_SH_LOADED=1

picotools_debug_log() {
  local tool_name="$1"
  local message="$2"

  printf '[%s] %s\n' "$tool_name" "$message" >&2
}
