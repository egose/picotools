#!/usr/bin/env bats

load 'helpers/git-commit'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-commit"
# shellcheck disable=SC2034
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  setup_git_commit_test_home
}

teardown() {
  teardown_git_commit_test_home
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  [ "$actual" = "$expected" ] || fail "$message (expected '$expected', got '$actual')"
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

write_git_commit_config() {
  mkdir -p "$GIT_COMMIT_CONFIG_DIR"
  cat >"$GIT_COMMIT_CONFIG_DIR/config" <<'EOF'
[model]
	profile = alpha-profile
	name = alpha-model
[git-api]
	profile = test-profile
EOF
}

init_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.name 'Test User'
  git -C "$repo" config user.email 'test@example.com'
  printf '%s\n' 'initial' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m 'chore(init): initial commit'
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

create_model_provider_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
ask)
  case "${MODEL_PROFILE_MUTATION:-}" in
  stage-unrelated)
    printf '%s\n' 'secret' >unrelated-secret.txt
    git add unrelated-secret.txt
    ;;
  mutate-readme)
    printf '%s\n' 'mutated during model call' >>README.md
    ;;
  create-selected)
    printf '%s\n' 'created during model call' >dir/new.txt
    ;;
  delete-selected)
    rm -f dir/a.txt
    ;;
  rename-selected)
    mv dir/a.txt dir/b.txt
    ;;
  esac
  printf '%s\n' "$MODEL_PROFILE_ASK_RESPONSE"
  ;;
*)
  exit 1
  ;;
esac
EOF
  chmod +x "$stub_path"
}

create_git_api_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while [ "$#" -gt 0 ]; do
  case "${1:-}" in
  --debug)
    shift
    ;;
  --profile)
    shift 2
    ;;
  --token-stdin)
    cat >/dev/null
    shift
    ;;
  *)
    break
    ;;
  esac
done

case "${1:-}" in
repos/get)
  printf '%s\n' '{"default_branch":"main"}'
  ;;
pulls/list)
  printf '%s\n' '[]'
  ;;
pulls/create)
  if [ "${GIT_API_FAIL_CREATE:-false}" = 'true' ]; then
    printf '%s\n' 'create failed' >&2
    exit 1
  fi
  printf '%s\n' '{"html_url":"https://github.com/octo/demo/pull/42"}'
  ;;
*)
  exit 1
  ;;
esac
EOF
  chmod +x "$stub_path"
}

create_git_profile_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'Error: no git profile is recorded in this repository' >&2
exit 1
EOF
  chmod +x "$stub_path"
}

create_git_wrapper() {
  local wrapper_path="$1"

  cat >"$wrapper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${GIT_WRAPPER_LOG:-}" ]; then
  printf '%s\n' 'ARGV_BEGIN' >>"$GIT_WRAPPER_LOG"
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$GIT_WRAPPER_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$GIT_WRAPPER_LOG"
fi

for arg in "$@"; do
  if [ "$arg" = 'commit-tree' ] && [ -n "${GIT_COMMIT_TREE_FAIL_AT:-}" ]; then
    count=1
    if [ -f "$GIT_COMMIT_TREE_COUNT_FILE" ]; then
      count=$(( $(<"$GIT_COMMIT_TREE_COUNT_FILE") + 1 ))
    fi
    printf '%s\n' "$count" >"$GIT_COMMIT_TREE_COUNT_FILE"
    if [ "$count" = "$GIT_COMMIT_TREE_FAIL_AT" ]; then
      printf 'injected commit-tree failure at %s\n' "$count" >&2
      exit 1
    fi
    break
  fi
done

exec "$REAL_GIT" "$@"
EOF
  chmod +x "$wrapper_path"
}

setup_state_repo() {
  local repo="$1"

  mkdir -p "$TMP_HOME/bin"
  REAL_GIT="$(command -v git)"
  MODEL_PROFILE_STUB="$TMP_HOME/model-profile"
  GIT_API_STUB="$TMP_HOME/git-api"
  GIT_PROFILE_STUB="$TMP_HOME/git-profile"
  GIT_COMMIT_TREE_COUNT_FILE="$TMP_HOME/commit-tree-count"
  GIT_WRAPPER_LOG="$TMP_HOME/git-wrapper.log"
  export REAL_GIT MODEL_PROFILE_STUB GIT_API_STUB GIT_PROFILE_STUB GIT_COMMIT_TREE_COUNT_FILE GIT_WRAPPER_LOG
  create_model_provider_stub "$MODEL_PROFILE_STUB"
  create_git_api_stub "$GIT_API_STUB"
  create_git_profile_stub "$GIT_PROFILE_STUB"
  create_git_wrapper "$TMP_HOME/bin/git"
  ensure_real_jq_on_path "$TMP_HOME/bin"
  init_repo "$repo"
  write_git_commit_config
}

