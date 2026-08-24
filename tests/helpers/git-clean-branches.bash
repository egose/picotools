#!/usr/bin/env bash

GIT_CLEAN_BRANCHES_TEST_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_CLEAN_BRANCHES_TEST_REPO_ROOT="$(cd "$GIT_CLEAN_BRANCHES_TEST_HELPER_DIR/../.." && pwd)"

: "${REPO_ROOT:=$GIT_CLEAN_BRANCHES_TEST_REPO_ROOT}"
: "${TOOL:=$REPO_ROOT/tools/bin/git-clean-branches}"
: "${REAL_GIT:=$(command -v git)}"
export REAL_GIT

setup_git_clean_branches_test_home() {
  TMP_HOME="$(mktemp -d)" || return 1
  export TMP_HOME
  export HOME="$TMP_HOME"
  export XDG_CONFIG_HOME="$TMP_HOME/.config"
  export XDG_DATA_HOME="$TMP_HOME/.local/share"
  export GIT_TERMINAL_PROMPT=0
}

teardown_git_clean_branches_test_home() {
  rm -rf "${TMP_HOME:-}"
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

assert_remote_branch_exists() {
  local remote="$1"
  local branch="$2"
  local message="$3"

  git -C "$remote" show-ref --verify --quiet "refs/heads/$branch" || fail "$message"
}

assert_remote_branch_missing() {
  local remote="$1"
  local branch="$2"
  local message="$3"

  if git -C "$remote" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "$message"
  fi
}

create_repo_with_remote() {
  local remote_name="${1:-origin}"

  REMOTE_DIR="$TMP_HOME/remote.git"
  REPO_DIR="$TMP_HOME/repo"
  export REMOTE_DIR REPO_DIR

  git init --bare -q "$REMOTE_DIR"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" config user.name 'Test User'
  git -C "$REPO_DIR" config user.email 'test@example.com'
  git -C "$REPO_DIR" checkout -q -b main

  printf 'initial\n' >"$REPO_DIR/README.md"
  git -C "$REPO_DIR" add README.md
  git -C "$REPO_DIR" commit -q -m 'init'
  git -C "$REPO_DIR" remote add -- "$remote_name" "$REMOTE_DIR"
  git -C "$REPO_DIR" push -q -u -- "$remote_name" main

  git -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/main
  git -C "$REPO_DIR" remote set-head --auto -- "$remote_name" >/dev/null 2>&1
  GIT_CLEAN_BRANCHES_REMOTE_NAME="$remote_name"
  export GIT_CLEAN_BRANCHES_REMOTE_NAME
}

create_repo_with_unresolved_default_remote() {
  REMOTE_DIR="$TMP_HOME/remote.git"
  REPO_DIR="$TMP_HOME/repo"
  export REMOTE_DIR REPO_DIR

  git init --bare -q "$REMOTE_DIR"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" config user.name 'Test User'
  git -C "$REPO_DIR" config user.email 'test@example.com'
  git -C "$REPO_DIR" checkout -q -b main
  printf 'initial\n' >"$REPO_DIR/README.md"
  git -C "$REPO_DIR" add README.md
  git -C "$REPO_DIR" commit -q -m 'init'
  git -C "$REPO_DIR" remote add origin "$REMOTE_DIR"
}

create_merged_remote_branch() {
  local branch="${1:-merged-remote}"
  local remote_name="${GIT_CLEAN_BRANCHES_REMOTE_NAME:-origin}"

  git -C "$REPO_DIR" checkout -q -b "$branch" main
  printf '%s\n' "$branch" >>"$REPO_DIR/README.md"
  git -C "$REPO_DIR" add README.md
  git -C "$REPO_DIR" commit -q -m "$branch"
  git -C "$REPO_DIR" push -q -u -- "$remote_name" "$branch"

  git -C "$REPO_DIR" checkout -q main
  git -C "$REPO_DIR" merge --no-ff -q -m "merge $branch" "$branch"
  git -C "$REPO_DIR" push -q -- "$remote_name" main
}

create_unmerged_remote_branch() {
  local branch="${1:-unmerged-remote}"
  local remote_name="${GIT_CLEAN_BRANCHES_REMOTE_NAME:-origin}"

  git -C "$REPO_DIR" checkout -q -b "$branch" main
  printf '%s\n' "$branch" >"$REPO_DIR/$branch.txt"
  git -C "$REPO_DIR" add "$branch.txt"
  git -C "$REPO_DIR" commit -q -m "$branch"
  git -C "$REPO_DIR" push -q -u -- "$remote_name" "$branch"
  git -C "$REPO_DIR" checkout -q main
}

create_remote_branch_at_main() {
  local branch="$1"
  local remote_name="${GIT_CLEAN_BRANCHES_REMOTE_NAME:-origin}"

  git -C "$REPO_DIR" branch "$branch" main
  git -C "$REPO_DIR" push -q -u -- "$remote_name" "$branch"
}

create_unmerged_local_branch() {
  local branch="${1:-unmerged-local}"

  git -C "$REPO_DIR" checkout -q -b "$branch" main
  printf '%s\n' "$branch" >"$REPO_DIR/$branch.txt"
  git -C "$REPO_DIR" add "$branch.txt"
  git -C "$REPO_DIR" commit -q -m "$branch"
  git -C "$REPO_DIR" checkout -q main
}

checkout_topic_branch() {
  local branch="${1:-dv_1}"

  git -C "$REPO_DIR" checkout -q -b "$branch" main
}

extract_plan_section() {
  local text="$1"
  local header="$2"
  local in_section=false
  local line

  while IFS= read -r line; do
    if [ "$in_section" = true ]; then
      case "$line" in
      '  '*) printf '%s\n' "$line" ;;
      *) break ;;
      esac
      continue
    fi

    if [ "$line" = "$header" ]; then
      in_section=true
    fi
  done <<<"$text"
}

