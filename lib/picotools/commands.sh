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

picotools_resolve_tool_command() {
  local script_dir="$1"
  local env_var_name="$2"
  local tool_name="$3"
  local env_value="${!env_var_name:-}"
  local candidate

  if [ -n "$env_value" ]; then
    printf '%s\n' "$env_value"
    return 0
  fi

  candidate="${script_dir}/${tool_name}"
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return 0
  fi

  echo "Error: unable to locate ${tool_name}" >&2
  exit 1
}
