#!/usr/bin/env bash

if [ "${PICOTOOLS_PROMPT_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_PROMPT_SH_LOADED=1

picotools_prompt_value() {
  local label="$1"
  local default_value="${2:-}"
  local required="${3:-false}"
  local answer

  while true; do
    if [ -n "$default_value" ]; then
      printf '%s [%s]: ' "$label" "$default_value" >&2
    else
      printf '%s: ' "$label" >&2
    fi

    read -r answer || true
    if [ -z "$answer" ]; then
      answer="$default_value"
    fi

    if [ "$required" = true ] && [ -z "$answer" ]; then
      echo 'Value is required.' >&2
      continue
    fi

    printf '%s\n' "$answer"
    return 0
  done
}

picotools_prompt_yes_no() {
  local label="$1"
  local default_value="${2:-no}"
  local prompt
  local answer
  local normalized

  case "$default_value" in
  y | yes)
    default_value='yes'
    prompt='[Y/n]'
    ;;
  n | no | '')
    default_value='no'
    prompt='[y/N]'
    ;;
  *)
    echo "Error: invalid yes/no default '$default_value'" >&2
    exit 1
    ;;
  esac

  while true; do
    printf '%s %s: ' "$label" "$prompt" >&2
    read -r answer || true
    normalized=${answer,,}

    if [ -z "$normalized" ]; then
      normalized="$default_value"
    fi

    case "$normalized" in
    y | yes)
      printf 'yes\n'
      return 0
      ;;
    n | no)
      printf 'no\n'
      return 0
      ;;
    esac

    echo 'Please answer yes or no.' >&2
  done
}

picotools_confirm_action() {
  local prompt="$1"

  if [ "$(picotools_prompt_yes_no "$prompt" no)" = 'yes' ]; then
    return 0
  fi

  echo 'Cancelled.' >&2
  return 1
}
