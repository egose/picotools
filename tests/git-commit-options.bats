#!/usr/bin/env bats

load 'helpers/git-commit'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-commit"

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

assert_file_missing_or_empty() {
  local path="$1"
  local message="$2"

  if [ -s "$path" ]; then
    fail "$message ($(sed ':a;N;$!ba;s/\n/; /g' "$path"))"
  fi
}

write_git_commit_config() {
  mkdir -p "$GIT_COMMIT_CONFIG_DIR"
  cat >"$GIT_COMMIT_CONFIG_DIR/config" <<'EOF'
[model]
	profile = alpha-profile
	name = alpha-model
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

create_model_provider_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${MODEL_PROFILE_LOG:-}" ]; then
  printf '%s\n' 'ARGV_BEGIN' >>"$MODEL_PROFILE_LOG"
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$MODEL_PROFILE_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$MODEL_PROFILE_LOG"
fi

case "${1:-}" in
ask)
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = '--message-file' ] || [ "${!i}" = '--user-message-file' ]; then
      next_index=$((i + 1))
      if [ -n "${MODEL_PROFILE_MESSAGE_LOG:-}" ]; then
        cat "${!next_index}" >>"$MODEL_PROFILE_MESSAGE_LOG"
      fi
    fi
  done
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

if [ -n "${GIT_API_LOG:-}" ]; then
  printf '%s\n' 'ARGV_BEGIN' >>"$GIT_API_LOG"
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$GIT_API_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$GIT_API_LOG"
fi
printf '%s\n' '[]'
EOF
  chmod +x "$stub_path"
}

create_jq_stub() {
  local stub_path="$1"

  create_jq_stub_from_real_jq "$stub_path"
  return 0

  # shellcheck disable=SC2317
  cat >"$stub_path" <<'EOF'
#!/usr/bin/python3
import json
import re
import sys

args = sys.argv[1:]
data = json.load(sys.stdin)

def commit_value(index, key):
    commits = data.get('commits') if isinstance(data, dict) else None
    if not isinstance(commits, list) or index >= len(commits):
        return None
    commit = commits[index]
    if isinstance(commit, dict):
        return commit.get(key)
    return None

if len(args) >= 2 and args[0] == '-e':
    expr = args[1]
    if expr == 'type == "object" and (.commits | type == "array")':
        sys.exit(0 if isinstance(data, dict) and isinstance(data.get('commits'), list) else 1)
    if expr == 'type == "object"':
        sys.exit(0 if isinstance(data, dict) else 1)
    if expr == 'has("commits") and (.commits | type == "array")':
        sys.exit(0 if isinstance(data, dict) and 'commits' in data and isinstance(data.get('commits'), list) else 1)
    if expr == 'has("pull_request") | not':
        sys.exit(0 if isinstance(data, dict) and 'pull_request' not in data else 1)
    if expr == '.pull_request == null':
        sys.exit(0 if isinstance(data, dict) and data.get('pull_request') is None else 1)
    if expr == '.pull_request | type == "object"':
        sys.exit(0 if isinstance(data, dict) and isinstance(data.get('pull_request'), dict) else 1)
    if expr == '.pull_request | has("title")':
        pull_request = data.get('pull_request') if isinstance(data, dict) else None
        sys.exit(0 if isinstance(pull_request, dict) and 'title' in pull_request else 1)
    if expr == '.pull_request | has("body")':
        pull_request = data.get('pull_request') if isinstance(data, dict) else None
        sys.exit(0 if isinstance(pull_request, dict) and 'body' in pull_request else 1)
    match = re.fullmatch(r'\.commits\[(\d+)\] \| type == "object"', expr)
    if match:
        commits = data.get('commits') if isinstance(data, dict) else None
        value = commits[int(match.group(1))] if isinstance(commits, list) and int(match.group(1)) < len(commits) else None
        sys.exit(0 if isinstance(value, dict) else 1)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.(type|message) \| type == "string" and length > 0', expr)
    if match:
        value = commit_value(int(match.group(1)), match.group(2))
        sys.exit(0 if isinstance(value, str) and len(value) > 0 else 1)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.files \| type == "array" and length > 0', expr)
    if match:
        value = commit_value(int(match.group(1)), 'files')
        sys.exit(0 if isinstance(value, list) and len(value) > 0 else 1)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.files\[(\d+)\] \| type == "string" and length > 0', expr)
    if match:
        files = commit_value(int(match.group(1)), 'files')
        value = files[int(match.group(2))] if isinstance(files, list) and int(match.group(2)) < len(files) else None
        sys.exit(0 if isinstance(value, str) and len(value) > 0 else 1)

if args[:2] == ['-e', '.commits | type == "array"']:
    sys.exit(0 if isinstance(data.get('commits'), list) else 1)

if len(args) >= 2 and args[0] == '-r':
    expr = args[1]
    if expr == '.commits | length':
        print(len(data.get('commits', [])))
        sys.exit(0)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.files \| length', expr)
    if match:
        files = commit_value(int(match.group(1)), 'files')
        print(len(files) if isinstance(files, list) else 0)
        sys.exit(0)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.type', expr)
    if match:
        value = commit_value(int(match.group(1)), 'type')
        print(value if isinstance(value, str) else '')
        sys.exit(0)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.message', expr)
    if match:
        value = commit_value(int(match.group(1)), 'message')
        print(value if isinstance(value, str) else '')
        sys.exit(0)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.type // empty', expr)
    if match:
        print(data.get('commits', [])[int(match.group(1))].get('type', ''))
        sys.exit(0)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.message // empty', expr)
    if match:
        print(data.get('commits', [])[int(match.group(1))].get('message', ''))
        sys.exit(0)
    match = re.fullmatch(r'\.commits\[(\d+)\]\.files\[\]\?', expr)
    if match:
        for item in data.get('commits', [])[int(match.group(1))].get('files', []):
            print(item)
        sys.exit(0)

if len(args) >= 2 and args[0] == '-rj':
    expr = args[1]
    match = re.fullmatch(r'\.commits\[(\d+)\]\.files\[\]\? \| \. \+ "\\u0000"', expr)
    if match:
        for item in data.get('commits', [])[int(match.group(1))].get('files', []):
            sys.stdout.write(item + '\0')
        sys.exit(0)

sys.exit(1)
EOF
  # shellcheck disable=SC2317
  chmod +x "$stub_path"
}

