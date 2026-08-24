#!/usr/bin/env bash

if [ "${PICOTOOLS_MODEL_PROFILE_TOKEN_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_MODEL_PROFILE_TOKEN_SH_LOADED=1

data_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/model-profile"
}

token_file() {
  local name="$1"
  printf '%s/%s.token\n' "$(data_dir)" "$name"
}

read_token() {
  local name="$1"
  local file status

  if file=$(validate_token_storage "$name" read); then
    :
  else
    status=$?
    if [ "$status" -eq 1 ]; then
      echo "Error: API key not found for profile '$name'" >&2
    fi
    return 1
  fi

  read_valid_token_file "$name" "$file"
}

path_mode() {
  stat -c '%a' "$1"
}

path_link_count() {
  stat -c '%h' "$1"
}

token_storage_error() {
  echo "Error: unsafe API key storage for profile '$1'" >&2
}

ensure_token_storage_root_for_write() {
  local dir

  dir=$(data_dir)
  if [ -L "$dir" ]; then
    echo 'Error: unsafe API key storage directory' >&2
    return 2
  fi
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    echo 'Error: unsafe API key storage directory' >&2
    return 2
  fi

  mkdir -p "$dir"
  chmod 700 "$dir"

  if [ -L "$dir" ] || [ ! -d "$dir" ]; then
    echo 'Error: unsafe API key storage directory' >&2
    return 2
  fi

  printf '%s\n' "$dir"
}

validate_token_storage() {
  local name="$1"
  local operation="$2"
  local dir file mode link_count

  dir=$(data_dir)
  file=$(token_file "$name")

  if [ "$operation" = write ]; then
    if ! ensure_token_storage_root_for_write >/dev/null; then
      return 2
    fi
  else
    if [ -L "$dir" ]; then
      token_storage_error "$name"
      return 2
    fi
    if [ ! -e "$dir" ]; then
      return 1
    fi
    if [ ! -d "$dir" ]; then
      token_storage_error "$name"
      return 2
    fi
    mode=$(path_mode "$dir")
    if [ "$mode" != 700 ]; then
      token_storage_error "$name"
      return 2
    fi
  fi

  if [ -L "$file" ]; then
    token_storage_error "$name"
    return 2
  fi
  if [ ! -e "$file" ]; then
    printf '%s\n' "$file"
    return 1
  fi
  if [ ! -f "$file" ]; then
    token_storage_error "$name"
    return 2
  fi

  link_count=$(path_link_count "$file")
  if [ "$link_count" -ne 1 ]; then
    token_storage_error "$name"
    return 2
  fi

  if [ "$operation" != write ]; then
    mode=$(path_mode "$file")
    if [ "$mode" != 600 ]; then
      token_storage_error "$name"
      return 2
    fi
  fi

  printf '%s\n' "$file"
}

validate_token_content() {
  local name="$1"
  local token="$2"

  if [ -z "$token" ]; then
    echo "Error: API key is blank for profile '$name'" >&2
    return 1
  fi
  if [[ "$token" =~ [[:cntrl:]] ]]; then
    echo "Error: API key content is malformed for profile '$name'" >&2
    return 1
  fi
  if [[ "$token" == *\"* ]]; then
    echo "Error: API key content is malformed for profile '$name'" >&2
    return 1
  fi
  if [[ "$token" == *\\* ]]; then
    echo "Error: API key content is malformed for profile '$name'" >&2
    return 1
  fi
}

read_valid_token_file() {
  local name="$1"
  local file="$2"
  local token='' extra='' first_line_ended=false fd
  local byte

  for byte in $(od -An -tx1 -v "$file"); do
    case "$byte" in
    00 | 01 | 02 | 03 | 04 | 05 | 06 | 07 | 08 | 09 | 0b | 0c | 0e | 0f | \
      10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 1a | 1b | 1c | 1d | 1e | 1f | 7f)
      echo "Error: API key content is malformed for profile '$name'" >&2
      return 1
      ;;
    esac
  done

  exec {fd}<"$file"
  if IFS= read -r -u "$fd" token; then
    first_line_ended=true
  fi
  if IFS= read -r -u "$fd" extra || [ -n "$extra" ]; then
    exec {fd}<&-
    echo "Error: API key content is malformed for profile '$name'" >&2
    return 1
  fi
  exec {fd}<&-

  if [ "$first_line_ended" = true ] && [[ "$token" == *$'\r' ]]; then
    token=${token%$'\r'}
  fi

  if ! validate_token_content "$name" "$token"; then
    return 1
  fi

  printf '%s\n' "$token"
}

token_exists() {
  local name="$1"
  local file status

  if file=$(validate_token_storage "$name" status); then
    if read_valid_token_file "$name" "$file" >/dev/null; then
      return 0
    fi
    return 2
  else
    status=$?
    if [ "$status" -eq 1 ]; then
      return 1
    fi
    return 2
  fi
}
