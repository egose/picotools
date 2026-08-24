#!/usr/bin/env bats

load 'helpers/git-commit'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-commit"
# shellcheck disable=SC2034
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  setup_git_commit_test_home
  mkdir -p "$HOME" "$GIT_COMMIT_CONFIG_DIR"
  ensure_real_jq_on_path "$TMP_HOME"
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

create_model_provider_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

debug_requested=false
if [ "${1:-}" = '--debug' ]; then
  debug_requested=true
  shift
fi

case "${1:-}" in
profiles)
  printf '%s\n' alpha-profile
  ;;
models)
  printf '%s\n' alpha-model
  ;;
ask)
  if [ "$debug_requested" = 'true' ]; then
    printf '%s\n' '[model-profile] Stub debug enabled' >&2
  fi
  if [ -n "${MODEL_PROFILE_ASK_ARGS_LOG:-}" ]; then
    printf '%s\n' 'ARGV_BEGIN' >"$MODEL_PROFILE_ASK_ARGS_LOG"
    for arg in "$@"; do
      printf '%q\n' "$arg" >>"$MODEL_PROFILE_ASK_ARGS_LOG"
    done
    printf '%s\n' 'ARGV_END' >>"$MODEL_PROFILE_ASK_ARGS_LOG"
  fi
  if [ -n "${MODEL_PROFILE_ASK_RESPONSE_FILE:-}" ]; then
    cat "$MODEL_PROFILE_ASK_RESPONSE_FILE"
    exit 0
  fi
  printf '%s\n' "${MODEL_PROFILE_ASK_RESPONSE:-}"
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
  git -C "$repo" init -q
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.com
  printf 'initial\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm 'chore(init): initial commit'
  git -C "$repo" checkout -q -b feat/11222
}

write_git_commit_config() {
  local file="$GIT_COMMIT_CONFIG_DIR/config"

  git config -f "$file" model.profile alpha-profile
  git config -f "$file" model.name alpha-model
}

