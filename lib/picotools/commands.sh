#!/usr/bin/env bash

if [ "${PICOTOOLS_COMMANDS_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_COMMANDS_SH_LOADED=1

picotools_require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: ${command_name} is required but not installed" >&2
    exit 1
  fi
}

picotools_require_commands() {
  local command_name
  local -a missing=()

  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing+=("$command_name")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'Error: missing required tools: %s\n' "${missing[*]}" >&2
    exit 1
  fi
}
