#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-commit"

setup() {
  TMP_HOME="$(mktemp -d)" || return 1
  export TMP_HOME
  export HOME="$TMP_HOME"
  export XDG_CONFIG_HOME="$TMP_HOME/.config"
  export GIT_COMMIT_CONFIG_DIR="$XDG_CONFIG_HOME/git-commit"
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

assert_file_exists() {
  local path="$1"
  local message="$2"

  [ -f "$path" ] || fail "$message ($path)"
}

git_commit_config_file() {
  printf '%s/config\n' "$GIT_COMMIT_CONFIG_DIR"
}

assert_config_value() {
  local key="$1"
  local expected="$2"
  local message="$3"

  assert_eq "$(git config -f "$(git_commit_config_file)" --get "$key")" "$expected" "$message"
}

create_model_provider_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
profiles)
  printf '%s\n' alpha-profile beta-profile
  ;;
models)
  case "${2:-}" in
  alpha-profile)
    printf '%s\n' alpha-model alpha-model-2
    ;;
  beta-profile)
    printf '%s\n' beta-model beta-model-2
    ;;
  esac
  ;;
ask)
  if [ -n "${MODEL_PROVIDER_ASK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$*" >"$MODEL_PROVIDER_ASK_ARGS_LOG"
  fi
  printf '%s\n' "$MODEL_PROVIDER_ASK_RESPONSE"
  ;;
*)
  exit 1
  ;;
esac
EOF
  chmod +x "$stub_path"
}

create_jq_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/python3
import json
import re
import sys

args = sys.argv[1:]

if not args:
    sys.exit(1)

data = json.load(sys.stdin)

if args[0] == '-e' and len(args) >= 2 and args[1] == '.commits | type == "array"':
    sys.exit(0 if isinstance(data.get('commits'), list) else 1)

if args[0] == '-r' and len(args) >= 2:
    expr = args[1]

    if expr == '.commits | length':
        print(len(data.get('commits', [])))
        sys.exit(0)

    match = re.fullmatch(r'\.commits\[(\d+)\]\.type // empty', expr)
    if match:
        index = int(match.group(1))
        print(data.get('commits', [])[index].get('type', ''))
        sys.exit(0)

    match = re.fullmatch(r'\.commits\[(\d+)\]\.message // empty', expr)
    if match:
        index = int(match.group(1))
        print(data.get('commits', [])[index].get('message', ''))
        sys.exit(0)

    match = re.fullmatch(r'\.commits\[(\d+)\]\.files\[\]\??', expr)
    if match:
        index = int(match.group(1))
        for item in data.get('commits', [])[index].get('files', []):
            print(item)
        sys.exit(0)

sys.exit(1)
EOF
  chmod +x "$stub_path"
}

create_pre_commit_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

attempt=1
if [ -n "${PRE_COMMIT_ATTEMPTS_FILE:-}" ]; then
  if [ -f "$PRE_COMMIT_ATTEMPTS_FILE" ]; then
    attempt=$(( $(<"$PRE_COMMIT_ATTEMPTS_FILE") + 1 ))
  fi
  printf '%s\n' "$attempt" >"$PRE_COMMIT_ATTEMPTS_FILE"
fi

if [ -n "${PRE_COMMIT_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$PRE_COMMIT_LOG"
fi

if [ -n "${PRE_COMMIT_FAIL_FIRST:-}" ] && [ "$attempt" -le "$PRE_COMMIT_FAIL_FIRST" ]; then
  exit 1
fi
EOF
  chmod +x "$stub_path"
}

install_pre_commit_hook() {
  local repo="$1"

  mkdir -p "$repo/.git/hooks"
  cat >"$repo/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec pre-commit hook-impl --hook-type pre-commit --hook-dir "$HERE" -- "$@"
EOF
  chmod +x "$repo/.git/hooks/pre-commit"
}

install_index_sensitive_pre_commit_hook() {
  local repo="$1"

  mkdir -p "$repo/.git/hooks"
  cat >"$repo/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

staged_script=$(git show :script.bash 2>/dev/null || true)
case "$staged_script" in
*BROKEN_FOR_SHELLCHECK*)
  echo 'Shellcheck Bash Linter' >&2
  exit 1
  ;;
esac
EOF
  chmod +x "$repo/.git/hooks/pre-commit"
}

run_configure_with_stub() {
  local stub_path="$1"
  local input_file

  input_file="$TMP_HOME/configure-input.txt"
  printf '1\n1\n' >"$input_file"
  MODEL_PROVIDER_BIN="$stub_path" "$TOOL" configure <"$input_file"
}