assert_tmpdir_empty() {
  local tmpdir="$1"
  local message="$2"
  local -a leftovers=()

  shopt -s nullglob dotglob
  leftovers=("$tmpdir"/*)
  shopt -u nullglob dotglob
  assert_eq "${#leftovers[@]}" '0' "$message"
}

@test "malformed model output is not exposed in normal diagnostics and temp files are cleaned" {
  local stub_path repo output run_tmpdir secret

  stub_path="$TMP_HOME/model-profile"
  repo="$TMP_HOME/repo"
  run_tmpdir="$TMP_HOME/git-commit-tmp"
  secret='sentinel-secret-12345'
  mkdir -p "$run_tmpdir"
  create_model_provider_stub "$stub_path"
  init_repo "$repo"
  printf 'contains secret-shaped text\n' >>"$repo/README.md"
  write_git_commit_config

  if output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      TMPDIR="$run_tmpdir" \
      MODEL_PROFILE_BIN="$stub_path" \
      SENTINEL_SECRET="$secret" \
      MODEL_PROFILE_ASK_RESPONSE=$'not-json sentinel-secret-12345 \033[31mred\a' \
      "$TOOL" 2>&1
  ); then
    fail 'git-commit should fail when every model attempt returns invalid JSON'
  fi

  assert_contains "$output" 'Error: model-profile ask did not return valid commit plan JSON' 'normal diagnostics should report a stable validation failure'
  assert_not_contains "$output" "$secret" 'normal diagnostics should not expose secret bytes from model output'
  assert_not_contains "$output" $'\033' 'normal diagnostics should not expose terminal control bytes from model output'
  assert_not_contains "$output" 'Raw model response:' 'normal diagnostics should not include raw model output'
  assert_tmpdir_empty "$run_tmpdir" 'prompt and diagnostic temp files should be removed after failure'
}

@test "debug model diagnostics are redacted escaped and truncated" {
  local stub_path repo output secret

  stub_path="$TMP_HOME/model-profile"
  repo="$TMP_HOME/repo"
  secret='sentinel-secret-12345'
  create_model_provider_stub "$stub_path"
  init_repo "$repo"
  printf 'change\n' >>"$repo/README.md"
  write_git_commit_config

  if output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      GIT_COMMIT_MODEL_DIAGNOSTIC_MAX_BYTES=64 \
      SENTINEL_SECRET="$secret" \
      MODEL_PROFILE_ASK_RESPONSE=$'not-json sentinel-secret-12345 \033[31mred\a xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \
      "$TOOL" --debug 2>&1
  ); then
    fail 'git-commit should fail when debugged model output is invalid JSON'
  fi

  assert_contains "$output" 'Model response diagnostic (redacted, JSON-escaped, max 64 bytes):' 'debug diagnostics should document their formatting contract'
  assert_contains "$output" '[REDACTED]' 'debug diagnostics should redact known secret environment values'
  assert_contains "$output" '\u001b' 'debug diagnostics should JSON-escape ANSI escape bytes'
  assert_contains "$output" '\u0007' 'debug diagnostics should JSON-escape control bytes'
  assert_contains "$output" 'truncated to 64' 'debug diagnostics should report truncation'
  assert_not_contains "$output" "$secret" 'debug diagnostics should not expose secret bytes'
}

@test "oversized model responses fail with bounded output and temp cleanup" {
  local stub_path repo output response_file run_tmpdir large_response

  stub_path="$TMP_HOME/model-profile"
  repo="$TMP_HOME/repo"
  response_file="$TMP_HOME/large-response.txt"
  run_tmpdir="$TMP_HOME/git-commit-tmp"
  mkdir -p "$run_tmpdir"
  create_model_provider_stub "$stub_path"
  init_repo "$repo"
  printf 'change\n' >>"$repo/README.md"
  write_git_commit_config
  printf -v large_response '%*s' 2048 ''
  printf '%s' "${large_response// /x}" >"$response_file"

  if output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      TMPDIR="$run_tmpdir" \
      MODEL_PROFILE_BIN="$stub_path" \
      GIT_COMMIT_MODEL_RESPONSE_MAX_BYTES=128 \
      MODEL_PROFILE_ASK_RESPONSE_FILE="$response_file" \
      "$TOOL" 2>&1
  ); then
    fail 'git-commit should fail when the provider response exceeds the configured byte limit'
  fi

  assert_contains "$output" 'Error: model response exceeded 128 bytes' 'oversized responses should fail with a stable bounded diagnostic'
  [ "${#output}" -lt 512 ] || fail "oversized response diagnostic should stay bounded (${#output} bytes)"
  assert_not_contains "$output" 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' 'oversized response should not be printed'
  assert_tmpdir_empty "$run_tmpdir" 'prompt and diagnostic temp files should be removed after oversized-response failure'
}

@test "prompt content is passed by file not argv and temp files are cleaned after success" {
  local stub_path repo output ask_log run_tmpdir

  stub_path="$TMP_HOME/model-profile"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-args.log"
  run_tmpdir="$TMP_HOME/git-commit-tmp"
  mkdir -p "$run_tmpdir"
  create_model_provider_stub "$stub_path"
  init_repo "$repo"
  printf 'prompt-secret-value\n' >>"$repo/README.md"
  write_git_commit_config

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      TMPDIR="$run_tmpdir" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should succeed with a valid model response ($output)"
  fi

  assert_contains "$(<"$ask_log")" '--system-message-file' 'system prompt should be passed by file path'
  assert_contains "$(<"$ask_log")" '--message-file' 'user prompt should be passed by file path'
  assert_not_contains "$(<"$ask_log")" 'prompt-secret-value' 'prompt contents should not appear in model-profile argv'
  assert_tmpdir_empty "$run_tmpdir" 'prompt and diagnostic temp files should be removed after success'
}
