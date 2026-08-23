#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_PROFILE_TOKEN_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_PROFILE_TOKEN_SH_LOADED=1

context_token_file() {
  local name="$1"

  validate_context_name "$name"
  printf '%s/%s.token\n' "$(data_dir)" "$name"
}

ensure_data_dir() {
  local dir

  dir=$(data_dir)
  umask 077
  mkdir -p "$dir"
  chmod 700 "$dir"
}

validate_token_data_dir() {
  local action="$1"
  local write_allowed="$2"
  local dir mode

  dir=$(data_dir)
  if [ -L "$dir" ]; then
    echo "Error: refusing to $action PAT because the git-profile data directory is a symbolic link: $dir" >&2
    return 2
  fi

  if [ ! -e "$dir" ]; then
    if [ "$write_allowed" = 'yes' ]; then
      ensure_data_dir
      printf '%s\n' "$dir"
      return 0
    fi
    return 1
  fi

  if [ ! -d "$dir" ]; then
    echo "Error: refusing to $action PAT because the git-profile data path is not a directory: $dir" >&2
    return 2
  fi

  if [ "$write_allowed" = 'yes' ]; then
    chmod 700 "$dir"
  else
    mode=$(stat -c %a "$dir")
    if [ "$mode" != '700' ]; then
      echo "Error: refusing to $action PAT because the git-profile data directory must be mode 0700: $dir" >&2
      return 2
    fi
  fi

  printf '%s\n' "$dir"
}

require_safe_token_path() {
  local name="$1"
  local action="$2"
  local write_allowed="${3:-no}"
  local dir file mode
  local status=0

  validate_context_name "$name"
  dir=$(validate_token_data_dir "$action" "$write_allowed") || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s/%s.token\n' "$(data_dir)" "$name"
    return "$status"
  fi

  file="$dir/$name.token"
  if [ -L "$file" ]; then
    echo "Error: refusing to $action PAT for profile '$name' because its token path is a symbolic link" >&2
    return 2
  fi

  if [ -e "$file" ] && [ ! -f "$file" ]; then
    echo "Error: refusing to $action PAT for profile '$name' because its token path is not a regular file" >&2
    return 2
  fi

  if [ "$write_allowed" != 'yes' ] && [ -f "$file" ]; then
    mode=$(stat -c %a "$file")
    if [ "$mode" != '600' ]; then
      echo "Error: refusing to $action PAT for profile '$name' because its token file must be mode 0600" >&2
      return 2
    fi
  fi

  printf '%s\n' "$file"
}

read_token_file_value() {
  local name="$1"
  local file="$2"
  local line='' extra=''
  local token_fd

  exec {token_fd}<"$file"
  if ! IFS= read -r -u "$token_fd" line && [ -z "$line" ]; then
    exec {token_fd}<&-
    return 1
  fi

  if IFS= read -r -u "$token_fd" extra || [ -n "$extra" ]; then
    exec {token_fd}<&-
    echo "Error: refusing to read PAT for profile '$name' because its token file must contain exactly one line" >&2
    return 2
  fi
  exec {token_fd}<&-

  if [[ "$line" == *$'\r' ]]; then
    line=${line%$'\r'}
  fi
  if [[ "$line" == *$'\r'* ]]; then
    echo "Error: refusing to read PAT for profile '$name' because its token file contains an unexpected carriage return" >&2
    return 2
  fi

  if [ -z "$line" ]; then
    return 1
  fi

  printf '%s\n' "$line"
}

context_token_configured() {
  local name="$1"
  local action="${2:-read status for}"
  local file token
  local status=0

  file=$(require_safe_token_path "$name" "$action") || status=$?
  if [ "$status" -eq 1 ]; then
    return 1
  elif [ "$status" -ne 0 ]; then
    exit 1
  fi

  if [ ! -f "$file" ]; then
    return 1
  fi

  status=0
  token=$(read_token_file_value "$name" "$file") || status=$?
  if [ "$status" -eq 1 ]; then
    return 1
  elif [ "$status" -ne 0 ]; then
    exit 1
  fi
  [ -n "$token" ]
}

context_token_status() {
  local name="$1"
  local action="${2:-read status for}"

  if context_token_configured "$name" "$action"; then
    printf '%s\n' yes
  else
    printf '%s\n' no
  fi
}

read_context_token() {
  local name="$1"
  local file token
  local status=0

  file=$(require_safe_token_path "$name" read) || status=$?
  if [ "$status" -eq 1 ]; then
    echo "Error: PAT not configured for profile '$name'" >&2
    exit 1
  elif [ "$status" -ne 0 ]; then
    exit 1
  fi
  if [ ! -f "$file" ]; then
    echo "Error: PAT not configured for profile '$name'" >&2
    exit 1
  fi

  status=0
  token=$(read_token_file_value "$name" "$file") || status=$?
  if [ "$status" -eq 1 ]; then
    echo "Error: PAT not configured for profile '$name'" >&2
    exit 1
  elif [ "$status" -ne 0 ]; then
    exit 1
  fi

  printf '%s\n' "$token"
}

write_context_token() {
  local name="$1"
  local token="$2"
  local file dir tmp

  case "$token" in
  *$'\n'* | *$'\r'*)
    echo "Error: refusing to write PAT for profile '$name' because PAT values must be a single line" >&2
    return 1
    ;;
  esac

  if ! file=$(require_safe_token_path "$name" write yes); then
    return 1
  fi
  dir=${file%/*}
  umask 077
  if ! tmp=$(mktemp "$dir/.${name}.token.tmp.XXXXXX"); then
    return 1
  fi
  register_tmpfile "$tmp"

  if ! printf '%s\n' "$token" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

delete_context_token() {
  local name="$1"
  local file
  local status=0

  file=$(require_safe_token_path "$name" delete) || status=$?
  if [ "$status" -eq 1 ]; then
    return 0
  elif [ "$status" -ne 0 ]; then
    return 1
  fi
  rm -f -- "$file"
}

save_context_token_state() {
  local name="$1"
  local token="$2"

  if [ -n "$token" ]; then
    write_context_token "$name" "$token"
  else
    delete_context_token "$name"
  fi
}

preflight_context_token_state() {
  local name="$1"
  local token_action="$2"
  local pat_token="$3"
  local status=0

  case "$token_action" in
  write)
    case "$pat_token" in
    *$'\n'* | *$'\r'*)
      echo "Error: refusing to write PAT for profile '$name' because PAT values must be a single line" >&2
      return 1
      ;;
    esac
    require_safe_token_path "$name" write yes >/dev/null
    ;;
  delete)
    require_safe_token_path "$name" delete >/dev/null || status=$?
    if [ "$status" -eq 1 ]; then
      return 0
    fi
    return "$status"
    ;;
  keep)
    ;;
  *)
    echo "Error: invalid token transaction action '$token_action'" >&2
    return 1
    ;;
  esac
}
