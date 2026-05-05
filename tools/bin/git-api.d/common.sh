#!/usr/bin/env bash

git_api_default_api_root() {
  printf '%s\n' 'https://api.github.com'
}

git_api_default_api_version() {
  printf '%s\n' '2026-03-10'
}

git_api_reference_root() {
  local script_dir="$1"
  local candidate

  for candidate in \
    "$script_dir/../lib/picotools/git-api" \
    "$script_dir/../../lib/picotools/git-api"; do
    if [ -d "$candidate" ] && [ -f "$candidate/api.github.com.json" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo 'Error: git-api reference directory was not found' >&2
  exit 1
}

git_api_spec_file() {
  local script_dir="$1"
  printf '%s/api.github.com.json\n' "$(git_api_reference_root "$script_dir")"
}

git_api_path_tree_dir() {
  local script_dir="$1"
  printf '%s/github-rest-path-tree\n' "$(git_api_reference_root "$script_dir")"
}

git_api_operation_index_file() {
  local script_dir="$1"
  printf '%s/operation-id-index.json\n' "$(git_api_reference_root "$script_dir")"
}

git_api_urlencode() {
  local value="$1"
  local length index char encoded=''

  LC_ALL=C
  length=${#value}
  for ((index = 0; index < length; index++)); do
    char=${value:index:1}
    case "$char" in
    [a-zA-Z0-9.~_-])
      encoded+="$char"
      ;;
    *)
      printf -v char '%%%02X' "'${char}"
      encoded+="$char"
      ;;
    esac
  done

  printf '%s\n' "$encoded"
}

git_api_urlencode_path_value() {
  local key="$1"
  local value="$2"
  local part joined=''

  case "$key" in
  path | ref)
    while IFS= read -r part; do
      if [ -n "$joined" ]; then
        joined+='/'
      fi
      joined+="$(git_api_urlencode "$part")"
    done < <(printf '%s\n' "$value" | tr '/' '\n')
    printf '%s\n' "$joined"
    ;;
  *)
    git_api_urlencode "$value"
    ;;
  esac
}

git_api_token() {
  if [ -n "${GITHUB_PAT:-}" ]; then
    printf '%s\n' "$GITHUB_PAT"
    return 0
  fi

  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s\n' "$GH_TOKEN"
    return 0
  fi

  printf '%s\n' ''
}

git_api_validate_key_value() {
  local pair="$1"
  local flag_name="$2"

  case "$pair" in
  *=*)
    return 0
    ;;
  *)
    echo "Error: ${flag_name} requires KEY=VALUE" >&2
    exit 1
    ;;
  esac
}

git_api_path_has_placeholder() {
  local path="$1"
  local key="$2"

  case "$path" in
  *"{$key}"*)
    return 0
    ;;
  esac

  return 1
}

git_api_fill_path_placeholder() {
  local path="$1"
  local key="$2"
  local value="$3"
  local encoded

  encoded=$(git_api_urlencode_path_value "$key" "$value")
  printf '%s\n' "${path//\{$key\}/$encoded}"
}

git_api_assert_no_placeholders() {
  local path="$1"

  if [[ "$path" =~ \{[^}]+\} ]]; then
    echo "Error: missing required path parameter for $path" >&2
    exit 1
  fi
}

git_api_extract_path_parameters() {
  local path="$1"
  local remainder="$path"

  while [[ "$remainder" =~ \{([^}]+)\} ]]; do
    printf '%s\n' "${BASH_REMATCH[1]}"
    remainder=${remainder#*"${BASH_REMATCH[0]}"}
  done
}

git_api_cli_flag_name() {
  local parameter_name="$1"
  printf '%s\n' "${parameter_name//_/-}"
}

git_api_normalize_flag_name() {
  local flag_name="$1"
  printf '%s\n' "${flag_name//-/_}"
}

git_api_flag_matches_parameter() {
  local flag_name="$1"
  local parameter_name="$2"

  [ "$(git_api_normalize_flag_name "$flag_name")" = "$(git_api_normalize_flag_name "$parameter_name")" ]
}
