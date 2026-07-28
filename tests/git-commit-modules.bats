#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
PLAN_MODULE="$REPO_ROOT/lib/picotools/git_commit_plan.sh"
WORKSPACE_MODULE="$REPO_ROOT/lib/picotools/git_commit_workspace.sh"
MODEL_MODULE="$REPO_ROOT/lib/picotools/git_commit_model.sh"
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export HOME="$TMP_DIR/home"
  export PATH="$TMP_DIR/bin:$PATH"

  mkdir -p "$HOME" "$TMP_DIR/bin"
  ln -s "$REAL_JQ_BIN" "$TMP_DIR/bin/jq"
}

teardown() {
  rm -rf "$TMP_DIR"
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

@test "git_commit_plan extracts JSON from fenced responses" {
  # shellcheck disable=SC2016
  run env RAW_INPUT=$'```json\n{"commits":[{"type":"feat","message":"add tests","files":["a.txt"]}]}\n```' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; extract_commit_plan_json "$RAW_INPUT"' _ "$PLAN_MODULE"

  [ "$status" -eq 0 ] || fail 'extract_commit_plan_json should succeed'
  assert_eq "$output" '{"commits":[{"type":"feat","message":"add tests","files":["a.txt"]}]}' 'should strip markdown fences and return raw JSON'
}

@test "git_commit_plan validation reports duplicate file assignments" {
  # shellcheck disable=SC2016
  run env PLAN_JSON='{"commits":[{"type":"feat","message":"add api","files":["src/a.ts"]},{"type":"fix","message":"update tests","files":["src/a.ts"]}]}' CHANGED_FILES=$'src/a.ts\n' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; run_commit_plan_validation "$PLAN_JSON" "$CHANGED_FILES" false' _ "$PLAN_MODULE"

  [ "$status" -ne 0 ] || fail 'run_commit_plan_validation should fail for duplicate files'
  assert_contains "$output" 'assigned the same file to multiple commits' 'should explain the duplicate-file validation failure'
}

@test "git_commit_workspace collects tracked and untracked changed files" {
  local workspace

  workspace="$TMP_DIR/workspace"
  mkdir -p "$workspace"

  run bash -lc 'set -euo pipefail; mkdir -p "$1"; cd "$1"; git init -q; git config user.name Test; git config user.email test@example.com; printf "one\n" > tracked.txt; git add tracked.txt; git commit -qm init; printf "two\n" > tracked.txt; printf "new\n" > untracked.txt; debug_log() { :; }; MAX_COMMIT_PLAN_ADDED_FILE_BYTES=65536; MAX_COMMIT_PLAN_FILE_DIFF_CHARS=16384; MAX_COMMIT_PLAN_DIFF_CHARS=50000; . "$2"; collect_changed_files' bash "$workspace" "$WORKSPACE_MODULE"

  [ "$status" -eq 0 ] || fail 'collect_changed_files should succeed'
  assert_contains "$output" 'tracked.txt' 'should include modified tracked files'
  assert_contains "$output" 'untracked.txt' 'should include untracked files'
}

@test "git_commit_workspace truncates oversized prompt sections with a notice" {
  run bash -lc 'debug_log() { :; }; . "$1"; truncate_commit_plan_section diff abcdefghij 8' bash "$WORKSPACE_MODULE"

  [ "$status" -eq 0 ] || fail 'truncate_commit_plan_section should succeed'
  assert_contains "$output" '[Truncated diff to fit provider message limits.]' 'should append a truncation notice'
}

@test "git_commit_model retries with the additional profile on HTTP 429" {
  run bash -lc 'set -euo pipefail; TMP_DIR="$1"; debug_log() { :; }; GIT_COMMIT_TMPFILES=(); register_tmpfile() { GIT_COMMIT_TMPFILES+=("$1"); }; cleanup_tmpfiles() { if [ "${#GIT_COMMIT_TMPFILES[@]}" -gt 0 ]; then rm -f "${GIT_COMMIT_TMPFILES[@]}"; fi; }; run_model_profile() { if [ "$2" = primary ]; then printf "Error: request failed with HTTP 429\n" >&2; return 1; fi; printf "{\"commits\":[{\"type\":\"feat\",\"message\":\"add fallback\",\"files\":[\"a.txt\"]}]}\n"; }; . "$2"; request_commit_plan primary model-a secondary model-b system user' bash "$TMP_DIR" "$MODEL_MODULE"

  [ "$status" -eq 0 ] || fail 'request_commit_plan should retry with the additional profile on HTTP 429'
  assert_contains "$output" '"add fallback"' 'should return the successful fallback model response'
}