write_git_commit_config() {
  local profile="$1"
  local model="$2"
  local file

  mkdir -p "$GIT_COMMIT_CONFIG_DIR"
  file="$(git_commit_config_file)"
  printf '[model]\n\tprofile = %s\n\tname = %s\n' "$profile" "$model" >"$file"
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

@test "help and configure command" {
  local stub_path output

  stub_path="$TMP_HOME/model-provider-stub"
  create_model_provider_stub "$stub_path"

  output=$(MODEL_PROVIDER_BIN="$stub_path" "$TOOL" --help)
  assert_contains "$output" 'Usage: git-commit [command]' 'help should describe usage'
  assert_contains "$output" 'configure  Select the model profile and model to use' 'help should list configure'
  assert_contains "$output" '--apply' 'help should list apply mode'
  assert_contains "$output" '--pre-commit-retries <n>' 'help should list pre-commit retry option'

  printf '2\n2\n' | MODEL_PROVIDER_BIN="$stub_path" "$TOOL" configure >/dev/null 2>&1
  assert_file_exists "$(git_commit_config_file)" 'configure should create a config file'
  assert_config_value model.profile 'beta-profile' 'configure should save the selected profile'
  assert_config_value model.name 'beta-model-2' 'configure should save the selected model'
}

@test "warns when configuration is missing" {
  local stub_path repo output

  stub_path="$TMP_HOME/model-provider-stub"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf '%s\n' 'change' >>"$repo/README.md"

  if output=$(cd "$repo" && MODEL_PROVIDER_BIN="$stub_path" "$TOOL" 2>&1); then
    fail 'git-commit should fail when configuration is missing'
  fi

  assert_contains "$output" 'Warning: git-commit is not configured. Run git-commit configure.' 'git-commit should warn when configuration is missing'
}

@test "fails when pre-staged changes are kept" {
  local stub_path repo output

  stub_path="$TMP_HOME/model-provider-stub"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && printf 'n\n' | MODEL_PROVIDER_BIN="$stub_path" "$TOOL" 2>&1); then
    fail 'git-commit should fail when staged changes already exist'
  fi

  assert_contains "$output" 'Staged changes detected. Unstage them with git restore --staged :/? [y/N]:' 'git-commit should prompt before unstaging changes'
  assert_contains "$output" 'Error: git-commit requires no pre-staged changes. Unstage them first.' 'git-commit should explain why pre-staged changes are rejected'
}

@test "can unstage pre-staged changes and continue" {
  local stub_path jq_stub repo output staged_after head_subject

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && printf 'y\n' |
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROVIDER_BIN="$stub_path" \
      MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
      "$TOOL" 2>&1)

  assert_contains "$output" 'git add -A :/' 'git-commit should print a repo-root add command after unstaging staged changes'
  assert_contains "$output" 'git commit -m "feat(11222): update readme"' 'git-commit should print the proposed commit command after unstaging staged changes'
  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_eq "$staged_after" '' 'git-commit should leave no staged changes after unstaging them for preview'
  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'chore(init): initial commit' 'git-commit should not create a commit during preview'
}

@test "creates a single conventional commit from one plan item" {
  local stub_path jq_stub repo ask_log output head_subject staged_after

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-provider-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222_2
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROVIDER_BIN="$stub_path" \
      MODEL_PROVIDER_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should create a single commit successfully ($output)"
  fi

  assert_contains "$output" 'git add -A :/' 'git-commit should print a repo-root add command for a single planned commit'
  assert_contains "$output" 'git commit -m "feat(11222): add repository notes"' 'git-commit should print a conventional commit command with derived scope'
  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'chore(init): initial commit' 'git-commit should not create the commit automatically'
  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_eq "$staged_after" '' 'git-commit should not stage files automatically in preview mode'
  assert_contains "$(<"$ask_log")" 'ask alpha-profile --model alpha-model' 'git-commit should call model-provider ask with configured profile and model'
}