create_git_profile_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${GIT_PROFILE_LOG:-}" ]; then
  printf '%s\n' 'ARGV_BEGIN' >>"$GIT_PROFILE_LOG"
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$GIT_PROFILE_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$GIT_PROFILE_LOG"
fi
printf '%s\n' 'Error: no git profile is recorded in this repository' >&2
exit 1
EOF
  chmod +x "$stub_path"
}

create_git_command_wrapper() {
  local wrapper_path="$1"

  cat >"$wrapper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = 'add' ] || [ "${1:-}" = 'commit' ]; then
  if [ -n "${GIT_MUTATION_LOG:-}" ]; then
    printf '%s\n' 'ARGV_BEGIN' >>"$GIT_MUTATION_LOG"
    rendered=''
    for arg in "$@"; do
      printf '%q\n' "$arg" >>"$GIT_MUTATION_LOG"
      printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
    done
    printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$GIT_MUTATION_LOG"
  fi
fi

exec "$REAL_GIT" "$@"
EOF
  chmod +x "$wrapper_path"
}

install_pre_commit_hook() {
  local repo="$1"

  mkdir -p "$repo/.git/hooks"
  cat >"$repo/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${PRE_COMMIT_LOG:-}" ]; then
  printf 'pre-commit invoked\n' >>"$PRE_COMMIT_LOG"
fi
EOF
  chmod +x "$repo/.git/hooks/pre-commit"
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
    MODEL_PROFILE_LOG="$MODEL_PROFILE_LOG" \
    MODEL_PROFILE_MESSAGE_LOG="$MODEL_PROFILE_MESSAGE_LOG" \
    GIT_API_LOG="$GIT_API_LOG" \
    GIT_PROFILE_LOG="$GIT_PROFILE_LOG" \
    GIT_MUTATION_LOG="$GIT_MUTATION_LOG" \
    PRE_COMMIT_LOG="$PRE_COMMIT_LOG" \
    "$TOOL" "$@"
}

