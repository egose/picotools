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
