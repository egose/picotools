#!/usr/bin/env bats

load 'helpers/git-commit'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-commit"
# shellcheck disable=SC2034
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  setup_git_commit_test_home
  ensure_real_jq_on_path "$TMP_HOME/bin"
  export PATH="$TMP_HOME/bin:$PATH"
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

assert_file_missing() {
  local path="$1"
  local message="$2"

  [ ! -e "$path" ] || fail "$message ($path)"
}

write_git_commit_config() {
  mkdir -p "$GIT_COMMIT_CONFIG_DIR"
  cat >"$GIT_COMMIT_CONFIG_DIR/config" <<'EOF'
[model]
	profile = alpha-profile
	name = alpha-model
EOF
}

create_model_provider_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
ask)
  printf '%s\n' "$MODEL_PROFILE_ASK_RESPONSE"
  ;;
*)
  exit 1
  ;;
esac
EOF
  chmod +x "$stub_path"
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

install_hook() {
  local repo="$1"
  local hook_body="$2"

  mkdir -p "$repo/.git/hooks"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "$hook_body" >"$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
}

@test "preliminary hook uses only selected paths from nested working directory" {
  local repo model_stub hook_log status_after committed_files head_subject

  repo="$TMP_HOME/repo"
  model_stub="$TMP_HOME/model-profile"
  hook_log="$TMP_HOME/hook.log"
  create_model_provider_stub "$model_stub"
  init_repo "$repo"
  create_initial_commit "$repo"
  mkdir -p "$repo/src"
  printf '%s\n' 'selected' >"$repo/src/selected.txt"
  printf '%s\n' 'deleted' >"$repo/src/deleted.txt"
  printf '%s\n' 'unrelated' >"$repo/unrelated.txt"
  git -C "$repo" add src/selected.txt src/deleted.txt unrelated.txt
  git -C "$repo" commit -q -m 'chore: add files'
  printf '%s\n' 'selected update' >>"$repo/src/selected.txt"
  rm "$repo/src/deleted.txt"
  printf '%s\n' 'unrelated update' >>"$repo/unrelated.txt"
  printf '%s\n' 'new outside file' >"$repo/bad.sh"
  install_hook "$repo" "cat >\"\$HOOK_LOG\" <<EOF
PWD=\$(pwd -P)
EOF
git diff --cached --name-status --no-renames >>\"\$HOOK_LOG\"
cached=\$(git diff --cached --name-only)
case \"\$cached\" in
*unrelated.txt* | *bad.sh*)
  printf 'unrelated path was staged: %s\\n' \"\$cached\" >&2
  exit 1
  ;;
esac"
  write_git_commit_config

  (cd "$repo/src" && HOOK_LOG="$hook_log" MODEL_PROFILE_BIN="$model_stub" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update selected files","files":["src/selected.txt","src/deleted.txt"]}]}' \
    "$TOOL" --apply --no-scope --path selected.txt --path deleted.txt >/dev/null)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat: update selected files' 'git-commit should create the scoped commit after hook checks'
  assert_contains "$(<"$hook_log")" "PWD=$repo" 'preliminary hook should run from the repository root'
  assert_contains "$(<"$hook_log")" $'M\tsrc/selected.txt' 'preliminary hook should see the selected modification'
  assert_contains "$(<"$hook_log")" $'D\tsrc/deleted.txt' 'preliminary hook should see the selected deletion'
  assert_not_contains "$(<"$hook_log")" 'unrelated.txt' 'preliminary hook should not see unrelated tracked changes'
  assert_not_contains "$(<"$hook_log")" 'bad.sh' 'preliminary hook should not see unrelated untracked files'
  status_after=$(git -C "$repo" status --short)
  assert_contains "$status_after" ' M unrelated.txt' 'unrelated tracked changes should remain in the worktree'
  assert_contains "$status_after" '?? bad.sh' 'unrelated untracked files should remain untracked'
  committed_files=$(git -C "$repo" show --name-only --pretty=format: HEAD)
  assert_contains "$committed_files" 'src/selected.txt' 'selected modification should be committed'
  assert_contains "$committed_files" 'src/deleted.txt' 'selected deletion should be committed'
  assert_not_contains "$committed_files" 'unrelated.txt' 'unrelated tracked changes should not be committed'
  assert_not_contains "$committed_files" 'bad.sh' 'unrelated untracked files should not be committed'
}