setup_option_repo() {
  local repo="$1"

  mkdir -p "$TMP_HOME/bin"
  REAL_GIT="$(command -v git)"
  MODEL_PROFILE_STUB="$TMP_HOME/model-profile"
  GIT_API_STUB="$TMP_HOME/git-api"
  GIT_PROFILE_STUB="$TMP_HOME/git-profile"
  MODEL_PROFILE_LOG="$TMP_HOME/model-profile.log"
  MODEL_PROFILE_MESSAGE_LOG="$TMP_HOME/model-message.log"
  GIT_API_LOG="$TMP_HOME/git-api.log"
  GIT_PROFILE_LOG="$TMP_HOME/git-profile.log"
  GIT_MUTATION_LOG="$TMP_HOME/git-mutation.log"
  PRE_COMMIT_LOG="$TMP_HOME/pre-commit.log"
  export REAL_GIT MODEL_PROFILE_STUB GIT_API_STUB GIT_PROFILE_STUB
  export MODEL_PROFILE_LOG MODEL_PROFILE_MESSAGE_LOG GIT_API_LOG GIT_PROFILE_LOG GIT_MUTATION_LOG PRE_COMMIT_LOG

  create_model_provider_stub "$MODEL_PROFILE_STUB"
  create_git_api_stub "$GIT_API_STUB"
  create_git_profile_stub "$GIT_PROFILE_STUB"
  create_git_command_wrapper "$TMP_HOME/bin/git"
  create_jq_stub "$TMP_HOME/bin/jq"
  init_repo "$repo"
  install_pre_commit_hook "$repo"
  write_git_commit_config
}

@test "missing --path-file forms fail before workspace and model work" {
  local repo output

  repo="$TMP_HOME/repo"
  setup_option_repo "$repo"
  printf '%s\n' 'changed' >>"$repo/README.md"

  if output=$(run_tool_in_repo "$repo" --path-file missing 2>&1); then
    fail 'git-commit should fail for --path-file missing'
  fi
  assert_contains "$output" 'Error: --path-file not found: missing' 'missing --path-file should report the missing file'

  if output=$(run_tool_in_repo "$repo" --path-file=missing 2>&1); then
    fail 'git-commit should fail for --path-file=missing'
  fi
  assert_contains "$output" 'Error: --path-file not found: missing' 'missing --path-file= should report the missing file'
  assert_file_missing_or_empty "$MODEL_PROFILE_LOG" 'model provider must not run after missing path-file parser failure'
  assert_file_missing_or_empty "$PRE_COMMIT_LOG" 'pre-commit hook must not run after missing path-file parser failure'
}

@test "apply with a missing path file creates no commit and does not stage unscoped changes" {
  local repo output before_count after_count staged_after

  repo="$TMP_HOME/repo"
  setup_option_repo "$repo"
  printf '%s\n' 'changed' >>"$repo/README.md"
  printf '%s\n' 'secret' >"$repo/secret.txt"
  before_count=$(git -C "$repo" rev-list --count HEAD)

  if output=$(run_tool_in_repo "$repo" --apply --path-file missing 2>&1); then
    fail 'git-commit should fail for --apply --path-file missing'
  fi

  after_count=$(git -C "$repo" rev-list --count HEAD)
  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_contains "$output" 'Error: --path-file not found: missing' 'apply mode should report the missing path file'
  [ "$after_count" = "$before_count" ] || fail 'missing path-file apply must not create a commit'
  [ -z "$staged_after" ] || fail "missing path-file apply must not stage files ($staged_after)"
  assert_file_missing_or_empty "$GIT_MUTATION_LOG" 'git add and git commit must not run after missing path-file parser failure'
}

@test "parser failures after valid options stop before hooks model API and git mutations" {
  local repo output

  repo="$TMP_HOME/repo"
  setup_option_repo "$repo"
  printf '%s\n' 'changed' >>"$repo/README.md"

  if output=$(run_tool_in_repo "$repo" --pr main --apply --path README.md --unknown 2>&1); then
    fail 'git-commit should fail for an unknown option after valid options'
  fi

  assert_contains "$output" "Error: unknown option '--unknown'" 'unknown trailing option should be rejected'
  assert_file_missing_or_empty "$PRE_COMMIT_LOG" 'pre-commit hook must not run after parser failure'
  assert_file_missing_or_empty "$MODEL_PROFILE_LOG" 'model provider must not run after parser failure'
  assert_file_missing_or_empty "$GIT_API_LOG" 'git-api must not run after parser failure'
  assert_file_missing_or_empty "$GIT_MUTATION_LOG" 'git add and git commit must not run after parser failure'
}

