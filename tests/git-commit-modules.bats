#!/usr/bin/env bats

load 'helpers/git-commit'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
PLAN_MODULE="$REPO_ROOT/lib/picotools/git_commit_plan.sh"
WORKSPACE_MODULE="$REPO_ROOT/lib/picotools/git_commit_workspace.sh"
MODEL_MODULE="$REPO_ROOT/lib/picotools/git_commit_model.sh"
# shellcheck disable=SC2034
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  setup_git_commit_test_home
  TMP_DIR="$TMP_HOME"
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"

  mkdir -p "$HOME" "$TMP_DIR/bin"
  ensure_real_jq_on_path "$TMP_DIR/bin"
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

run_plan_validation() {
  local plan_json="$1"
  local create_pr="${2:-false}"
  local scope="${3:-}"

  # shellcheck disable=SC2016
  run env PLAN_JSON="$plan_json" CREATE_PR="$create_pr" SCOPE="$scope" \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; MAX_COMMIT_HEADER_LENGTH=100; changed_files=("a.txt"); run_commit_plan_validation "$PLAN_JSON" changed_files "$CREATE_PR" "$SCOPE"' _ "$PLAN_MODULE"
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
  run env PLAN_JSON='{"commits":[{"type":"feat","message":"add api","files":["src/a.ts"]},{"type":"fix","message":"update tests","files":["src/a.ts"]}]}' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; changed_files=("src/a.ts"); run_commit_plan_validation "$PLAN_JSON" changed_files false' _ "$PLAN_MODULE"

  [ "$status" -ne 0 ] || fail 'run_commit_plan_validation should fail for duplicate files'
  assert_contains "$output" 'assigned the same file to multiple commits' 'should explain the duplicate-file validation failure'
}

@test "git_commit_plan requires exact changed-file paths" {
  # shellcheck disable=SC2016
  run env PLAN_JSON='{"commits":[{"type":"feat","message":"add basename","files":["a.ts"]}]}' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; changed_files=("src/a.ts" "test/a.ts"); run_commit_plan_validation "$PLAN_JSON" changed_files false' _ "$PLAN_MODULE"

  [ "$status" -ne 0 ] || fail 'run_commit_plan_validation should reject basename-only references'
  assert_contains "$output" 'unknown or ambiguous changed file: a.ts' 'should explain exact path validation failure'
}

@test "git_commit_plan accepts exact duplicate basename paths" {
  # shellcheck disable=SC2016
  run env PLAN_JSON='{"commits":[{"type":"feat","message":"add source","files":["src/a.ts"]},{"type":"test","message":"add test","files":["test/a.ts"]}]}' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; changed_files=("src/a.ts" "test/a.ts"); run_commit_plan_validation "$PLAN_JSON" changed_files false' _ "$PLAN_MODULE"

  [ "$status" -eq 0 ] || fail "run_commit_plan_validation should accept exact duplicate basename paths ($output)"
}

@test "git_commit_plan accepts exact newline path strings" {
  local plan_json

  plan_json=$(jq -n --arg file $'dir/new\nline.txt' '{commits:[{type:"feat",message:"add newline path",files:[$file]}]}')

  # shellcheck disable=SC2016
  run env PLAN_JSON="$plan_json" bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; changed_files=($'"'"'dir/new\nline.txt'"'"'); run_commit_plan_validation "$PLAN_JSON" changed_files false' _ "$PLAN_MODULE"

  [ "$status" -eq 0 ] || fail "run_commit_plan_validation should accept exact newline paths ($output)"
}