@test "unborn repository can create initial commit with successful preliminary hook" {
  local repo model_stub hook_log head_subject

  repo="$TMP_HOME/unborn"
  model_stub="$TMP_HOME/model-profile"
  hook_log="$TMP_HOME/unborn-hook.log"
  create_model_provider_stub "$model_stub"
  init_repo "$repo"
  printf '%s\n' 'initial content' >"$repo/README.md"
  install_hook "$repo" "git diff --cached --name-status --no-renames >\"\$HOOK_LOG\""
  write_git_commit_config

  (cd "$repo" && HOOK_LOG="$hook_log" MODEL_PROFILE_BIN="$model_stub" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add readme","files":["README.md"]}]}' \
    "$TOOL" --apply --no-scope >/dev/null)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat: add readme' 'git-commit should create an initial commit in an unborn repository'
  assert_contains "$(<"$hook_log")" $'A\tREADME.md' 'preliminary hook should see the unborn repository staged addition'
}

@test "split-index repositories fail before running preliminary hook" {
  local repo model_stub output head_before

  repo="$TMP_HOME/split"
  model_stub="$TMP_HOME/model-profile"
  create_model_provider_stub "$model_stub"
  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" config core.splitIndex true
  git -C "$repo" update-index --split-index
  printf '%s\n' 'updated' >>"$repo/README.md"
  install_hook "$repo" "printf '%s\\n' mutation >hook-side-effect.txt"
  write_git_commit_config
  head_before=$(git -C "$repo" rev-parse HEAD)

  if output=$(cd "$repo" && MODEL_PROFILE_BIN="$model_stub" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --apply --no-scope 2>&1); then
    fail 'git-commit should fail closed before running hooks in split-index repositories'
  fi

  assert_contains "$output" 'Error: preliminary pre-commit checks do not support split-index repositories.' 'git-commit should report the unsupported split-index boundary'
  assert_file_missing "$repo/hook-side-effect.txt" 'preliminary hook should not run after split-index rejection'
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" 'split-index rejection should not create a commit'
}

@test "preview mode does not execute repository-controlled preliminary hooks" {
  local repo model_stub output

  repo="$TMP_HOME/preview"
  model_stub="$TMP_HOME/model-profile"
  create_model_provider_stub "$model_stub"
  init_repo "$repo"
  create_initial_commit "$repo"
  printf '%s\n' 'updated' >>"$repo/README.md"
  install_hook "$repo" "printf '%s\\n' side-effect >preview-side-effect.txt"
  write_git_commit_config

  output=$(cd "$repo" && MODEL_PROFILE_BIN="$model_stub" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --no-scope 2>&1)

  assert_contains "$output" 'git add -A --' 'preview should still render the planned git commands'
  assert_file_missing "$repo/preview-side-effect.txt" 'preview mode should not execute repository-controlled hooks'
}

@test "preliminary hook out-of-scope worktree mutation is rejected" {
  local repo model_stub output head_before status_after

  repo="$TMP_HOME/out-of-scope"
  model_stub="$TMP_HOME/model-profile"
  create_model_provider_stub "$model_stub"
  init_repo "$repo"
  create_initial_commit "$repo"
  printf '%s\n' 'updated' >>"$repo/README.md"
  install_hook "$repo" "printf '%s\\n' generated >generated.txt"
  write_git_commit_config
  head_before=$(git -C "$repo" rev-parse HEAD)

  if output=$(cd "$repo" && MODEL_PROFILE_BIN="$model_stub" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --apply --no-scope 2>&1); then
    fail 'git-commit should reject out-of-scope preliminary hook mutations'
  fi

  status_after=$(git -C "$repo" status --short)
  assert_contains "$output" 'Error: preliminary pre-commit hook changed files outside the selected scope.' 'git-commit should report out-of-scope hook-created paths'
  assert_contains "$status_after" ' M README.md' 'selected worktree change should remain after rejection'
  assert_contains "$status_after" '?? generated.txt' 'hook-created out-of-scope file should remain untracked for review'
  assert_eq "$(git -C "$repo" diff --cached --name-only)" '' 'out-of-scope hook mutation should not be staged'
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" 'out-of-scope hook mutation should not be committed'
}