@test "creates multiple commits from grouped file plan" {
  local stub_path jq_stub repo output head_subject staged_after

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b fix/445566_2
  mkdir -p "$repo/src" "$repo/tests"
  printf 'code change\n' >"$repo/src/app.txt"
  printf 'test change\n' >"$repo/tests/app.txt"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROVIDER_BIN="$stub_path" \
      MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"fix","message":"update application logic","files":["src/app.txt"]},{"type":"test","message":"add coverage for application logic","files":["tests/app.txt"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should create grouped commits successfully ($output)"
  fi

  assert_contains "$output" 'Commit 1:' 'git-commit should print a header for the first grouped commit'
  assert_contains "$output" 'git add -- :/src/app.txt' 'git-commit should print a repo-root grouped add command for the first commit'
  assert_contains "$output" 'git commit -m "fix(445566): update application logic"' 'git-commit should print the first grouped commit command'
  assert_contains "$output" 'Commit 2:' 'git-commit should print a header for the second grouped commit'
  assert_contains "$output" 'git add -- :/tests/app.txt' 'git-commit should print a repo-root grouped add command for the second commit'
  assert_contains "$output" 'git commit -m "test(445566): add coverage for application logic"' 'git-commit should print the second grouped commit command'
  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'chore(init): initial commit' 'git-commit should not create grouped commits automatically'
  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_eq "$staged_after" '' 'git-commit should not stage grouped files automatically in preview mode'
}

@test "omits scope when branch name has no slash" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b dv
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"chore","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" 2>&1)

  assert_contains "$output" 'git commit -m "chore: update readme"' 'git-commit should omit scope when branch name has no slash'
}

@test "uses explicit --scope override instead of branch-derived scope" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --scope override 2>&1)

  assert_contains "$output" 'git commit -m "feat(override): update readme"' 'git-commit should use the explicit scope override'
}

@test "uses explicit --scope=value override instead of branch-derived scope" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --scope=override 2>&1)

  assert_contains "$output" 'git commit -m "feat(override): update readme"' 'git-commit should accept --scope=value'
}

@test "omits scope when --no-scope is provided" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --no-scope 2>&1)

  assert_contains "$output" 'git commit -m "feat: update readme"' 'git-commit should omit scope when --no-scope is provided'
}

@test "runs pre-commit on changed files when hook exists" {
  local stub_path jq_stub pre_commit_stub repo output pre_commit_log

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  pre_commit_stub="$TMP_HOME/pre-commit"
  pre_commit_log="$TMP_HOME/pre-commit.log"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_pre_commit_stub "$pre_commit_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  install_pre_commit_hook "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    PRE_COMMIT_LOG="$pre_commit_log" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}]}' \
    "$TOOL" 2>&1)

  assert_contains "$output" 'git commit -m "feat(11222): add repository notes"' 'git-commit should continue after successful pre-commit checks'
  assert_contains "$(<"$pre_commit_log")" 'hook-impl --hook-type pre-commit' 'git-commit should execute the installed pre-commit hook'
}

@test "retries pre-commit up to two more times after failures" {
  local stub_path jq_stub pre_commit_stub repo output pre_commit_log pre_commit_attempts

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  pre_commit_stub="$TMP_HOME/pre-commit"
  pre_commit_log="$TMP_HOME/pre-commit.log"
  pre_commit_attempts="$TMP_HOME/pre-commit.attempts"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_pre_commit_stub "$pre_commit_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  install_pre_commit_hook "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    PRE_COMMIT_LOG="$pre_commit_log" \
    PRE_COMMIT_ATTEMPTS_FILE="$pre_commit_attempts" \
    PRE_COMMIT_FAIL_FIRST=2 \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" 2>&1)

  assert_contains "$output" 'git commit -m "feat(11222): update readme"' 'git-commit should continue after pre-commit succeeds on a retry'
  assert_eq "$(<"$pre_commit_attempts")" '3' 'git-commit should retry pre-commit up to three total attempts'
  assert_contains "$(<"$pre_commit_log")" 'hook-impl --hook-type pre-commit' 'git-commit should retry the installed pre-commit hook'
}

@test "respects --pre-commit-retries override" {
  local stub_path jq_stub pre_commit_stub repo output pre_commit_attempts

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  pre_commit_stub="$TMP_HOME/pre-commit"
  pre_commit_attempts="$TMP_HOME/pre-commit.attempts"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_pre_commit_stub "$pre_commit_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  install_pre_commit_hook "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    PRE_COMMIT_ATTEMPTS_FILE="$pre_commit_attempts" \
    PRE_COMMIT_FAIL_FIRST=2 \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --pre-commit-retries 1 2>&1); then
    fail 'git-commit should fail after the configured pre-commit retry limit is reached'
  fi

  assert_contains "$output" 'Error: pre-commit checks failed after 2 attempts' 'git-commit should report the configured total attempts'
  assert_eq "$(<"$pre_commit_attempts")" '2' 'git-commit should stop after the configured retry limit'
}