@test "git_commit_plan rejects invalid commit schema values before coverage validation" {
  local name plan_json

  while IFS='|' read -r name plan_json; do
    [ -n "$name" ] || continue

    run_plan_validation "$plan_json" false
    [ "$status" -ne 0 ] || fail "run_commit_plan_validation should reject $name"
    assert_contains "$output" 'Error:' "schema validation should explain $name"
  done <<'EOF'
root null|null
root boolean|true
root number|1
root array|[]
root empty object|{}
commits missing|{"commitz":[]}
commits null|{"commits":null}
commits boolean|{"commits":true}
commits number|{"commits":1}
commits object|{"commits":{}}
commits empty|{"commits":[]}
commit null|{"commits":[null]}
commit boolean|{"commits":[true]}
commit number|{"commits":[1]}
commit string empty|{"commits":[""]}
commit object empty|{"commits":[{}]}
type missing|{"commits":[{"message":"add file","files":["a.txt"]}]}
type null|{"commits":[{"type":null,"message":"add file","files":["a.txt"]}]}
type boolean|{"commits":[{"type":true,"message":"add file","files":["a.txt"]}]}
type number|{"commits":[{"type":1,"message":"add file","files":["a.txt"]}]}
type object|{"commits":[{"type":{},"message":"add file","files":["a.txt"]}]}
type empty|{"commits":[{"type":"","message":"add file","files":["a.txt"]}]}
message missing|{"commits":[{"type":"feat","files":["a.txt"]}]}
message null|{"commits":[{"type":"feat","message":null,"files":["a.txt"]}]}
message boolean|{"commits":[{"type":"feat","message":true,"files":["a.txt"]}]}
message number|{"commits":[{"type":"feat","message":1,"files":["a.txt"]}]}
message object|{"commits":[{"type":"feat","message":{},"files":["a.txt"]}]}
message empty|{"commits":[{"type":"feat","message":"","files":["a.txt"]}]}
files missing|{"commits":[{"type":"feat","message":"add file"}]}
files null|{"commits":[{"type":"feat","message":"add file","files":null}]}
files boolean|{"commits":[{"type":"feat","message":"add file","files":true}]}
files number|{"commits":[{"type":"feat","message":"add file","files":1}]}
files object|{"commits":[{"type":"feat","message":"add file","files":{}}]}
files empty|{"commits":[{"type":"feat","message":"add file","files":[]}]}
file null|{"commits":[{"type":"feat","message":"add file","files":[null]}]}
file boolean|{"commits":[{"type":"feat","message":"add file","files":[true]}]}
file number|{"commits":[{"type":"feat","message":"add file","files":[1]}]}
file object|{"commits":[{"type":"feat","message":"add file","files":[{}]}]}
file empty|{"commits":[{"type":"feat","message":"add file","files":[""]}]}
EOF
}

@test "git_commit_plan validates PR metadata only for PR plans" {
  local valid_plan='{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}]}'
  local name plan_json

  run_plan_validation "$valid_plan" false
  [ "$status" -eq 0 ] || fail "non-PR plan should not require pull_request metadata ($output)"

  run_plan_validation "$valid_plan" true
  [ "$status" -ne 0 ] || fail 'PR plan should require pull_request metadata'
  assert_contains "$output" 'pull_request must be an object when --pr is used' 'PR validation should require a pull_request object'

  while IFS='|' read -r name plan_json; do
    [ -n "$name" ] || continue

    run_plan_validation "$plan_json" true
    [ "$status" -ne 0 ] || fail "PR validation should reject $name"
    assert_contains "$output" 'Error:' "PR schema validation should explain $name"
  done <<'EOF'
pull_request null|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":null}
pull_request boolean|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":true}
pull_request number|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":1}
pull_request array|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":[]}
pull_request empty object|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{}}
title null|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":null,"body":"body"}}
title boolean|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":true,"body":"body"}}
title number|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":1,"body":"body"}}
title object|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":{},"body":"body"}}
title empty|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":"","body":"body"}}
body null|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":"title","body":null}}
body boolean|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":"title","body":true}}
body number|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":"title","body":1}}
body object|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":"title","body":{}}}
body empty|{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":"title","body":""}}
EOF

  run_plan_validation '{"commits":[{"type":"feat","message":"add file","files":["a.txt"]}],"pull_request":{"title":"title","body":"body"}}' true
  [ "$status" -eq 0 ] || fail "PR plan with metadata should validate ($output)"
}

