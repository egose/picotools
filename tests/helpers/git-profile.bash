#!/bin/bash

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-profile"

setup() {
  TMP_HOME="$(mktemp -d)" || return 1
  export TMP_HOME
  export HOME="$TMP_HOME"
  export XDG_CONFIG_HOME="$TMP_HOME/.config"
  export XDG_DATA_HOME="$TMP_HOME/.local/share"
  export PROFILE_DIR="$XDG_CONFIG_HOME/git-profile"
  export PROFILE_DATA_DIR="$XDG_DATA_HOME/git-profile"
}

teardown() {
  rm -rf "$TMP_HOME"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*) ;;
  *)
    fail "$message (missing '$needle')"
    ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*)
    fail "$message (unexpected '$needle')"
    ;;
  esac
}

assert_file_exists() {
  local path="$1"
  local message="$2"

  [ -f "$path" ] || fail "$message ($path)"
}

assert_file_not_exists() {
  local path="$1"
  local message="$2"

  if [ -e "$path" ]; then
    fail "$message ($path)"
  fi
}

assert_git_config_file_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local message="$4"

  assert_eq "$(git config -f "$file" --get "$key")" "$expected" "$message"
}

assert_git_local_value() {
  local repo="$1"
  local key="$2"
  local expected="$3"
  local message="$4"

  assert_eq "$(git -C "$repo" config --local --get "$key")" "$expected" "$message"
}

assert_git_local_all_values() {
  local repo="$1"
  local key="$2"
  local expected="$3"
  local message="$4"

  assert_eq "$(git -C "$repo" config --local --get-all "$key")" "$expected" "$message"
}

assert_git_local_unset() {
  local repo="$1"
  local key="$2"
  local message="$3"

  if git -C "$repo" config --local --get "$key" >/dev/null 2>&1; then
    fail "$message"
  fi
}

assert_git_config_file_unset() {
  local file="$1"
  local key="$2"
  local message="$3"

  if git config -f "$file" --get "$key" >/dev/null 2>&1; then
    fail "$message"
  fi
}

init_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git init -q "$repo"
}

run_tool() {
  "$TOOL" "$@"
}

path_with_commands() {
  local bin="$1"
  local command_name command_path
  shift

  mkdir -p "$bin"
  for command_name in "$@"; do
    command_path=$(command -v "$command_name") || return 1
    ln -s "$command_path" "$bin/$command_name"
  done
  printf '%s\n' "$bin"
}

source_git_profile_modules() {
  # shellcheck source=../../lib/picotools/load.sh
  # shellcheck disable=SC1091
  . "$REPO_ROOT/lib/picotools/load.sh"
  picotools_source_modules "$REPO_ROOT/tools/bin" commands config git prompt table ui
  # shellcheck source=../../tools/lib/picotools/git-profile/profile.sh
  # shellcheck disable=SC1091
  . "$REPO_ROOT/tools/lib/picotools/git-profile/profile.sh"
  # shellcheck source=../../tools/lib/picotools/git-profile/resources.sh
  # shellcheck disable=SC1091
  . "$REPO_ROOT/tools/lib/picotools/git-profile/resources.sh"
  # shellcheck source=../../tools/lib/picotools/git-profile/token.sh
  # shellcheck disable=SC1091
  . "$REPO_ROOT/tools/lib/picotools/git-profile/token.sh"
}

register_git_profile_module_test_hooks() {
  # shellcheck disable=SC2329 # These hooks are invoked indirectly by sourced modules.
  register_tmpfile() { :; }
  # shellcheck disable=SC2329 # These hooks are invoked indirectly by sourced modules.
  debug_log() { :; }
}

run_set_in_repo() {
  local repo="$1"

  (
    cd "$repo" || return 1
    printf '1\n' | run_tool set >/dev/null 2>&1
  )
}

context_file_path() {
  printf '%s/%s.gitconfig\n' "$PROFILE_DIR" "$1"
}

token_file_path() {
  printf '%s/%s.token\n' "$PROFILE_DATA_DIR" "$1"
}

assert_mode() {
  local path="$1"
  local expected="$2"
  local message="$3"

  assert_eq "$(stat -c %a "$path")" "$expected" "$message"
}

assert_no_token_temps() {
  local dir="$1"
  local matches=()

  if [ -d "$dir" ]; then
    shopt -s nullglob
    matches=("$dir"/.*.token.tmp.*)
    shopt -u nullglob
  fi

  if [ "${#matches[@]}" -ne 0 ]; then
    fail "token operation should not leave temporary files behind"
  fi
}

assert_no_profile_temps() {
  local dir="$1"
  local matches=()

  if [ -d "$dir" ]; then
    shopt -s nullglob
    matches=("$dir"/.*.gitconfig.tmp.* "$dir"/*.gitconfig.backup.*)
    shopt -u nullglob
  fi

  if [ "${#matches[@]}" -ne 0 ]; then
    fail "profile operation should not leave temporary files behind"
  fi
}

write_git_config_values() {
  local file="$1"
  shift

  mkdir -p "$(dirname "$file")"

  while [ "$#" -gt 0 ]; do
    git config -f "$file" "$1" "$2"
    shift 2
  done
}

write_local_git_config_values() {
  local repo="$1"
  shift

  while [ "$#" -gt 0 ]; do
    git -C "$repo" config --local "$1" "$2"
    shift 2
  done
}

append_local_git_config_values() {
  local repo="$1"
  shift

  while [ "$#" -gt 0 ]; do
    git -C "$repo" config --local --add "$1" "$2"
    shift 2
  done
}

assert_command_fails() {
  local expected_message="$1"
  shift

  local output

  if output=$("$@" 2>&1); then
    fail "command should fail with a non-zero exit status"
  fi

  assert_contains "$output" "$expected_message" 'command should explain why it failed'
}

assert_create_fails() {
  local input="$1"
  local expected_message="$2"
  local context_name="$3"
  local unexpected_prompt="${4:-}"
  local output context_file

  context_file="$(context_file_path "$context_name")"

  if output=$(printf '%b' "$input" | run_tool create 2>&1); then
    fail "create should fail with a non-zero exit status"
  fi

  assert_contains "$output" "$expected_message" 'create should explain why the requested flow is unavailable'

  if [ -n "$unexpected_prompt" ]; then
    assert_not_contains "$output" "$unexpected_prompt" 'create should fail before prompting for later values'
  fi

  if [ -e "$context_file" ]; then
    fail 'create should not save a context file when the requested flow is unavailable'
  fi
}