@test "required option values return nonzero" {
  local repo output

  repo="$TMP_HOME/repo"
  setup_option_repo "$repo"
  printf '%s\n' 'changed' >>"$repo/README.md"

  if output=$(run_tool_in_repo "$repo" --scope 2>&1); then
    fail 'git-commit should fail when --scope has no value'
  fi
  assert_contains "$output" 'Error: --scope requires a value' 'missing --scope value should be rejected'

  if output=$(run_tool_in_repo "$repo" --path 2>&1); then
    fail 'git-commit should fail when --path has no value'
  fi
  assert_contains "$output" 'Error: --path requires a value' 'missing --path value should be rejected'

  if output=$(run_tool_in_repo "$repo" --pre-commit-retries 2>&1); then
    fail 'git-commit should fail when --pre-commit-retries has no value'
  fi
  assert_contains "$output" 'Error: --pre-commit-retries requires a value' 'missing --pre-commit-retries value should be rejected'
}

@test "parse_run_options preserves mixed repeated path order exactly" {
  local path_file_one path_file_two
  local -a selected_paths=()
  local -A run_options=()

  path_file_one="$TMP_HOME/paths-one.txt"
  path_file_two="$TMP_HOME/paths-two.txt"
  printf '%s\n' 'from-file-one' 'from-file-two' >"$path_file_one"
  printf '%s\n' 'from-file-three' >"$path_file_two"

  # shellcheck source=../tools/bin/git-commit disable=SC1091
  . "$TOOL"
  parse_run_options run_options selected_paths \
    --path first \
    --path-file "$path_file_one" \
    --path first \
    --path-file="$path_file_two" \
    --path 'last path'

  [ "${#selected_paths[@]}" -eq 6 ] || fail "parser should preserve six selected entries (${#selected_paths[@]})"
  [ "${selected_paths[0]}" = 'first' ] || fail 'parser should preserve first --path entry'
  [ "${selected_paths[1]}" = 'from-file-one' ] || fail 'parser should insert first path-file entry at its option position'
  [ "${selected_paths[2]}" = 'from-file-two' ] || fail 'parser should preserve all entries from a path file'
  [ "${selected_paths[3]}" = 'first' ] || fail 'parser should preserve repeated --path entries'
  [ "${selected_paths[4]}" = 'from-file-three' ] || fail 'parser should insert --path-file= entries at their option position'
  [ "${selected_paths[5]}" = 'last path' ] || fail 'parser should preserve paths containing spaces exactly'
  [ "${run_options[apply_commits]}" = 'false' ] || fail 'parser should keep default apply state for path-only options'
}

@test "mixed repeated path and path-file options preserve exact selected entries" {
  local repo path_file_one path_file_two output ask_payload

  repo="$TMP_HOME/repo"
  path_file_one="$TMP_HOME/paths-one.txt"
  path_file_two="$TMP_HOME/paths-two.txt"
  setup_option_repo "$repo"
  mkdir -p "$repo/dir one"
  printf '%s\n' 'alpha' >"$repo/alpha.txt"
  printf '%s\n' 'nested' >"$repo/dir one/file.txt"
  printf '%s\n' 'beta' >"$repo/beta.txt"
  printf '%s\n' 'zeta' >"$repo/zeta.txt"
  printf '%s\n' 'unscoped' >"$repo/unscoped.txt"
  printf '%s\n' 'dir one' >"$path_file_one"
  printf '%s\n' 'beta.txt' >"$path_file_two"

  if ! output=$(MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add selected files","files":["alpha.txt","beta.txt","dir one/file.txt","zeta.txt"]}]}' \
    run_tool_in_repo "$repo" --path alpha.txt --path-file "$path_file_one" --path zeta.txt --path-file="$path_file_two" 2>&1); then
    fail "git-commit should accept mixed repeated --path and --path-file options ($output)"
  fi

  ask_payload=$(<"$MODEL_PROFILE_MESSAGE_LOG")
  assert_contains "$ask_payload" 'alpha.txt' 'direct --path entry should be preserved in planning input'
  assert_contains "$ask_payload" 'dir one/file.txt' 'path-file entry with spaces should be preserved exactly in planning input'
  assert_contains "$ask_payload" 'beta.txt' 'second path-file entry should be preserved in planning input'
  assert_contains "$ask_payload" 'zeta.txt' 'repeated --path entry should be preserved in planning input'
  assert_contains "$output" 'git add -A --' 'preview should contain a git add command'
  assert_contains "$output" ':\(top\,literal\)alpha.txt' 'preview should contain the alpha literal pathspec'
  assert_contains "$output" ':\(top\,literal\)beta.txt' 'preview should contain the beta literal pathspec'
  assert_contains "$output" ':\(top\,literal\)dir\ one/file.txt' 'preview should contain the spaced literal pathspec'
  assert_contains "$output" 'zeta.txt' 'preview should contain the zeta selected file'
}