@test "fails early when the installed pre-commit hook rejects the staged snapshot" {
  local stub_path jq_stub pre_commit_stub repo output

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  pre_commit_stub="$TMP_HOME/pre-commit"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_pre_commit_stub "$pre_commit_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  install_index_sensitive_pre_commit_hook "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf '%s\n' '#!/usr/bin/env bash' 'BROKEN_FOR_SHELLCHECK' >"$repo/script.bash"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add script","files":["script.bash"]}]}' \
    "$TOOL" 2>&1); then
    fail 'git-commit should fail when the installed pre-commit hook rejects the staged snapshot'
  fi

  assert_contains "$output" 'Shellcheck Bash Linter' 'git-commit should surface the installed hook failure'
}

@test "applies a single planned commit with --apply" {
  local stub_path jq_stub repo output head_subject status_after

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat(11222): add repository notes' 'git-commit should create the planned commit in apply mode'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after apply mode'
  assert_contains "$output" 'feat(11222): add repository notes' 'git-commit should show the created commit title in apply mode'
}

@test "applies grouped commits with --apply" {
  local stub_path jq_stub repo output head_subject previous_subject status_after

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b fix/445566_2
  mkdir -p "$repo/src" "$repo/tests"
  printf 'code change\n' >"$repo/src/app.txt"
  printf 'test change\n' >"$repo/tests/app.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"fix","message":"update application logic","files":["src/app.txt"]},{"type":"test","message":"add coverage for application logic","files":["tests/app.txt"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  previous_subject=$(git -C "$repo" log -2 --pretty=%s | sed -n '2p')
  assert_eq "$head_subject" 'test(445566): add coverage for application logic' 'git-commit should create the last grouped commit in apply mode'
  assert_eq "$previous_subject" 'fix(445566): update application logic' 'git-commit should create grouped commits in order'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after grouped apply mode'
  assert_contains "$output" 'fix(445566): update application logic' 'git-commit should show the first created grouped commit'
  assert_contains "$output" 'test(445566): add coverage for application logic' 'git-commit should show the second created grouped commit'
}

@test "applies grouped commits when the model returns a unique basename for a new file" {
  local stub_path jq_stub repo output head_subject previous_subject status_after

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  mkdir -p "$repo/tools/bin"
  printf 'updated\n' >>"$repo/README.md"
  printf '%s\n' '#!/usr/bin/env bash' 'echo tool' >"$repo/tools/bin/asdf-upgrade"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"docs","message":"update readme","files":["README.md"]},{"type":"feat","message":"add asdf upgrade tool","files":["asdf-upgrade"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  previous_subject=$(git -C "$repo" log -2 --pretty=%s | sed -n '2p')
  assert_eq "$head_subject" 'feat(11222): add asdf upgrade tool' 'git-commit should resolve the new file basename to its changed path'
  assert_eq "$previous_subject" 'docs(11222): update readme' 'git-commit should preserve earlier grouped commits'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after applying basename-resolved commits'
  assert_contains "$output" 'feat(11222): add asdf upgrade tool' 'git-commit should show the basename-resolved commit title'
}

@test "applies grouped commits from a subdirectory using repo-root paths" {
  local stub_path jq_stub repo output head_subject previous_subject status_after

  stub_path="$TMP_HOME/model-provider-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  mkdir -p "$repo/tools/bin"
  printf 'updated\n' >>"$repo/README.md"
  printf '%s\n' '#!/usr/bin/env bash' 'echo tool' >"$repo/tools/bin/asdf-upgrade"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo/tools/bin" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROVIDER_BIN="$stub_path" \
    MODEL_PROVIDER_ASK_RESPONSE='{"commits":[{"type":"docs","message":"update readme","files":["README.md"]},{"type":"feat","message":"add asdf upgrade tool","files":["asdf-upgrade"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  previous_subject=$(git -C "$repo" log -2 --pretty=%s | sed -n '2p')
  assert_eq "$head_subject" 'feat(11222): add asdf upgrade tool' 'git-commit should stage basename-resolved files correctly from a subdirectory'
  assert_eq "$previous_subject" 'docs(11222): update readme' 'git-commit should keep grouped commit order from a subdirectory'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after subdirectory apply mode'
  assert_contains "$output" 'feat(11222): add asdf upgrade tool' 'git-commit should show the basename-resolved commit title from a subdirectory'
}
