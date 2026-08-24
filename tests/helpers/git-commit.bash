#!/usr/bin/env bash

GIT_COMMIT_TEST_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_COMMIT_TEST_REPO_ROOT="$(cd "$GIT_COMMIT_TEST_HELPER_DIR/../.." && pwd)"

: "${REPO_ROOT:=$GIT_COMMIT_TEST_REPO_ROOT}"
: "${TOOL:=$REPO_ROOT/tools/bin/git-commit}"
: "${REAL_JQ_BIN:=$(asdf which jq 2>/dev/null || command -v jq)}"

setup_git_commit_test_home() {
  TMP_HOME="$(mktemp -d)" || return 1
  export TMP_HOME
  export HOME="$TMP_HOME"
  export XDG_CONFIG_HOME="$TMP_HOME/.config"
  export GIT_COMMIT_CONFIG_DIR="$XDG_CONFIG_HOME/git-commit"
}

teardown_git_commit_test_home() {
  rm -rf "${TMP_HOME:-}"
}

ensure_real_jq_on_path() {
  local bin_dir="${1:-$TMP_HOME/bin}"

  if [ -z "${REAL_JQ_BIN:-}" ] || [ ! -x "$REAL_JQ_BIN" ]; then
    fail 'real jq is required for git-commit tests'
  fi

  mkdir -p "$bin_dir"
  ln -sf "$REAL_JQ_BIN" "$bin_dir/jq"
}

create_jq_stub_from_real_jq() {
  local stub_path="$1"

  if [ -z "${REAL_JQ_BIN:-}" ] || [ ! -x "$REAL_JQ_BIN" ]; then
    fail 'real jq is required for git-commit tests'
  fi

  ln -sf "$REAL_JQ_BIN" "$stub_path"
}

create_jq_stub() {
  create_jq_stub_from_real_jq "$@"
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
  *) fail "$message (missing '$needle')" ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*) fail "$message (unexpected '$needle')" ;;
  esac
}

assert_file_exists() {
  local path="$1"
  local message="$2"

  [ -f "$path" ] || fail "$message ($path)"
}

assert_file_missing() {
  local path="$1"
  local message="$2"

  [ ! -e "$path" ] || fail "$message ($path)"
}

git_commit_config_file() {
  printf '%s/config\n' "$GIT_COMMIT_CONFIG_DIR"
}

write_git_commit_config() {
  local profile="$1"
  local model="$2"
  local additional_profile="${3:-}"
  local additional_model="${4:-}"
  local git_api_profile="${5:-}"
  local file

  mkdir -p "$GIT_COMMIT_CONFIG_DIR"
  file="$(git_commit_config_file)"
  printf '[model]\n\tprofile = %s\n\tname = %s\n' "$profile" "$model" >"$file"
  if [ -n "$additional_profile" ] && [ -n "$additional_model" ]; then
    printf '[model "additional"]\n\tprofile = %s\n\tname = %s\n' "$additional_profile" "$additional_model" >>"$file"
  fi
  if [ -n "$git_api_profile" ]; then
    printf '[git-api]\n\tprofile = %s\n' "$git_api_profile" >>"$file"
  fi
}

assert_config_value() {
  local key="$1"
  local expected="$2"
  local message="$3"

  assert_eq "$(git config -f "$(git_commit_config_file)" --get "$key")" "$expected" "$message"
}

assert_config_missing() {
  local key="$1"
  local message="$2"

  if git config -f "$(git_commit_config_file)" --get "$key" >/dev/null 2>&1; then
    fail "$message ($key)"
  fi
}

init_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.name 'Test User'
  git -C "$repo" config user.email 'test@example.com'
}

create_initial_commit() {
  local repo="$1"

  printf '%s\n' 'initial' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m 'chore(init): initial commit'
}

init_repo_with_initial_commit() {
  local repo="$1"

  init_repo "$repo"
  create_initial_commit "$repo"
}

create_repo_with_remote() {
  local remote="$1"
  local repo="$2"

  git init --bare -q "$remote"
  git clone -q "$remote" "$repo"
  git -C "$repo" config user.name 'Test User'
  git -C "$repo" config user.email 'test@example.com'
  git -C "$repo" checkout -q -b main

  printf '%s\n' 'initial' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m 'chore(init): initial commit'
  git -C "$repo" push -q -u origin main

  git -C "$remote" symbolic-ref HEAD refs/heads/main
  git -C "$repo" remote set-head origin --auto >/dev/null 2>&1
}

strip_ansi() {
  printf '%s' "$1" | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g'
}

strip_box_borders() {
  perl -C -pe 's/^[\x{2500}-\x{257F}\x{2550}-\x{256C}]+[ \t]*//; s/[ \t]*[\x{2500}-\x{257F}\x{2550}-\x{256C}]+$//'
}

preview_shell_squote() {
  local text="$1"

  printf "'%s'" "${text//\'/\'\\\'\'}"
}

preview_git_commit_command() {
  local title="$1"

  printf 'git commit -m %s\n' "$(preview_shell_squote "$title")"
}

append_argv_records() {
  local log_file="$1"
  shift
  local arg

  printf '%s\n' 'ARGV_BEGIN' >>"$log_file"
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$log_file"
  done
  printf '%s\n' 'ARGV_END' >>"$log_file"
}

append_human_argv_line() {
  local log_file="$1"
  shift
  local arg rendered=''

  for arg in "$@"; do
    printf -v rendered '%s%s%q' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n' "$rendered" >>"$log_file"
}

assert_argv_record_contains_exact_arg() {
  local log_file="$1"
  local expected="$2"
  local encoded

  printf -v encoded '%q' "$expected"
  grep -Fx -- "$encoded" "$log_file" >/dev/null || fail "argv log should contain exact argument '$expected'"
}

assert_argv_record_not_contains_exact_arg() {
  local log_file="$1"
  local unexpected="$2"
  local encoded

  printf -v encoded '%q' "$unexpected"
  if grep -Fx -- "$encoded" "$log_file" >/dev/null; then
    fail "argv log should not contain exact argument '$unexpected'"
  fi
}