run_tool_in_repo() {
  local repo="$1"
  shift

  cd "$repo" || return 1
  PATH="$TMP_HOME/bin:$PATH" \
    REAL_GIT="$REAL_GIT" \
    MODEL_PROFILE_BIN="$MODEL_PROFILE_STUB" \
    GIT_API_BIN="$GIT_API_STUB" \
    GIT_PROFILE_BIN="$GIT_PROFILE_STUB" \
    GIT_COMMIT_TREE_COUNT_FILE="$GIT_COMMIT_TREE_COUNT_FILE" \
    GIT_COMMIT_TREE_FAIL_AT="${GIT_COMMIT_TREE_FAIL_AT:-}" \
    GIT_API_FAIL_CREATE="${GIT_API_FAIL_CREATE:-false}" \
    GIT_WRAPPER_LOG="$GIT_WRAPPER_LOG" \
    "$TOOL" "$@"
}

commit_files() {
  local repo="$1"
  local revision="$2"

  git -C "$repo" diff-tree --no-commit-id --name-only -r "$revision"
}

@test "model-staged unrelated file fails before any commit" {
  local repo output before_count after_count secret_log

  repo="$TMP_HOME/repo"
  setup_state_repo "$repo"
  printf '%s\n' 'changed' >>"$repo/README.md"
  before_count=$(git -C "$repo" rev-list --count HEAD)

  if output=$(MODEL_PROFILE_MUTATION=stage-unrelated \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    run_tool_in_repo "$repo" --apply 2>&1); then
    fail 'git-commit should reject a model-side staged unrelated file'
  fi

  after_count=$(git -C "$repo" rev-list --count HEAD)
  secret_log=$(git -C "$repo" log --all --format= --name-only -- unrelated-secret.txt)
  assert_eq "$after_count" "$before_count" 'stale index rejection must happen before commit'
  assert_eq "$secret_log" '' 'unrelated staged path must never be committed'
  assert_contains "$output" 'real Git index changed after git-commit planning started' 'failure should identify stale real index'
}

@test "selected file content mutation during model execution is rejected as stale" {
  local repo output before_subject staged_after

  repo="$TMP_HOME/repo"
  setup_state_repo "$repo"
  before_subject=$(git -C "$repo" log -1 --pretty=%s)
  printf '%s\n' 'changed' >>"$repo/README.md"

  if output=$(MODEL_PROFILE_MUTATION=mutate-readme \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    run_tool_in_repo "$repo" --apply 2>&1); then
    fail 'git-commit should reject content changed during planning'
  fi

  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_eq "$(git -C "$repo" log -1 --pretty=%s)" "$before_subject" 'stale content rejection must not create a commit'
  assert_eq "$staged_after" '' 'stale content rejection must leave the real index empty'
  assert_contains "$output" 'selected file contents changed after the plan was generated' 'failure should identify stale content'
}

