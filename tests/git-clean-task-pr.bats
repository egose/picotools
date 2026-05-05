#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-clean-task-pr"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
}

teardown() {
  rm -rf "$TMP_DIR"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
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

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

create_repo_with_remote() {
  REMOTE_DIR="$TMP_DIR/remote.git"
  REPO_DIR="$TMP_DIR/repo"

  git init --bare -q "$REMOTE_DIR"
  git clone -q "$REMOTE_DIR" "$REPO_DIR"

  git -C "$REPO_DIR" config user.name 'Test User'
  git -C "$REPO_DIR" config user.email 'test@example.com'
  git -C "$REPO_DIR" checkout -q -b main

  printf 'initial\n' >"$REPO_DIR/README.md"
  git -C "$REPO_DIR" add README.md
  git -C "$REPO_DIR" commit -q -m 'init'
  git -C "$REPO_DIR" push -q -u origin main

  git -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$REPO_DIR" remote set-head origin --auto >/dev/null 2>&1
}

@test "creates a cleanup branch and stages the task changes as one commit" {
  local current_branch staged_files status_output

  create_repo_with_remote

  git -C "$REPO_DIR" checkout -q -b feat/task main
  printf 'feature work\n' >"$REPO_DIR/feature.txt"
  git -C "$REPO_DIR" add feature.txt
  git -C "$REPO_DIR" commit -q -m 'add feature work'

  run env -C "$REPO_DIR" bash "$TOOL" --branch 'feat/task_1' main

  [ "$status" -eq 0 ] || fail 'git-clean-task-pr should succeed for a clean task branch'
  assert_contains "$output" 'Soft reset complete. Create your final commit when ready.' 'should explain the resulting staged state'

  current_branch="$(git -C "$REPO_DIR" branch --show-current)"
  assert_eq "$current_branch" 'feat/task_1' 'should switch to the newly created cleanup branch'

  staged_files="$(git -C "$REPO_DIR" diff --cached --name-only)"
  assert_contains "$staged_files" 'feature.txt' 'should stage the task changes after the soft reset'

  status_output="$(git -C "$REPO_DIR" status --short)"
  assert_contains "$status_output" 'A  feature.txt' 'should leave the feature changes staged and ready for a new commit'
}

@test "help documents debug mode" {
  run bash "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'git-clean-task-pr --help should succeed'
  assert_contains "$output" '--debug' 'help should list debug mode'
}
