#!/usr/bin/env bash

if [ "${PICOTOOLS_CONFIG_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_CONFIG_SH_LOADED=1

picotools_git_config_set() {
  local file="$1"
  local key="$2"
  local value="$3"

  git config -f "$file" "$key" "$value"
}

picotools_git_config_unset_all() {
  local file="$1"
  local key="$2"

  git config -f "$file" --unset-all "$key" 2>/dev/null || true
}

picotools_git_config_get() {
  local file="$1"
  local key="$2"

  git config -f "$file" --get "$key"
}

picotools_git_config_get_optional() {
  local file="$1"
  local key="$2"

  git config -f "$file" --get "$key" 2>/dev/null || true
}

picotools_git_config_get_default() {
  local file="$1"
  local key="$2"
  local default_value="$3"
  local value

  value=$(picotools_git_config_get_optional "$file" "$key")
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

picotools_display_value_or_dash() {
  local value="${1:-}"

  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' '-'
  fi
}