@test "new deleted and renamed selected paths after planning are rejected" {
  local repo output action before_count after_count

  for action in create-selected delete-selected rename-selected; do
    repo="$TMP_HOME/repo-$action"
    setup_state_repo "$repo"
    mkdir -p "$repo/dir"
    printf '%s\n' 'base' >"$repo/dir/a.txt"
    git -C "$repo" add dir/a.txt
    git -C "$repo" commit -q -m 'chore: add selected file'
    printf '%s\n' 'changed' >>"$repo/dir/a.txt"
    before_count=$(git -C "$repo" rev-list --count HEAD)

    if output=$(MODEL_PROFILE_MUTATION="$action" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update selected file","files":["dir/a.txt"]}]}' \
      run_tool_in_repo "$repo" --apply --path dir 2>&1); then
      fail "git-commit should reject $action after planning"
    fi

    after_count=$(git -C "$repo" rev-list --count HEAD)
    assert_eq "$after_count" "$before_count" "$action rejection must not create a commit"
    assert_contains "$output" 'Error: stale commit plan:' "$action should report stale selected state"
  done
}

@test "commit hook cannot move a later planned file into the current commit" {
  local repo output first_commit_files second_commit_files

  repo="$TMP_HOME/repo"
  setup_state_repo "$repo"
  printf '%s\n' 'first' >"$repo/first.txt"
  printf '%s\n' 'second' >"$repo/second.txt"
  mkdir -p "$repo/.git/hooks"
  cat >"$repo/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git add second.txt
EOF
  chmod +x "$repo/.git/hooks/pre-commit"

  if ! output=$(MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add first file","files":["first.txt"]},{"type":"feat","message":"add second file","files":["second.txt"]}]}' \
    run_tool_in_repo "$repo" --apply 2>&1); then
    fail "git-commit should isolate planned commits from hook staging ($output)"
  fi

  first_commit_files=$(commit_files "$repo" HEAD~1)
  second_commit_files=$(commit_files "$repo" HEAD)
  assert_eq "$first_commit_files" 'first.txt' 'first planned commit must contain only the first file'
  assert_eq "$second_commit_files" 'second.txt' 'second planned commit must contain only the later file'
}

@test "injected commit 1 failure leaves no commits empty index and recovery guidance" {
  local repo output before_count after_count staged_after status_after

  repo="$TMP_HOME/repo"
  setup_state_repo "$repo"
  printf '%s\n' 'first' >"$repo/first.txt"
  printf '%s\n' 'second' >"$repo/second.txt"
  before_count=$(git -C "$repo" rev-list --count HEAD)

  if output=$(GIT_COMMIT_TREE_FAIL_AT=1 \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add first file","files":["first.txt"]},{"type":"feat","message":"add second file","files":["second.txt"]}]}' \
    run_tool_in_repo "$repo" --apply 2>&1); then
    fail "git-commit should fail when commit 1 creation is injected to fail ($(sed ':a;N;$!ba;s/\n/; /g' "$GIT_WRAPPER_LOG"))"
  fi

  after_count=$(git -C "$repo" rev-list --count HEAD)
  staged_after=$(git -C "$repo" diff --cached --name-only)
  status_after=$(git -C "$repo" status --short)
  assert_eq "$after_count" "$before_count" 'commit 1 failure must not create commits'
  assert_eq "$staged_after" '' 'commit 1 failure must leave an empty real index'
  assert_contains "$status_after" '?? first.txt' 'commit 1 failure should leave first file in worktree'
  assert_contains "$status_after" '?? second.txt' 'commit 1 failure should leave second file in worktree'
  assert_contains "$output" 'State: no planned commits were created; the real index is empty' 'commit 1 failure should print exact state'
  assert_contains "$output" 'Recovery: fix the reported error, then re-run git-commit --apply.' 'commit 1 failure should print recovery guidance'
}

@test "injected commit 2 failure leaves first commit empty index and recovery guidance" {
  local repo output staged_after status_after

  repo="$TMP_HOME/repo"
  setup_state_repo "$repo"
  printf '%s\n' 'first' >"$repo/first.txt"
  printf '%s\n' 'second' >"$repo/second.txt"

  if output=$(GIT_COMMIT_TREE_FAIL_AT=2 \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add first file","files":["first.txt"]},{"type":"feat","message":"add second file","files":["second.txt"]}]}' \
    run_tool_in_repo "$repo" --apply 2>&1); then
    fail "git-commit should fail when commit 2 creation is injected to fail ($(sed ':a;N;$!ba;s/\n/; /g' "$GIT_WRAPPER_LOG"))"
  fi

  staged_after=$(git -C "$repo" diff --cached --name-only)
  status_after=$(git -C "$repo" status --short)
  assert_eq "$(git -C "$repo" log -1 --pretty=%s)" 'feat: add first file' 'commit 2 failure should preserve the first planned commit at HEAD'
  assert_eq "$staged_after" '' 'commit 2 failure must leave an empty real index'
  assert_not_contains "$status_after" 'first.txt' 'committed first file should not remain changed'
  assert_contains "$status_after" '?? second.txt' 'uncommitted second file should remain in worktree'
  assert_contains "$output" 'State: HEAD contains the first 1 planned commit(s); the real index is empty' 'commit 2 failure should print exact state'
  assert_contains "$output" 'reset only your local commits before re-running git-commit' 'commit 2 failure should print partial-apply recovery guidance'
}

@test "push failure preserves local commit and rejected remote state" {
  local remote repo output remote_branch_status

  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  setup_state_repo "$repo"
  rm -rf "$repo"
  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/state
  cat >"$remote/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$remote/hooks/pre-receive"
  printf '%s\n' 'changed' >>"$repo/README.md"

  if output=$(MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    run_tool_in_repo "$repo" --push 2>&1); then
    fail 'git-commit should fail when push is rejected'
  fi

  assert_eq "$(git -C "$repo" log -1 --pretty=%s)" 'feat(state): update readme' 'push failure should preserve local commit'
  if git -C "$remote" show-ref --verify --quiet refs/heads/feat/state; then
    remote_branch_status='present'
  else
    remote_branch_status='missing'
  fi
  assert_eq "$remote_branch_status" 'missing' 'rejected push should not create the remote branch'
  assert_contains "$output" 'Error: push failed after local commits were created.' 'push failure should print preservation contract'
}

@test "pull request failure preserves pushed branch and local state" {
  local remote repo output remote_subject

  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  setup_state_repo "$repo"
  rm -rf "$repo"
  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/state
  printf '%s\n' 'changed' >>"$repo/README.md"

  if output=$(GIT_API_FAIL_CREATE=true \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat: update readme","body":"## Summary\n- update readme"}}' \
    run_tool_in_repo "$repo" --pr 2>&1); then
    fail 'git-commit should fail when PR creation fails'
  fi

  remote_subject=$(git -C "$remote" log -1 --pretty=%s refs/heads/feat/state)
  assert_eq "$(git -C "$repo" log -1 --pretty=%s)" 'feat(state): update readme' 'PR failure should preserve local commit'
  assert_eq "$remote_subject" 'feat(state): update readme' 'PR failure should preserve pushed remote branch'
  assert_contains "$output" 'Error: pull request operation failed after local commits were pushed.' 'PR failure should print preservation contract'
}