@test "git_commit_plan enforces message semantics and header feasibility during validation" {
  run_plan_validation '{"commits":[{"type":"bogus","message":"add file","files":["a.txt"]}]}' false
  [ "$status" -ne 0 ] || fail 'run_commit_plan_validation should reject invalid commit types'
  assert_contains "$output" 'invalid commit type in plan: bogus' 'should report invalid commit types'

  run_plan_validation '{"commits":[{"type":"feat","message":"Updated file","files":["a.txt"]}]}' false
  [ "$status" -ne 0 ] || fail 'run_commit_plan_validation should reject invalid message style'
  assert_contains "$output" 'must start with an imperative lower-case verb' 'should report invalid message style'

  run_plan_validation '{"commits":[{"type":"feat","message":"add very long change that cannot fit inside the configured conventional commit header limit","files":["a.txt"]}]}' false longscope
  [ "$status" -ne 0 ] || fail 'run_commit_plan_validation should reject infeasible headers'
  assert_contains "$output" 'header must not exceed 100 characters' 'should report infeasible commit headers'
}

@test "git_commit_plan enforces exact-once path coverage for one and multiple commits" {
  # shellcheck disable=SC2016
  run env PLAN_JSON='{"commits":[{"type":"feat","message":"add files","files":["a.txt","b.txt"]}]}' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; changed_files=("a.txt" "b.txt"); run_commit_plan_validation "$PLAN_JSON" changed_files false' _ "$PLAN_MODULE"
  [ "$status" -eq 0 ] || fail "single-commit exact coverage should validate ($output)"

  # shellcheck disable=SC2016
  run env PLAN_JSON='{"commits":[{"type":"feat","message":"add first","files":["a.txt"]},{"type":"test","message":"add second","files":["b.txt"]}]}' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; changed_files=("a.txt" "b.txt"); run_commit_plan_validation "$PLAN_JSON" changed_files false' _ "$PLAN_MODULE"
  [ "$status" -eq 0 ] || fail "multi-commit exact coverage should validate ($output)"

  # shellcheck disable=SC2016
  run env PLAN_JSON='{"commits":[{"type":"feat","message":"add first","files":["a.txt"]},{"type":"test","message":"add duplicate","files":["a.txt"]}]}' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; changed_files=("a.txt" "b.txt"); run_commit_plan_validation "$PLAN_JSON" changed_files false' _ "$PLAN_MODULE"
  [ "$status" -ne 0 ] || fail 'multi-commit duplicate coverage should be rejected'
  assert_contains "$output" 'assigned the same file to multiple commits' 'should reject duplicate path coverage'

  # shellcheck disable=SC2016
  run env PLAN_JSON='{"commits":[{"type":"feat","message":"add first","files":["a.txt"]}]}' \
    bash -lc '. "$1"; ALLOWED_TYPES="feat fix docs refactor chore perf test ci"; changed_files=("a.txt" "b.txt"); run_commit_plan_validation "$PLAN_JSON" changed_files false' _ "$PLAN_MODULE"
  [ "$status" -ne 0 ] || fail 'single-commit missing coverage should be rejected'
  assert_contains "$output" 'did not cover changed file: b.txt' 'should reject omitted changed paths'
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

@test "git_commit_workspace exposes changed files as JSON without losing escapes" {
  local workspace

  workspace="$TMP_DIR/workspace"
  mkdir -p "$workspace"

  run bash -lc 'set -euo pipefail; mkdir -p "$1"; cd "$1"; git init -q; git config user.name Test; git config user.email test@example.com; printf "one\n" > README.md; git add README.md; git commit -qm init; mkdir -p dir; printf "new\n" > $'"'"'dir/new\nline.txt'"'"'; printf "tab\n" > $'"'"'dir/tab\tname.txt'"'"'; printf "slash\n" > $'"'"'dir/back\\slash.txt'"'"'; debug_log() { :; }; . "$2"; collect_changed_files_into files; changed_files_json_array files' bash "$workspace" "$WORKSPACE_MODULE"

  [ "$status" -eq 0 ] || fail "collect_changed_files_into should succeed ($output)"
  assert_contains "$output" 'dir/new\nline.txt' 'JSON array should escape newline filenames'
  assert_contains "$output" 'dir/tab\tname.txt' 'JSON array should escape tab filenames'
  assert_contains "$output" 'dir/back\\slash.txt' 'JSON array should escape backslash filenames'
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
