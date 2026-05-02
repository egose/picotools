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

picotools_prompt_select_index() {
  local header="$1"
  local prompt="$2"
  local default_index="${3:-}"
  local allow_empty="${4:-false}"
  shift 4
  local selection
  local key
  local suffix
  local option_count
  local selected_index
  local rendered=false
  local selected_start=''
  local selected_end=''
  local -a options=("$@")

  option_count=${#options[@]}
  if [ "$option_count" -eq 0 ]; then
    echo "Error: no options available for $header" >&2
    exit 1
  fi

  if ! [[ "$default_index" =~ ^[0-9]+$ ]] || [ "$default_index" -lt 1 ] || [ "$default_index" -gt "$option_count" ]; then
    if [ -n "$default_index" ]; then
      default_index=1
    fi
  fi

  if [ ! -t 0 ] || [ ! -t 2 ]; then
    local index=1
    local option

    printf '%s:\n' "$header" >&2
    for option in "${options[@]}"; do
      printf '  %d. %s\n' "$index" "$option" >&2
      index=$((index + 1))
    done

    if [ -n "$default_index" ]; then
      printf '%s [%s]: ' "$prompt" "$default_index" >&2
    else
      printf '%s: ' "$prompt" >&2
    fi

    read -r selection || true
    case "$selection" in
    q | Q)
      return 2
      ;;
    esac

    if [ -z "$selection" ]; then
      if [ -n "$default_index" ]; then
        selection="$default_index"
      elif [ "$allow_empty" = true ]; then
        return 2
      fi
    fi

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$option_count" ]; then
      echo 'Error: invalid selection' >&2
      return 1
    fi

    printf '%s\n' "$selection"
    return 0
  fi

  selected_index="${default_index:-1}"
  if [ "${TERM:-}" != 'dumb' ]; then
    selected_start=$'\033[1;36m'
    selected_end=$'\033[0m'
  fi

  printf '%s\n' "$header" >&2
  printf 'Use up/down to choose, Enter to confirm, Esc or q to cancel.\n' >&2

  printf '\033[?25l' >&2
  while true; do
    local index=1
    local option prefix

    if [ "$rendered" = true ]; then
      printf '\033[%dA' "$option_count" >&2
    fi
    for option in "${options[@]}"; do
      if [ "$index" -eq "$selected_index" ]; then
        prefix="> ${selected_start}"
        option+="$selected_end"
      else
        prefix='  '
      fi
      printf '\033[2K\r%s%s\n' "$prefix" "$option" >&2
      index=$((index + 1))
    done
    rendered=true

    if ! IFS= read -rsn1 key; then
      printf '\033[?25h' >&2
      return 2
    fi

    case "$key" in
    '')
      printf '\033[?25h\n' >&2
      printf '%s\n' "$selected_index"
      return 0
      ;;
    q | Q)
      printf '\033[?25h\n' >&2
      return 2
      ;;
    $'\x1b')
      suffix=''
      IFS= read -rsn2 -t 0.1 suffix || true
      key+="$suffix"
      case "$key" in
      $'\x1b[A')
        if [ "$selected_index" -gt 1 ]; then
          selected_index=$((selected_index - 1))
        fi
        ;;
      $'\x1b[B')
        if [ "$selected_index" -lt "$option_count" ]; then
          selected_index=$((selected_index + 1))
        fi
        ;;
      $'\x1b')
        printf '\033[?25h\n' >&2
        return 2
        ;;
      esac
      ;;
    esac
  done
}

picotools_prompt_parse_selection_list() {
  local raw_value="$1"
  local option_count="$2"
  local token
  local -a tokens=()
  local -a selections=()
  local -a seen=()

  raw_value=${raw_value//,/ }
  read -r -a tokens <<<"$raw_value"

  if [ "${#tokens[@]}" -eq 0 ]; then
    return 2
  fi

  for token in "${tokens[@]}"; do
    case "$token" in
    q | Q)
      return 2
      ;;
    esac

    if ! [[ "$token" =~ ^[0-9]+$ ]] || [ "$token" -lt 1 ] || [ "$token" -gt "$option_count" ]; then
      echo "Error: invalid selection '$token'" >&2
      return 1
    fi

    if [ "${seen[$token]:-0}" -eq 1 ]; then
      continue
    fi

    seen[token]=1
    selections+=("$token")
  done

  printf '%s\n' "${selections[@]}"
}