run_git_clean_branches() {
  local repo="$1"
  local input="$2"
  shift 2

  run bash -c 'cd "$1" || exit 1; input="$2"; shift 2; printf "%b" "$input" | "$@"' _ "$repo" "$input" "$TOOL" "$@"
}

run_git_clean_branches_without_stdin() {
  local repo="$1"
  shift

  run bash -c 'cd "$1" || exit 1; shift; "$@" </dev/null' _ "$repo" "$TOOL" "$@"
}

run_git_clean_branches_without_git() {
  local non_repo="$1"
  shift

  local bin_dir="$TMP_HOME/no-git-bin"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/git" <<'EOF'
#!/usr/bin/env bash
printf 'git should not run during argument parsing\n' >&2
exit 99
EOF
  chmod +x "$bin_dir/git"

  # shellcheck disable=SC2016
  run env PATH="$bin_dir:$PATH" bash -c 'cd "$1" || exit 1; shift; "$@" </dev/null' _ "$non_repo" "$TOOL" "$@"
}

install_git_clean_branches_layout() {
  local install_dir="$1"

  mkdir -p "$install_dir/bin" "$install_dir/lib/picotools"
  cp "$TOOL" "$install_dir/bin/git-clean-branches"
  cp "$REPO_ROOT/VERSION" "$install_dir/VERSION"
  cp "$REPO_ROOT"/lib/picotools/*.sh "$install_dir/lib/picotools/"
}

run_git_clean_branches_with_failure() {
  local failure="$1"
  local repo="$2"
  shift 2

  # shellcheck disable=SC2016
  run env GIT_CLEAN_BRANCHES_FAIL_ON="$failure" bash -c 'cd "$1" || exit 1; shift; "$@" </dev/null' _ "$repo" "$TOOL" "$@"
}

run_git_clean_branches_with_push_log() {
  local repo="$1"
  local push_log="$2"
  shift 2

  # shellcheck disable=SC2016
  run env GIT_CLEAN_BRANCHES_PUSH_LOG="$push_log" bash -c 'cd "$1" || exit 1; shift; "$@" </dev/null' _ "$repo" "$TOOL" "$@"
}

run_git_clean_branches_with_delayed_default_change() {
  local repo="$1"
  local remote="$2"
  local new_default="$3"
  shift 3

  run bash -c 'cd "$1" || exit 1; remote_dir="$2"; new_default="$3"; shift 3; { sleep 1; "$REAL_GIT" -C "$remote_dir" symbolic-ref HEAD "refs/heads/$new_default"; printf "y\n"; } | "$@"' _ "$repo" "$remote" "$new_default" "$TOOL" "$@"
}

run_git_clean_branches_with_delayed_remote_default_rewind() {
  local repo="$1"
  local remote="$2"
  local default_branch="$3"
  shift 3

  run bash -c 'cd "$1" || exit 1; remote_dir="$2"; default_branch="$3"; shift 3; { sleep 1; root_oid=$("$REAL_GIT" -C "$remote_dir" rev-list --max-parents=0 "refs/heads/$default_branch") || exit 1; "$REAL_GIT" -C "$remote_dir" update-ref "refs/heads/$default_branch" "$root_oid" || exit 1; printf "y\n"; } | "$@"' _ "$repo" "$remote" "$default_branch" "$TOOL" "$@"
}

run_git_clean_branches_with_delayed_local_advance() {
  local repo="$1"
  local branch="$2"
  shift 2

  run bash -c 'cd "$1" || exit 1; branch="$2"; shift 2; { sleep 1; old_oid=$("$REAL_GIT" rev-parse "refs/heads/$branch") || exit 1; tree_oid=$("$REAL_GIT" rev-parse HEAD^{tree}) || exit 1; new_oid=$(printf "advanced %s\n" "$branch" | "$REAL_GIT" commit-tree "$tree_oid" -p "$old_oid" -m "advance $branch") || exit 1; "$REAL_GIT" update-ref "refs/heads/$branch" "$new_oid" "$old_oid" || exit 1; printf "y\n"; } | "$@"' _ "$repo" "$branch" "$TOOL" "$@"
}

run_git_clean_branches_with_delayed_local_delete() {
  local repo="$1"
  local branch="$2"
  shift 2

  run bash -c 'cd "$1" || exit 1; branch="$2"; shift 2; { sleep 1; old_oid=$("$REAL_GIT" rev-parse "refs/heads/$branch") || exit 1; "$REAL_GIT" update-ref -d "refs/heads/$branch" "$old_oid" || exit 1; printf "y\n"; } | "$@"' _ "$repo" "$branch" "$TOOL" "$@"
}

run_git_clean_branches_with_delayed_worktree_checkout() {
  local repo="$1"
  local branch="$2"
  local worktree_dir="$3"
  shift 3

  run bash -c 'cd "$1" || exit 1; branch="$2"; worktree_dir="$3"; shift 3; { sleep 1; mkdir -p "$(dirname "$worktree_dir")"; "$REAL_GIT" worktree add -q "$worktree_dir" "$branch" || exit 1; printf "y\n"; } | "$@"' _ "$repo" "$branch" "$worktree_dir" "$TOOL" "$@"
}

run_git_clean_branches_with_delayed_remote_advance() {
  local repo="$1"
  local remote="$2"
  local branch="$3"
  shift 3

  run bash -c 'cd "$1" || exit 1; remote_dir="$2"; branch="$3"; shift 3; { clone_dir="$TMP_HOME/second-clone"; "$REAL_GIT" clone -q "$remote_dir" "$clone_dir" || exit 1; "$REAL_GIT" -C "$clone_dir" config user.name "Second User"; "$REAL_GIT" -C "$clone_dir" config user.email second@example.com; "$REAL_GIT" -C "$clone_dir" checkout -q "$branch" || exit 1; printf "advanced remote\n" >>"$clone_dir/README.md"; "$REAL_GIT" -C "$clone_dir" add README.md; "$REAL_GIT" -C "$clone_dir" commit -q -m "advance $branch" || exit 1; "$REAL_GIT" -C "$clone_dir" push -q origin "HEAD:refs/heads/$branch" || exit 1; printf "y\n"; } | "$@"' _ "$repo" "$remote" "$branch" "$TOOL" "$@"
}

run_git_clean_branches_with_delayed_remote_delete() {
  local repo="$1"
  local remote="$2"
  local branch="$3"
  shift 3

  run bash -c 'cd "$1" || exit 1; remote_dir="$2"; branch="$3"; shift 3; { sleep 1; clone_dir="$TMP_HOME/delete-clone"; "$REAL_GIT" clone -q "$remote_dir" "$clone_dir" || exit 1; "$REAL_GIT" -C "$clone_dir" push -q origin ":refs/heads/$branch" || exit 1; printf "y\n"; } | "$@"' _ "$repo" "$remote" "$branch" "$TOOL" "$@"
}

install_git_clean_branches_failure_wrapper() {
  local bin_dir="$TMP_HOME/bin"

  mkdir -p "$bin_dir"
  cat >"$bin_dir/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${GIT_CLEAN_BRANCHES_FAIL_ON:-}" in
worktree-list)
  if [ "${1:-}" = 'worktree' ] && [ "${2:-}" = 'list' ]; then
    exit 42
  fi
  ;;
local-for-each-ref)
  args=("$@")
  if [ "${1:-}" = 'for-each-ref' ] && [ "${args[$((${#args[@]} - 1))]}" = 'refs/heads' ]; then
    exit 42
  fi
  ;;
remote-for-each-ref)
  if [ "${1:-}" = 'for-each-ref' ]; then
    for arg in "$@"; do
      if [ "$arg" = '--merged' ]; then
        exit 42
      fi
    done
  fi
  ;;
authoritative-default)
  if [ "${1:-}" = 'ls-remote' ] && [ "${2:-}" = '--symref' ]; then
    exit 42
  fi
  ;;
local-update-ref)
  if [ "${1:-}" = 'update-ref' ] && [ "${2:-}" = '--stdin' ]; then
    exit 42
  fi
  ;;
remote-atomic-preflight)
  if [ "${1:-}" = 'push' ]; then
    saw_atomic=false
    saw_dry_run=false
    for arg in "$@"; do
      [ "$arg" = '--atomic' ] && saw_atomic=true
      [ "$arg" = '--dry-run' ] && saw_dry_run=true
    done
    if [ "$saw_atomic" = true ] && [ "$saw_dry_run" = true ]; then
      printf 'fatal: the receiving end does not support --atomic push\n' >&2
      exit 42
    fi
  fi
  ;;
esac

if [ "${1:-}" = 'push' ] && [ -n "${GIT_CLEAN_BRANCHES_PUSH_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$GIT_CLEAN_BRANCHES_PUSH_LOG"
fi

exec "$REAL_GIT" "$@"
EOF
  chmod +x "$bin_dir/git"
  export PATH="$bin_dir:$PATH"
}
