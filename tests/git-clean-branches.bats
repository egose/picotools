#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-clean-branches"

setup() {
  TMP_HOME="$(mktemp -d)" || return 1
}

teardown() {
  rm -rf "$TMP_HOME"
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*)
    fail "$message (unexpected '$needle')"
    ;;
  *) ;;
  esac
}

assert_branch_exists() {
  local repo="$1"
  local branch="$2"
  local message="$3"

  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || fail "$message"
}

assert_branch_missing() {
  local repo="$1"
  local branch="$2"
  local message="$3"

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "$message"
  fi
}

create_repo_with_remote() {
  REMOTE_DIR="$TMP_HOME/remote.git"
  REPO_DIR="$TMP_HOME/repo"

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

create_merged_remote_branch() {
  git -C "$REPO_DIR" checkout -q -b merged-remote
  printf 'merged remote\n' >>"$REPO_DIR/README.md"
  git -C "$REPO_DIR" add README.md
  git -C "$REPO_DIR" commit -q -m 'merged remote'
  git -C "$REPO_DIR" push -q -u origin merged-remote

  git -C "$REPO_DIR" checkout -q main
  git -C "$REPO_DIR" merge --no-ff -q -m 'merge merged remote' merged-remote
  git -C "$REPO_DIR" push -q origin main
}

checkout_topic_branch() {
  git -C "$REPO_DIR" checkout -q -b dv_1 main
}

@test "does not list symbolic origin head as a remote branch" {
  create_repo_with_remote
  create_merged_remote_branch
  checkout_topic_branch

  run bash -c 'cd "$1" && printf "n\n" | "$2"' _ "$REPO_DIR" "$TOOL"

  [ "$status" -eq 1 ] || fail 'cancelling the prompt should exit non-zero'
  assert_contains "$output" 'Remote branches to delete:' 'should list merged remote branches'
  assert_contains "$output" '  merged-remote' 'should include merged remote branches'
  assert_not_contains "$output" $'\n  origin\n' 'should not treat the symbolic remote head as a branch'
}

@test "skips local branches that are checked out in another worktree" {
  local worktree_dir

  create_repo_with_remote
  checkout_topic_branch

  git -C "$REPO_DIR" branch dv main
  git -C "$REPO_DIR" branch feat/git-context main
  worktree_dir="$TMP_HOME/worktrees/git-context"
  mkdir -p "$TMP_HOME/worktrees"
  git -C "$REPO_DIR" worktree add -q "$worktree_dir" feat/git-context

  run bash -c 'cd "$1" && "$2" --yes' _ "$REPO_DIR" "$TOOL"

  [ "$status" -eq 0 ] || fail 'cleaning branches should succeed when another worktree exists'
  assert_contains "$output" 'Local branches to delete:' 'should still delete other local branches'
  assert_contains "$output" '  dv' 'should include deletable local branches'
  assert_not_contains "$output" '  feat/git-context' 'should skip branches used by another worktree'
  assert_branch_missing "$REPO_DIR" 'dv' 'should delete local branches not used by a worktree'
  assert_branch_exists "$REPO_DIR" 'feat/git-context' 'should preserve branches checked out in another worktree'
}