picotools_prompt_select_multiple_indexes() {
  local header="$1"
  local prompt="$2"
  local allow_empty="${3:-false}"
  shift 3
  local selection
  local key
  local suffix
  local option_count
  local selected_index=1
  local rendered=false
  local selected_start=''
  local selected_end=''
  local selected_count=0
  local index
  local option
  local marker
  local line
  local -a options=("$@")
  local -a selected=()

  option_count=${#options[@]}
  if [ "$option_count" -eq 0 ]; then
    echo "Error: no options available for $header" >&2
    exit 1
  fi

  if [ ! -t 0 ] || [ ! -t 2 ]; then
    index=1

    printf '%s:\n' "$header" >&2
    for option in "${options[@]}"; do
      printf '  %d. %s\n' "$index" "$option" >&2
      index=$((index + 1))
    done

    printf '%s: ' "$prompt" >&2
    read -r selection || true

    if [ -z "$selection" ]; then
      if [ "$allow_empty" = true ]; then
        return 0
      fi

      return 2
    fi

    picotools_prompt_parse_selection_list "$selection" "$option_count"
    return $?
  fi

  if [ "${TERM:-}" != 'dumb' ]; then
    selected_start=$'\033[1;36m'
    selected_end=$'\033[0m'
  fi

  printf '%s\n' "$header" >&2
  printf 'Use up/down to choose, Space to toggle, Enter to confirm, Esc or q to cancel.\n' >&2

  printf '\033[?25l' >&2
  while true; do
    index=1

    if [ "$rendered" = true ]; then
      printf '\033[%dA' "$option_count" >&2
    fi

    for option in "${options[@]}"; do
      marker='[ ]'
      if [ "${selected[$index]:-0}" -eq 1 ]; then
        marker='[x]'
      fi

      line="$marker $option"
      if [ "$index" -eq "$selected_index" ]; then
        printf '\033[2K\r> %s%s%s\n' "$selected_start" "$line" "$selected_end" >&2
      else
        printf '\033[2K\r  %s\n' "$line" >&2
      fi

      index=$((index + 1))
    done
    rendered=true

    if ! IFS= read -rsn1 key; then
      printf '\033[?25h' >&2
      return 2
    fi

    case "$key" in
    '')
      if [ "$selected_count" -eq 0 ] && [ "$allow_empty" != true ]; then
        printf '\033[?25h\n' >&2
        return 2
      fi

      printf '\033[?25h\n' >&2
      for index in "${!options[@]}"; do
        if [ "${selected[$((index + 1))]:-0}" -eq 1 ]; then
          printf '%s\n' "$((index + 1))"
        fi
      done
      return 0
      ;;
    ' ')
      if [ "${selected[$selected_index]:-0}" -eq 1 ]; then
        selected[selected_index]=0
        selected_count=$((selected_count - 1))
      else
        selected[selected_index]=1
        selected_count=$((selected_count + 1))
      fi
      ;;
    q | Q)
      printf '\033[?25h\n' >&2
      return 2
      ;;
    $'\x1b')
      suffix=''
      IFS= read -rsn2 -t 0.1 suffix || true
      key+="$suffix"
      case "$key" in
      $'\x1b[A')
        if [ "$selected_index" -gt 1 ]; then
          selected_index=$((selected_index - 1))
        fi
        ;;
      $'\x1b[B')
        if [ "$selected_index" -lt "$option_count" ]; then
          selected_index=$((selected_index + 1))
        fi
        ;;
      $'\x1b')
        printf '\033[?25h\n' >&2
        return 2
        ;;
      esac
      ;;
    esac
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
