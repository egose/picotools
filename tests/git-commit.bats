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

strip_ansi() {
  printf '%s' "$1" | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g'
}

strip_box_borders() {
  perl -C -pe 's/^[\x{2500}-\x{257F}\x{2550}-\x{256C}]+[ \t]*//; s/[ \t]*[\x{2500}-\x{257F}\x{2550}-\x{256C}]+$//'
}

preview_git_add_command() {
  (
    # shellcheck source=../tools/bin/git-commit disable=SC1091
    . "$TOOL"
    print_git_add_command "$@"
  )
}

preview_git_commit_command() {
  local title="$1"

  (
    # shellcheck source=../tools/bin/git-commit disable=SC1091
    . "$TOOL"
    print_git_commit_command "$title"
  )
}

decode_bash_word() {
  local encoded="$1"

  bash -lc "printf '%s' $encoded"
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

assert_config_missing() {
  local key="$1"
  local message="$2"

  if git config -f "$(git_commit_config_file)" --get "$key" >/dev/null 2>&1; then
    fail "$message ($key)"
  fi
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

message_file=''
system_message_file=''
selected_profile=''
selected_model=''

for ((i = 1; i <= $#; i++)); do
  if [ "$i" -eq 2 ] && [ "${1:-}" = 'ask' ]; then
    selected_profile="${!i}"
  fi
  if [ "${!i}" = '--message-file' ] || [ "${!i}" = '--user-message-file' ]; then
    next_index=$((i + 1))
    message_file="${!next_index}"
  fi
  if [ "${!i}" = '--system-message-file' ]; then
    next_index=$((i + 1))
    system_message_file="${!next_index}"
  fi
  if [ "${!i}" = '--model' ]; then
    next_index=$((i + 1))
    selected_model="${!next_index}"
  fi
done

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
  if [ "$debug_requested" = 'true' ] || [ "${MODEL_PROFILE_DEBUG:-false}" = 'true' ]; then
    printf '%s\n' '[model-profile] Stub debug enabled' >&2
  fi
if [ -n "${MODEL_PROFILE_ASK_ARGS_LOG:-}" ]; then
  printf '%s\n' 'ARGV_BEGIN' >>"$MODEL_PROFILE_ASK_ARGS_LOG"
  human_prefix=''
  if [ "$debug_requested" = 'true' ]; then
    printf '%q\n' --debug >>"$MODEL_PROFILE_ASK_ARGS_LOG"
    human_prefix='--debug '
  fi
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$MODEL_PROFILE_ASK_ARGS_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n' 'ARGV_END' >>"$MODEL_PROFILE_ASK_ARGS_LOG"
  printf '%s%s\n' "$human_prefix" "$rendered" >>"$MODEL_PROFILE_ASK_ARGS_LOG"
  if [ -n "$system_message_file" ]; then
    printf 'SYSTEM_MESSAGE_FILE_CONTENT=%s\n' "$(<"$system_message_file")" >>"$MODEL_PROFILE_ASK_ARGS_LOG"
  fi
    if [ -n "$message_file" ]; then
      printf 'MESSAGE_FILE_CONTENT=%s\n' "$(<"$message_file")" >>"$MODEL_PROFILE_ASK_ARGS_LOG"
    fi
  fi
  if [ -n "${MODEL_PROFILE_ASK_FAIL_PROFILE:-}" ] && [ "$selected_profile" = "$MODEL_PROFILE_ASK_FAIL_PROFILE" ] &&
    [ -n "${MODEL_PROFILE_ASK_FAIL_MODEL:-}" ] && [ "$selected_model" = "$MODEL_PROFILE_ASK_FAIL_MODEL" ]; then
    printf '%s\n' "${MODEL_PROFILE_ASK_FAIL_MESSAGE:-Error: request failed}" >&2
    exit 1
  fi
  if [ -n "${MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE:-}" ] && [ -f "${MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE:-}" ]; then
    index=1
    if [ -n "${MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE:-}" ] && [ -f "${MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE:-}" ]; then
      index=$(( $(cat "${MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE}") + 1 ))
    fi
    if [ -n "${MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE:-}" ]; then
      printf '%s\n' "$index" >"${MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE:-}"
    fi
    mapfile -t sequence_lines < "${MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE}"
    response_index=$index
    if [ "$response_index" -gt "${#sequence_lines[@]}" ]; then
      response_index=${#sequence_lines[@]}
    fi
    printf '%s\n' "${sequence_lines[$((response_index - 1))]}"
    exit 0
  fi
  printf '%s\n' "$MODEL_PROFILE_ASK_RESPONSE"
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

  create_jq_stub_from_real_jq "$stub_path"
  return 0

  # shellcheck disable=SC2317
  cat >"$stub_path" <<'EOF'
#!/usr/bin/python3
import json
import re
import sys

args = sys.argv[1:]

if not args:
    sys.exit(1)

data = json.load(sys.stdin)

def jq_type(value):
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return 'boolean'
    if isinstance(value, (int, float)):
        return 'number'
    if isinstance(value, str):
        return 'string'
    if isinstance(value, list):
        return 'array'
    if isinstance(value, dict):
        return 'object'
    return 'unknown'

def commit_at(index):
    commits = data.get('commits') if isinstance(data, dict) else None
    if not isinstance(commits, list) or index >= len(commits):
        return None
    return commits[index]

def commit_value(index, key):
    commit = commit_at(index)
    if isinstance(commit, dict):
        return commit.get(key)
    return None

def file_value(commit_index, file_index):
    files = commit_value(commit_index, 'files')
    if isinstance(files, list) and file_index < len(files):
        return files[file_index]
    return None

if args[0] == '-e' and len(args) >= 2:
    expr = args[1]

    if expr == 'type == "object" and (.commits | type == "array")':
        sys.exit(0 if isinstance(data, dict) and isinstance(data.get('commits'), list) else 1)

    if expr == 'type == "object"':
        sys.exit(0 if isinstance(data, dict) else 1)

    if expr == 'type == "array"':
        sys.exit(0 if isinstance(data, list) else 1)

    if expr == 'length == 0':
        sys.exit(0 if isinstance(data, list) and len(data) == 0 else 1)

    if expr == '.[0] | type == "object"':
        sys.exit(0 if isinstance(data, list) and data and isinstance(data[0], dict) else 1)

    if expr == '.[0].html_url | type == "string" and length > 0':
        value = data[0].get('html_url') if isinstance(data, list) and data and isinstance(data[0], dict) else None
        sys.exit(0 if isinstance(value, str) and len(value) > 0 else 1)

    if expr == '.[0].number | ((type == "number") or (type == "string" and length > 0))':
        value = data[0].get('number') if isinstance(data, list) and data and isinstance(data[0], dict) else None
        sys.exit(0 if isinstance(value, (int, float)) or (isinstance(value, str) and len(value) > 0) else 1)

    if expr == '((.[0].title == null) or (.[0].title | type == "string"))':
        value = data[0].get('title') if isinstance(data, list) and data and isinstance(data[0], dict) else None
        sys.exit(0 if value is None or isinstance(value, str) else 1)

    if expr == '((.[0].body == null) or (.[0].body | type == "string"))':
        value = data[0].get('body') if isinstance(data, list) and data and isinstance(data[0], dict) else None
        sys.exit(0 if value is None or isinstance(value, str) else 1)

    if expr == '.html_url | type == "string" and length > 0':
        value = data.get('html_url') if isinstance(data, dict) else None
        sys.exit(0 if isinstance(value, str) and len(value) > 0 else 1)

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

    if expr == '.pull_request.title | type == "string" and length > 0':
        pull_request = data.get('pull_request') if isinstance(data, dict) else None
        value = pull_request.get('title') if isinstance(pull_request, dict) else None
        sys.exit(0 if isinstance(value, str) and len(value) > 0 else 1)

    if expr == '.pull_request.body | type == "string" and length > 0':
        pull_request = data.get('pull_request') if isinstance(data, dict) else None
        value = pull_request.get('body') if isinstance(pull_request, dict) else None
        sys.exit(0 if isinstance(value, str) and len(value) > 0 else 1)

    match = re.fullmatch(r'\.commits\[(\d+)\] \| type == "object"', expr)
    if match:
        sys.exit(0 if isinstance(commit_at(int(match.group(1))), dict) else 1)

    match = re.fullmatch(r'\.commits\[(\d+)\]\.(type|message) \| type == "string" and length > 0', expr)
    if match:
        value = commit_value(int(match.group(1)), match.group(2))
        sys.exit(0 if isinstance(value, str) and len(value) > 0 else 1)

    match = re.fullmatch(r'\.commits\[(\d+)\]\.files \| type == "array" and length > 0', expr)
    if match:
        files = commit_value(int(match.group(1)), 'files')
        sys.exit(0 if isinstance(files, list) and len(files) > 0 else 1)

    match = re.fullmatch(r'\.commits\[(\d+)\]\.files\[(\d+)\] \| type == "string" and length > 0', expr)
    if match:
        value = file_value(int(match.group(1)), int(match.group(2)))
        sys.exit(0 if isinstance(value, str) and len(value) > 0 else 1)

if args[0] == '-e' and len(args) >= 2 and args[1] == '.commits | type == "array"':
    sys.exit(0 if isinstance(data.get('commits'), list) else 1)

if args[0] == '-r' and len(args) >= 2:
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

    if expr == '.html_url // empty':
        print(data.get('html_url', ''))
        sys.exit(0)

    if expr == '.html_url':
        print(data.get('html_url', ''))
        sys.exit(0)

    if expr == '.[0].html_url // empty':
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, dict):
                print(first.get('html_url', ''))
                sys.exit(0)
        print('')
        sys.exit(0)

    if expr == '.[0].number // empty':
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, dict):
                print(first.get('number', ''))
                sys.exit(0)
        print('')
        sys.exit(0)

    if expr == '.[0].title // empty':
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, dict):
                print(first.get('title', ''))
                sys.exit(0)
        print('')
        sys.exit(0)

    if expr == '.[0].body // empty':
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, dict):
                print(first.get('body', ''))
                sys.exit(0)
        print('')
        sys.exit(0)

    if expr == '.default_branch // empty':
        print(data.get('default_branch', ''))
        sys.exit(0)

    if expr == '.pull_request.title // empty':
        pull_request = data.get('pull_request', {})
        if isinstance(pull_request, dict):
            print(pull_request.get('title', ''))
            sys.exit(0)
        print('')
        sys.exit(0)

    if expr == '.pull_request.title':
        pull_request = data.get('pull_request', {})
        if isinstance(pull_request, dict):
            print(pull_request.get('title', ''))
            sys.exit(0)
        print('')
        sys.exit(0)

    if expr == '.pull_request.title | if . == null then "null" else type end':
        pull_request = data.get('pull_request', {})
        value = None
        if isinstance(pull_request, dict):
            value = pull_request.get('title', None)
        if value is None:
            print('null')
        elif isinstance(value, str):
            print('string')
        elif isinstance(value, bool):
            print('boolean')
        elif isinstance(value, (int, float)):
            print('number')
        elif isinstance(value, list):
            print('array')
        elif isinstance(value, dict):
            print('object')
        else:
            print('unknown')
        sys.exit(0)

    if expr == '.pull_request.body // empty':
        pull_request = data.get('pull_request', {})
        if isinstance(pull_request, dict):
            print(pull_request.get('body', ''))
            sys.exit(0)
        print('')
        sys.exit(0)

    if expr == '.pull_request.body':
        pull_request = data.get('pull_request', {})
        if isinstance(pull_request, dict):
            print(pull_request.get('body', ''))
            sys.exit(0)
        print('')
        sys.exit(0)

    if expr == '.pull_request.body | if . == null then "null" else type end':
        pull_request = data.get('pull_request', {})
        value = None
        if isinstance(pull_request, dict):
            value = pull_request.get('body', None)
        if value is None:
            print('null')
        elif isinstance(value, str):
            print('string')
        elif isinstance(value, bool):
            print('boolean')
        elif isinstance(value, (int, float)):
            print('number')
        elif isinstance(value, list):
            print('array')
        elif isinstance(value, dict):
            print('object')
        else:
            print('unknown')
        sys.exit(0)

if args[0] == '-rj' and len(args) >= 2:
    expr = args[1]
    match = re.fullmatch(r'\.commits\[(\d+)\]\.files\[\]\? \| \. \+ "\\u0000"', expr)
    if match:
        index = int(match.group(1))
        for item in data.get('commits', [])[index].get('files', []):
            sys.stdout.write(item + '\0')
        sys.exit(0)

sys.exit(1)
EOF
  # shellcheck disable=SC2317
  chmod +x "$stub_path"
}

create_git_api_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

token_stdin_requested=false
stdin_payload=''

if [ -n "${GIT_API_ARGS_LOG:-}" ]; then
  printf '%s\n' 'ARGV_BEGIN' >>"$GIT_API_ARGS_LOG"
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$GIT_API_ARGS_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$GIT_API_ARGS_LOG"
fi

while [ "$#" -gt 0 ]; do
  case "${1:-}" in
  --debug)
    shift
    ;;
  --profile)
    shift 2
    ;;
  --token-stdin)
    token_stdin_requested=true
    shift
    ;;
  *)
    break
    ;;
  esac
done

if [ "$token_stdin_requested" = 'true' ]; then
  stdin_payload=$(cat)
fi

if [ "$token_stdin_requested" = 'true' ] && [ -n "${GIT_API_STDIN_LOG:-}" ]; then
  printf '%s\n' "$stdin_payload" >>"$GIT_API_STDIN_LOG"
fi

case "${1:-}" in
repos/get)
  if [ "${GIT_API_REPOS_GET_FAIL:-false}" = 'true' ]; then
    exit 1
  fi
  if [ -n "${GIT_API_REPOS_GET_RESPONSE:-}" ]; then
    printf '%s\n' "$GIT_API_REPOS_GET_RESPONSE"
  else
    printf '%s\n' '{"default_branch":"main"}'
  fi
  ;;
pulls/list)
  if [ -n "${GIT_API_PULLS_LIST_RESPONSE:-}" ]; then
    printf '%s\n' "$GIT_API_PULLS_LIST_RESPONSE"
  else
    printf '%s\n' '[]'
  fi
  ;;
pulls/update)
  if [ -n "${GIT_API_PULLS_UPDATE_RESPONSE:-}" ]; then
    printf '%s\n' "$GIT_API_PULLS_UPDATE_RESPONSE"
  else
    printf '%s\n' '{"html_url":"https://github.com/octo/demo/pull/77"}'
  fi
  ;;
pulls/create)
  if [ -n "${GIT_API_PULLS_CREATE_RESPONSE:-}" ]; then
    printf '%s\n' "$GIT_API_PULLS_CREATE_RESPONSE"
  else
    printf '%s\n' '{"html_url":"https://github.com/octo/demo/pull/42"}'
  fi
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

if [ -n "${GIT_PROFILE_ARGS_LOG:-}" ]; then
  printf '%s\n' 'ARGV_BEGIN' >>"$GIT_PROFILE_ARGS_LOG"
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$GIT_PROFILE_ARGS_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$GIT_PROFILE_ARGS_LOG"
fi

while [ "${1:-}" = '--debug' ]; do
  shift
done

case "${1:-}" in
token)
  if [ -n "${GIT_PROFILE_TOKEN_ERROR:-}" ]; then
    printf '%s\n' "$GIT_PROFILE_TOKEN_ERROR" >&2
    exit "${GIT_PROFILE_TOKEN_STATUS:-1}"
  fi
  printf '%s\n' "${GIT_PROFILE_TOKEN_STDOUT:-}"
  ;;
*)
  exit 1
  ;;
esac
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
  printf '%s\n' 'ARGV_BEGIN' >>"$PRE_COMMIT_LOG"
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$PRE_COMMIT_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$PRE_COMMIT_LOG"
fi

if [ -n "${PRE_COMMIT_FAIL_FIRST:-}" ] && [ "$attempt" -le "$PRE_COMMIT_FAIL_FIRST" ]; then
  exit 1
fi
EOF
  chmod +x "$stub_path"
}

create_detect_secrets_pre_commit_stub() {
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
  printf 'attempt=%s ARGV_BEGIN\n' "$attempt" >>"$PRE_COMMIT_LOG"
  rendered=''
  for arg in "$@"; do
    printf '%q\n' "$arg" >>"$PRE_COMMIT_LOG"
    printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
  done
  printf 'ARGV_END\nattempt=%s args=%s\n' "$attempt" "$rendered" >>"$PRE_COMMIT_LOG"
fi

repo_root=$(git rev-parse --show-toplevel)
if [ "$attempt" -eq 1 ]; then
  printf 'baseline refresh\n' >>"$repo_root/.secrets.baseline"
  cat >&2 <<'EOFMSG'
Detect secrets...........................................................Failed
- hook id: detect-secrets
- exit code: 3
- files were modified by this hook

The baseline file was updated.
Probably to keep line numbers of secrets up-to-date.
Please `git add .secrets.baseline`, thank you.
EOFMSG
  exit 3
fi

baseline_staged=false
while IFS= read -r file; do
  if [ "$file" = '.secrets.baseline' ]; then
    baseline_staged=true
    break
  fi
done < <(git diff --cached --name-only)

if [ "$baseline_staged" != 'true' ]; then
  echo 'missing staged .secrets.baseline on retry' >&2
  exit 3
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
  printf '1\n1\n2\n' >"$input_file"
  MODEL_PROFILE_BIN="$stub_path" "$TOOL" configure <"$input_file"
}

write_git_commit_config() {
  local profile="$1"
  local model="$2"
  local additional_profile="${3:-}"
  local additional_model="${4:-}"
  local git_api_profile="${5:-}"
  local file

  mkdir -p "$GIT_COMMIT_CONFIG_DIR"
  file="$(git_commit_config_file)"
  printf '[model]\n\tprofile = %s\n\tname = %s\n' "$profile" "$model" >"$file"
  if [ -n "$additional_profile" ] && [ -n "$additional_model" ]; then
    printf '[model "additional"]\n\tprofile = %s\n\tname = %s\n' "$additional_profile" "$additional_model" >>"$file"
  fi
  if [ -n "$git_api_profile" ]; then
    printf '[git-api]\n\tprofile = %s\n' "$git_api_profile" >>"$file"
  fi
}

init_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.name 'Test User'
  git -C "$repo" config user.email 'test@example.com'
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

create_initial_commit() {
  local repo="$1"

  printf '%s\n' 'initial' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m 'chore(init): initial commit'
}

@test "help and configure command" {
  local stub_path output

  stub_path="$TMP_HOME/model-profile-stub"
  create_model_provider_stub "$stub_path"

  output=$(MODEL_PROFILE_BIN="$stub_path" "$TOOL" --help)
  assert_contains "$output" 'Usage: git-commit [command]' 'help should describe usage'
  assert_contains "$output" 'configure  Select the model profile, model, and optional git-api profile to use' 'help should list configure'
  assert_contains "$output" '--apply' 'help should list apply mode'
  assert_contains "$output" '--debug' 'help should list debug mode'
  assert_contains "$output" '--push' 'help should list push mode'
  assert_contains "$output" '--pr' 'help should list pull request mode'
  assert_contains "$output" 'picotools.gitProfile' 'help should document repository context for PR auth'
  assert_contains "$output" "then the configured \`git-api.profile\`" 'help should document PR auth precedence'
  assert_contains "$output" '--pre-commit-retries <n>' 'help should list pre-commit retry option'

  printf '2\n2\n2\n' | MODEL_PROFILE_BIN="$stub_path" "$TOOL" configure >/dev/null 2>&1
  assert_file_exists "$(git_commit_config_file)" 'configure should create a config file'
  assert_config_value model.profile 'beta-profile' 'configure should save the selected profile'
  assert_config_value model.name 'beta-model-2' 'configure should save the selected model'
  assert_config_missing model.additional.profile 'configure should not save an additional profile when none is selected'
  assert_config_missing model.additional.name 'configure should not save an additional model when none is selected'
  assert_config_missing git-api.profile 'configure should not save a git-api profile when none are configured'
}

@test "configure command can save an optional additional model profile" {
  local stub_path

  stub_path="$TMP_HOME/model-profile-stub"
  create_model_provider_stub "$stub_path"

  printf '1\n1\n1\n2\n' | MODEL_PROFILE_BIN="$stub_path" "$TOOL" configure >/dev/null 2>&1

  assert_file_exists "$(git_commit_config_file)" 'configure should create a config file when additional model profile is selected'
  assert_config_value model.profile 'alpha-profile' 'configure should save the primary selected profile'
  assert_config_value model.name 'alpha-model' 'configure should save the primary selected model'
  assert_config_value model.additional.profile 'beta-profile' 'configure should exclude the primary profile from the additional profile list'
  assert_config_value model.additional.name 'beta-model-2' 'configure should save the selected additional model'
}

@test "configure command can save an optional git-api profile" {
  local stub_path

  stub_path="$TMP_HOME/model-profile-stub"
  create_model_provider_stub "$stub_path"
  mkdir -p "$TMP_HOME/.local/share/git-api/profiles/work"
  printf '%s\n' 'work-token' >"$TMP_HOME/.local/share/git-api/profiles/work/token"

  printf '1\n1\n2\n1\n' | MODEL_PROFILE_BIN="$stub_path" "$TOOL" configure >/dev/null 2>&1

  assert_file_exists "$(git_commit_config_file)" 'configure should create a config file when a git-api profile is selected'
  assert_config_value model.profile 'alpha-profile' 'configure should save the selected model profile'
  assert_config_value model.name 'alpha-model' 'configure should save the selected model'
  assert_config_value git-api.profile 'work' 'configure should save the selected git-api profile'
}

@test "warns when configuration is missing" {
  local stub_path repo output

  stub_path="$TMP_HOME/model-profile-stub"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf '%s\n' 'change' >>"$repo/README.md"

  if output=$(cd "$repo" && MODEL_PROFILE_BIN="$stub_path" "$TOOL" 2>&1); then
    fail 'git-commit should fail when configuration is missing'
  fi

  assert_contains "$output" 'Warning: git-commit is not configured. Run git-commit configure.' 'git-commit should warn when configuration is missing'
}

@test "fails on detached HEAD" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q HEAD~0
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" 2>&1); then
    fail 'git-commit should fail on detached HEAD'
  fi

  assert_contains "$output" 'Error: detached HEAD is not supported' 'git-commit should reject detached HEAD before planning commits'
}

@test "fails when pre-staged changes are kept" {
  local stub_path repo output

  stub_path="$TMP_HOME/model-profile-stub"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && printf 'n\n' | MODEL_PROFILE_BIN="$stub_path" "$TOOL" 2>&1); then
    fail 'git-commit should fail when staged changes already exist'
  fi

  assert_contains "$output" 'Staged changes detected. Unstage them with git restore --staged :/? [y/N]:' 'git-commit should prompt before unstaging changes'
  assert_contains "$output" 'Error: git-commit requires no pre-staged changes. Unstage them first.' 'git-commit should explain why pre-staged changes are rejected'
}

@test "can unstage pre-staged changes and continue" {
  local stub_path jq_stub repo output staged_after head_subject

  stub_path="$TMP_HOME/model-profile-stub"
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
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
      "$TOOL" 2>&1)

  assert_contains "$output" "$(preview_git_add_command README.md)" 'git-commit should print an add command using the planned file list after unstaging staged changes'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): update readme')" 'git-commit should print the proposed commit command after unstaging staged changes'
  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_eq "$staged_after" '' 'git-commit should leave no staged changes after unstaging them for preview'
  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'chore(init): initial commit' 'git-commit should not create a commit during preview'
}

@test "creates a single conventional commit from one plan item" {
  local stub_path jq_stub repo ask_log output head_subject staged_after

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
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
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should create a single commit successfully ($output)"
  fi

  assert_contains "$output" "$(preview_git_add_command README.md notes.txt)" 'git-commit should print an add command using the planned file list for a single planned commit'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add repository notes')" 'git-commit should print a conventional commit command with derived scope'
  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'chore(init): initial commit' 'git-commit should not create the commit automatically'
  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_eq "$staged_after" '' 'git-commit should not stage files automatically in preview mode'
  assert_contains "$(<"$ask_log")" 'ask alpha-profile --model alpha-model' 'git-commit should call model-profile ask with configured profile and model'
  assert_contains "$(<"$ask_log")" '--system-message-file' 'git-commit should pass the system prompt through a temp file'
  assert_contains "$(<"$ask_log")" '--message-file' 'git-commit should pass the user prompt through a temp file'
  assert_contains "$(<"$ask_log")" 'SYSTEM_MESSAGE_FILE_CONTENT=You are an expert software engineer creating conventional commit plans.' 'git-commit should write the system prompt into the temp file'
  assert_contains "$(<"$ask_log")" 'MESSAGE_FILE_CONTENT=Analyze these current git workspace changes and propose conventional commit plan JSON.' 'git-commit should write the user prompt into the temp file'
  assert_contains "$(<"$ask_log")" 'Allowed types: feat, fix, docs, refactor, chore, perf, test, ci' 'git-commit should keep the allowed commit types in the prompt aligned with runtime validation'
  assert_contains "$(<"$ask_log")" 'Each changed file must appear in exactly one commit, even when there is only one commit.' 'git-commit should tell the model that file coverage is strict even for a single commit'
  assert_contains "$(<"$ask_log")" "Before returning, check the full changed-file list and confirm every listed file appears exactly once across all commit \`files\` arrays." 'git-commit should tell the model to verify the changed-file list before returning'
  assert_contains "$(<"$ask_log")" 'Before returning, confirm the final response string is a single valid JSON object with the exact requested shape and no extra text before or after it.' 'git-commit should tell the model to verify the raw JSON response string before returning'
  assert_not_contains "$(<"$ask_log")" '"pull_request":{"title":"short pr title","body":"detailed markdown description"}' 'git-commit should not request PR details unless --pr is used'
}

@test "fails when a commit message does not start with a lower-case verb" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"Updated readme","files":["README.md"]}]}' \
    "$TOOL" 2>&1); then
    fail 'git-commit should fail when a commit message does not start with a lower-case verb'
  fi

  assert_contains "$output" 'Error: commit plan item 1 must start with an imperative lower-case verb' 'git-commit should validate commit message style locally'
}

@test "retries commit planning when the first plan has an invalid commit type" {
  local stub_path jq_stub repo ask_log sequence_file index_file output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  sequence_file="$TMP_HOME/model-responses.txt"
  index_file="$TMP_HOME/model-response-index.txt"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf '%s\n' \
    '{"commits":[{"type":"feature","message":"add readme","files":["README.md"]}]}' \
    '{"commits":[{"type":"feat","message":"add readme","files":["README.md"]}]}' \
    >"$sequence_file"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
    MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE="$sequence_file" \
    MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE="$index_file" \
    "$TOOL" 2>&1); then
    fail "git-commit should retry and accept the corrected commit type ($output)"
  fi

  assert_eq "$(<"$index_file")" '2' 'git-commit should request exactly one correction retry for invalid types'
  assert_contains "$(<"$ask_log")" 'Correction required:' 'retry request should include correction guidance'
  assert_contains "$(<"$ask_log")" 'invalid commit type in plan: feature' 'retry request should include the validation error'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add readme')" 'corrected plan should be rendered'
}

@test "retries commit planning when the first plan has an invalid commit message" {
  local stub_path jq_stub repo ask_log sequence_file index_file output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  sequence_file="$TMP_HOME/model-responses.txt"
  index_file="$TMP_HOME/model-response-index.txt"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf '%s\n' \
    '{"commits":[{"type":"feat","message":"Updated readme","files":["README.md"]}]}' \
    '{"commits":[{"type":"feat","message":"add readme","files":["README.md"]}]}' \
    >"$sequence_file"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
    MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE="$sequence_file" \
    MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE="$index_file" \
    "$TOOL" 2>&1); then
    fail "git-commit should retry and accept the corrected commit message ($output)"
  fi

  assert_eq "$(<"$index_file")" '2' 'git-commit should request exactly one correction retry for invalid messages'
  assert_contains "$(<"$ask_log")" 'Correction required:' 'retry request should include correction guidance'
  assert_contains "$(<"$ask_log")" 'must start with an imperative lower-case verb' 'retry request should include the validation error'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add readme')" 'corrected plan should be rendered'
}

@test "fails when a single-commit plan does not cover all changed files" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222_2
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md"]}]}' \
    "$TOOL" 2>&1); then
    fail 'git-commit should fail when a single-commit plan does not cover all changed files'
  fi

  assert_contains "$output" 'Error: commit plan did not cover changed file: notes.txt' 'git-commit should reject single-commit plans that omit changed files'
}

@test "limits commit planning to the selected file path scope" {
  local stub_path jq_stub repo ask_log output ask_payload

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
      "$TOOL" --path README.md 2>&1
  ); then
    fail "git-commit should succeed when --path limits planning to README.md ($output)"
  fi

  ask_payload=$(<"$ask_log")
  assert_contains "$output" "$(preview_git_add_command README.md)" 'git-commit should preview commits for the selected file scope only'
  assert_not_contains "$ask_payload" 'notes.txt' 'git-commit should exclude unrelated changed files from the planning prompt when --path is used'
}

@test "supports multiple scoped paths from flags and path files" {
  local stub_path jq_stub repo ask_log path_file output ask_payload

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  path_file="$TMP_HOME/paths.txt"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  mkdir -p "$repo/docs"
  printf 'updated\n' >>"$repo/README.md"
  printf 'guide\n' >"$repo/docs/guide.md"
  printf 'new file\n' >"$repo/notes.txt"
  printf '%s\n' 'docs' >"$path_file"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"docs","message":"update docs","files":["README.md","docs/guide.md"]}]}' \
      "$TOOL" --path README.md --path-file "$path_file" 2>&1
  ); then
    fail "git-commit should accept multiple scoped paths from flags and files ($output)"
  fi

  ask_payload=$(<"$ask_log")
  assert_contains "$output" "$(preview_git_add_command README.md docs/guide.md)" 'git-commit should preview all selected-scope files from flags and path files'
  assert_contains "$ask_payload" 'README.md' 'git-commit should include directly selected files in the planning prompt'
  assert_contains "$ask_payload" 'docs/guide.md' 'git-commit should include path-file selected directories in the planning prompt'
  assert_not_contains "$ask_payload" 'notes.txt' 'git-commit should still exclude unrelated changes outside the selected path scopes'
}

@test "resolves relative scoped paths from a subdirectory" {
  local stub_path jq_stub repo ask_log output ask_payload

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  mkdir -p "$repo/docs/guides"
  printf 'updated\n' >>"$repo/README.md"
  printf 'guide\n' >"$repo/docs/guides/intro.md"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(
    cd "$repo/docs" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"docs","message":"update readme","files":["README.md"]}]}' \
      "$TOOL" --path ../README.md 2>&1
  ); then
    fail "git-commit should resolve relative --path values from subdirectories ($output)"
  fi

  ask_payload=$(<"$ask_log")
  assert_contains "$output" "$(preview_git_add_command README.md)" 'git-commit should normalize relative scoped paths to repo-root paths in preview output'
  assert_contains "$ask_payload" 'README.md' 'git-commit should plan using the normalized repo-root path'
  assert_not_contains "$ask_payload" 'docs/guides/intro.md' 'git-commit should exclude unrelated changes when a relative scoped path selects a single file'
}

@test "fails when the model returns an empty commit plan" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[]}' \
    "$TOOL" 2>&1); then
    fail 'git-commit should fail when the model returns an empty commit plan'
  fi

  assert_contains "$output" 'Error: commit plan commits must be a nonempty array' 'git-commit should reject empty commit plans'
}

@test "falls back to the additional model profile on HTTP 429" {
  local stub_path jq_stub repo ask_log output ask_payload

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model beta-profile beta-model-2

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_FAIL_PROFILE='alpha-profile' \
      MODEL_PROFILE_ASK_FAIL_MODEL='alpha-model' \
      MODEL_PROFILE_ASK_FAIL_MESSAGE='Error: request failed with HTTP 429' \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should retry with the additional model after HTTP 429 ($output)"
  fi

  ask_payload=$(<"$ask_log")
  assert_contains "$ask_payload" 'ask alpha-profile --model alpha-model' 'git-commit should try the primary configured model first'
  assert_contains "$ask_payload" 'ask beta-profile --model beta-model-2' 'git-commit should retry with the configured additional model after HTTP 429'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): update readme')" 'git-commit should still print the commit preview after falling back to the additional model'
}

@test "falls back to the additional model profile on HTTP 503" {
  local stub_path jq_stub repo ask_log output ask_payload

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model beta-profile beta-model-2

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_FAIL_PROFILE='alpha-profile' \
      MODEL_PROFILE_ASK_FAIL_MODEL='alpha-model' \
      MODEL_PROFILE_ASK_FAIL_MESSAGE='Error: request failed with HTTP 503' \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should retry with the additional model after HTTP 503 ($output)"
  fi

  ask_payload=$(<"$ask_log")
  assert_contains "$ask_payload" 'ask alpha-profile --model alpha-model' 'git-commit should try the primary configured model first before handling HTTP 503'
  assert_contains "$ask_payload" 'ask beta-profile --model beta-model-2' 'git-commit should retry with the configured additional model after HTTP 503'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): update readme')" 'git-commit should still print the commit preview after a HTTP 503 fallback'
}

@test "fails immediately on HTTP 503 when no additional model profile is configured" {
  local stub_path jq_stub git_api_stub remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_FAIL_PROFILE='alpha-profile' \
    MODEL_PROFILE_ASK_FAIL_MODEL='alpha-model' \
    MODEL_PROFILE_ASK_FAIL_MESSAGE='Error: request failed with HTTP 503' \
    GIT_API_BIN="$git_api_stub" \
    "$TOOL" --pr 2>&1); then
    fail 'git-commit should fail immediately when the primary model request returns HTTP 503 and no additional model is configured'
  fi

  assert_contains "$output" 'Error: request failed with HTTP 503' 'git-commit should surface the original model request error'
  assert_not_contains "$output" 'did not return valid commit plan JSON' 'git-commit should not continue into JSON validation after a failed model request'
}

@test "omits oversized modified file diffs before calling model-profile" {
  local stub_path jq_stub repo ask_log output ask_payload

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  head -c 2100000 /dev/zero | tr '\0' 'a' >>"$repo/README.md"
  printf '\nTAIL_SENTINEL_123\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"expand readme","files":["README.md"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should handle oversized modified file diffs successfully ($output)"
  fi

  ask_payload=$(<"$ask_log")
  assert_contains "$ask_payload" '[Omitted diff for README.md because its diff size (' 'git-commit should omit oversized modified file diffs before calling model-profile'
  case "$ask_payload" in
  *TAIL_SENTINEL_123*)
    fail 'git-commit should not include the omitted large modified file diff contents in the prompt'
    ;;
  esac
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): expand readme')" 'git-commit should still print the planned commit after omitting the modified file diff'
}

@test "omits oversized added file diffs from the planning prompt" {
  local stub_path jq_stub repo ask_log output ask_payload

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  head -c 300000 /dev/zero | tr '\0' 'b' >"$repo/large-added.txt"
  printf '\nADDED_FILE_TAIL_SENTINEL_456\n' >>"$repo/large-added.txt"

  write_git_commit_config alpha-profile alpha-model

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add large added file","files":["large-added.txt"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should omit oversized added file diffs successfully ($output)"
  fi

  ask_payload=$(<"$ask_log")
  assert_contains "$ask_payload" '[Omitted added file diff for large-added.txt because its size (' 'git-commit should omit oversized added file diffs from the prompt'
  case "$ask_payload" in
  *ADDED_FILE_TAIL_SENTINEL_456*)
    fail 'git-commit should not include the omitted large added file contents in the prompt'
    ;;
  esac
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add large added file')" 'git-commit should still print the planned commit after omitting the added file diff'
}

@test "prints progress steps when --debug is enabled" {
  local stub_path jq_stub repo ask_log output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --debug 2>&1)

  assert_contains "$output" '[git-commit] Checking repository state' 'git-commit should print the initial debug step'
  assert_contains "$output" '[git-commit] Collecting changed files' 'git-commit should print a changed-files debug step'
  assert_contains "$output" '[git-commit] Requesting commit plan from model-profile ' 'git-commit should print a model-profile debug step'
  assert_contains "$output" '[model-profile] Stub debug enabled' 'git-commit should enable model-profile debug output in debug mode'
  assert_contains "$(<"$ask_log")" 'ask alpha-profile --model alpha-model' 'git-commit should still call model-profile ask with the configured profile and model'
  assert_contains "$(<"$ask_log")" '--debug' 'git-commit should forward --debug to model-profile'
  assert_contains "$output" '[git-commit] Printing commit plan preview' 'git-commit should print the preview debug step'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): update readme')" 'git-commit should still print the commit preview in debug mode'
}

@test "creates multiple commits from grouped file plan" {
  local stub_path jq_stub repo output head_subject staged_after

  stub_path="$TMP_HOME/model-profile-stub"
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
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"fix","message":"update application logic","files":["src/app.txt"]},{"type":"test","message":"add coverage for application logic","files":["tests/app.txt"]}]}' \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should create grouped commits successfully ($output)"
  fi

  assert_contains "$output" 'Commit 1:' 'git-commit should print a header for the first grouped commit'
  assert_contains "$output" 'git add -A -- :\(top\,literal\)src/app.txt' 'git-commit should print a repo-root grouped add command for the first commit'
  assert_contains "$output" "$(preview_git_commit_command 'fix(445566): update application logic')" 'git-commit should print the first grouped commit command'
  assert_contains "$output" 'Commit 2:' 'git-commit should print a header for the second grouped commit'
  assert_contains "$output" 'git add -A -- :\(top\,literal\)tests/app.txt' 'git-commit should print a repo-root grouped add command for the second commit'
  assert_contains "$output" "$(preview_git_commit_command 'test(445566): add coverage for application logic')" 'git-commit should print the second grouped commit command'
  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'chore(init): initial commit' 'git-commit should not create grouped commits automatically'
  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_eq "$staged_after" '' 'git-commit should not stage grouped files automatically in preview mode'
}

@test "omits scope when branch name has no slash" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"chore","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --apply 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'chore: update readme')" 'git-commit should omit scope when branch name has no slash'
}

@test "uses changed module name as scope in a monorepo when branch scope is unavailable" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b dv
  mkdir -p "$repo/packages/ui/src"
  printf 'packages:\n  - packages/*\n' >"$repo/pnpm-workspace.yaml"
  printf '{"name":"ui"}\n' >"$repo/packages/ui/package.json"
  printf 'export const value = 1\n' >"$repo/packages/ui/src/index.ts"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update ui module","files":["pnpm-workspace.yaml","packages/ui/package.json","packages/ui/src/index.ts"]}]}' \
    "$TOOL" 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'feat(ui): update ui module')" 'git-commit should fall back to the changed monorepo module name'
}

@test "uses the leaf package name as scope in a node monorepo when available" {
  local stub_path jq_stub repo ask_log output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b dv
  mkdir -p "$repo/packages/ui/src"
  printf 'packages:\n  - packages/*\n' >"$repo/pnpm-workspace.yaml"
  printf '{"name":"@acme/ui"}\n' >"$repo/packages/ui/package.json"
  printf 'export const value = 1\n' >"$repo/packages/ui/src/index.ts"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update ui module","files":["pnpm-workspace.yaml","packages/ui/package.json","packages/ui/src/index.ts"]}]}' \
    "$TOOL" 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'feat(ui): update ui module')" 'git-commit should prefer the leaf package name over the scoped package prefix'
  assert_contains "$(<"$ask_log")" $'Derived scope:\nui' 'git-commit should send the leaf package name as the derived scope in the planning prompt'
  assert_contains "$(<"$ask_log")" 'do not repeat that scope value or its parent package/org prefix' 'git-commit should tell the model to avoid repeating monorepo scope names in the message'
  assert_contains "$(<"$ask_log")" 'The final commit header, including the type/scope prefix, must not exceed 100 characters.' 'git-commit should tell the model about the commit header length limit'
}

@test "omits scope when monorepo changes span multiple modules" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b dv
  mkdir -p "$repo/packages/ui/src" "$repo/packages/api/src"
  printf 'packages:\n  - packages/*\n' >"$repo/pnpm-workspace.yaml"
  printf '{"name":"ui"}\n' >"$repo/packages/ui/package.json"
  printf '{"name":"api"}\n' >"$repo/packages/api/package.json"
  printf 'export const ui = 1\n' >"$repo/packages/ui/src/index.ts"
  printf 'export const api = 1\n' >"$repo/packages/api/src/index.ts"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"chore","message":"update shared workspace files","files":["pnpm-workspace.yaml","packages/ui/package.json","packages/ui/src/index.ts","packages/api/package.json","packages/api/src/index.ts"]}]}' \
    "$TOOL" 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'chore: update shared workspace files')" 'git-commit should omit scope when multiple monorepo modules are changed'
}

@test "uses explicit --scope override instead of branch-derived scope" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --scope override 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'feat(override): update readme')" 'git-commit should use the explicit scope override'
}

@test "uses explicit --scope=value override instead of branch-derived scope" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --scope=override 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'feat(override): update readme')" 'git-commit should accept --scope=value'
}

@test "rejects generated commit headers over 100 characters" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222_2
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"refresh git, model, release, license, asdf, API, and route tools to use shared helpers and improved flows","files":["README.md"]}]}' \
    "$TOOL" 2>&1); then
    fail 'git-commit should reject commit plans with infeasible headers'
  fi

  assert_contains "$output" 'Error: commit plan item 1 header must not exceed 100 characters' 'git-commit should reject headers that cannot fit without truncation'
}

@test "strips trailing numeric branch suffix from derived ticket scope" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b chore/CCP-4318_2
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"chore","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'chore(CCP-4318): update readme')" 'git-commit should strip the trailing numeric branch suffix from the derived scope'
}

@test "omits scope when --no-scope is provided" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --no-scope 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'feat: update readme')" 'git-commit should omit scope when --no-scope is provided'
}

@test "runs pre-commit on changed files when hook exists" {
  local stub_path jq_stub pre_commit_stub repo output pre_commit_log

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}],"pull_request":{"title":"feat(11222): add repository notes","body":"## Summary\n- add repository notes"}}' \
    "$TOOL" --apply 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add repository notes')" 'git-commit should continue after successful pre-commit checks'
  assert_contains "$(<"$pre_commit_log")" 'hook-impl --hook-type pre-commit' 'git-commit should execute the installed pre-commit hook'
}

@test "retries pre-commit up to two more times after failures" {
  local stub_path jq_stub pre_commit_stub repo output pre_commit_log pre_commit_attempts

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --apply 2>&1)

  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): update readme')" 'git-commit should continue after pre-commit succeeds on a retry'
  assert_eq "$(<"$pre_commit_attempts")" '3' 'git-commit should retry pre-commit up to three total attempts'
  assert_contains "$(<"$pre_commit_log")" 'hook-impl --hook-type pre-commit' 'git-commit should retry the installed pre-commit hook'
}

@test "stages detect-secrets baseline updates after a pre-commit retry" {
  local stub_path jq_stub pre_commit_stub repo output pre_commit_log pre_commit_attempts head_subject status_after baseline_contents

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  pre_commit_stub="$TMP_HOME/pre-commit"
  pre_commit_log="$TMP_HOME/pre-commit.log"
  pre_commit_attempts="$TMP_HOME/pre-commit.attempts"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_detect_secrets_pre_commit_stub "$pre_commit_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  printf '{"results": {}}\n' >"$repo/.secrets.baseline"
  git -C "$repo" add .secrets.baseline
  git -C "$repo" commit -q -m 'chore: add secrets baseline'
  install_pre_commit_hook "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'pending refresh\n' >>"$repo/.secrets.baseline"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    PRE_COMMIT_LOG="$pre_commit_log" \
    PRE_COMMIT_ATTEMPTS_FILE="$pre_commit_attempts" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"refresh readme secrets metadata","files":["README.md",".secrets.baseline"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat(11222): refresh readme secrets metadata' 'git-commit should finish the commit after detect-secrets updates the baseline'
  assert_eq "$(<"$pre_commit_attempts")" '2' 'git-commit should retry pre-commit before isolated commit creation'
  assert_contains "$output" "Please \`git add .secrets.baseline\`, thank you." 'git-commit should surface the detect-secrets retry output'
  assert_contains "$(<"$pre_commit_log")" 'attempt=2 args=hook-impl --hook-type pre-commit' 'git-commit should rerun the pre-commit hook after the baseline changes'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after committing the refreshed baseline'
  baseline_contents=$(git -C "$repo" show HEAD:.secrets.baseline)
  assert_contains "$baseline_contents" 'baseline refresh' 'git-commit should include the detect-secrets baseline update in the commit'
}

@test "prints shell-safe preview commands for commit titles" {
  # shellcheck disable=SC2016
  {
    local stub_path jq_stub repo output expected_command

    stub_path="$TMP_HOME/model-profile-stub"
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
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"run $(whoami) `pwd` safely","files":["README.md"]}]}' \
      "$TOOL" 2>&1)

    expected_command=$(preview_git_commit_command 'feat(11222): run $(whoami) `pwd` safely')
    assert_contains "$output" "$expected_command" 'git-commit should print a shell-safe preview command for generated commit titles'
    assert_not_contains "$output" 'git commit -m "feat(11222): run $(whoami) `pwd` safely"' 'git-commit should not print an unsafe double-quoted preview command for generated commit titles'
  }
}

@test "respects --pre-commit-retries override" {
  local stub_path jq_stub pre_commit_stub repo output pre_commit_attempts

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    "$TOOL" --apply --pre-commit-retries 1 2>&1); then
    fail 'git-commit should fail after the configured pre-commit retry limit is reached'
  fi

  assert_contains "$output" 'Error: pre-commit checks failed after 2 attempts' 'git-commit should report the configured total attempts'
  assert_eq "$(<"$pre_commit_attempts")" '2' 'git-commit should stop after the configured retry limit'
}

@test "fails early when the installed pre-commit hook rejects the staged snapshot" {
  local stub_path jq_stub pre_commit_stub repo output staged_after

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add script","files":["script.bash"]}]}' \
    "$TOOL" --apply 2>&1); then
    fail 'git-commit should fail when the installed pre-commit hook rejects the staged snapshot'
  fi

  staged_after=$(git -C "$repo" diff --cached --name-only)
  assert_contains "$output" 'Shellcheck Bash Linter' 'git-commit should surface the installed hook failure'
  assert_eq "$staged_after" '' 'git-commit should leave the real index untouched when pre-commit checks fail'
}

@test "applies a single planned commit with --apply" {
  local stub_path jq_stub repo output head_subject status_after

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}],"pull_request":{"title":"feat(11222): add repository notes","body":"## Summary\n- add repository notes"}}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat(11222): add repository notes' 'git-commit should create the planned commit in apply mode'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after apply mode'
  assert_contains "$output" "$(preview_git_add_command README.md notes.txt)" 'git-commit should print the add command using the planned file list before applying a single commit'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add repository notes')" 'git-commit should print the planned commit command before applying it'
  assert_contains "$output" 'feat(11222): add repository notes' 'git-commit should show the created commit title in apply mode'
}

@test "applies .pre-commit-config.yaml first when it is grouped with other files" {
  local stub_path jq_stub repo output head_subject previous_subject status_after

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'repos:\n- repo: https://github.com/pre-commit/pre-commit-hooks\n' >"$repo/.pre-commit-config.yaml"
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":[".pre-commit-config.yaml","README.md","notes.txt"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  previous_subject=$(git -C "$repo" log -2 --pretty=%s | sed -n '2p')
  assert_eq "$head_subject" 'feat(11222): add repository notes' 'git-commit should keep the planned commit after bootstrapping the pre-commit config'
  assert_eq "$previous_subject" 'chore(11222): add pre-commit config' 'git-commit should commit .pre-commit-config.yaml first in its own bootstrap commit'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after splitting out the pre-commit config commit'
  assert_contains "$output" 'Commit 1:' 'git-commit should show the synthetic pre-commit config commit first in the preview'
  assert_contains "$output" "$(preview_git_add_command .pre-commit-config.yaml)" 'git-commit should preview a config-only add command first'
  assert_contains "$output" "$(preview_git_commit_command 'chore(11222): add pre-commit config')" 'git-commit should preview the synthetic config-only commit first'
  assert_contains "$output" 'Commit 2:' 'git-commit should show the remaining planned commit after the synthetic config commit'
  assert_contains "$output" "$(preview_git_add_command README.md notes.txt)" 'git-commit should remove the pre-commit config from the later planned add command'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add repository notes')" 'git-commit should still preview the original planned commit title'
}

@test "applies updated .pre-commit-config.yaml first when it changes" {
  local stub_path jq_stub repo output head_subject previous_subject status_after

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  printf 'repos:\n- repo: https://github.com/pre-commit/pre-commit-hooks\n' >"$repo/.pre-commit-config.yaml"
  git -C "$repo" add .pre-commit-config.yaml
  git -C "$repo" commit -q -m 'chore: add pre-commit config'
  git -C "$repo" checkout -q -b feat/11222
  printf 'repos:\n- repo: https://github.com/pre-commit/pre-commit-hooks\n  rev: v4.6.0\n' >"$repo/.pre-commit-config.yaml"
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"refresh repository automation","files":[".pre-commit-config.yaml","README.md"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  previous_subject=$(git -C "$repo" log -2 --pretty=%s | sed -n '2p')
  assert_eq "$head_subject" 'feat(11222): refresh repository automation' 'git-commit should still create the planned commit after updating the pre-commit config first'
  assert_eq "$previous_subject" 'chore(11222): update pre-commit config' 'git-commit should use an update-specific bootstrap title when the pre-commit config already exists'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after splitting out an updated pre-commit config'
}

@test "--push implies --apply" {
  local stub_path jq_stub remote repo output head_subject remote_head_subject upstream_branch status_after

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}],"pull_request":{"title":"feat(11222): add repository notes","body":"## Summary\n- add repository notes"}}' \
    "$TOOL" --push 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat(11222): add repository notes' 'git-commit should create the planned commit when push mode implies apply mode'
  remote_head_subject=$(git -C "$remote" log -1 --pretty=%s refs/heads/feat/11222)
  assert_eq "$remote_head_subject" 'feat(11222): add repository notes' 'git-commit should push the created commit when push mode implies apply mode'
  upstream_branch=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
  assert_eq "$upstream_branch" 'origin/feat/11222' 'git-commit should set upstream when push mode implies apply mode'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree when push mode implies apply mode'
  assert_contains "$output" "$(preview_git_add_command README.md notes.txt)" 'git-commit should print the add command using the planned file list before applying when push mode is used'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add repository notes')" 'git-commit should print the planned commit command before pushing'
  assert_contains "$output" 'feat(11222): add repository notes' 'git-commit should show the created commit title when push mode implies apply mode'
}

@test "--pr implies --apply and --push" {
  local stub_path jq_stub git_api_stub git_api_log remote repo ask_log output head_subject remote_head_subject upstream_branch status_after ask_count

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api-args.log"
  ask_log="$TMP_HOME/model-profile-ask.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}],"pull_request":{"title":"feat(11222): add repository notes","body":"## Summary\n- update README\n- add repository notes file"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    "$TOOL" --pr 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat(11222): add repository notes' 'git-commit should create the planned commit when PR mode implies apply and push'
  remote_head_subject=$(git -C "$remote" log -1 --pretty=%s refs/heads/feat/11222)
  assert_eq "$remote_head_subject" 'feat(11222): add repository notes' 'git-commit should push the created commit when PR mode implies apply and push'
  upstream_branch=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
  assert_eq "$upstream_branch" 'origin/feat/11222' 'git-commit should set upstream when PR mode implies apply and push'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree when PR mode implies apply and push'
  assert_contains "$output" "$(preview_git_add_command README.md notes.txt)" 'git-commit should print the add command using the planned file list before applying when PR mode is used'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add repository notes')" 'git-commit should print the planned commit command before opening a PR'
  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should print the created pull request URL when PR mode implies apply and push'
  assert_contains "$(<"$ask_log")" '"pull_request":{"title":"short pr title","body":"detailed markdown description"}' 'git-commit should request PR title and body in the planning prompt when --pr is used'
  ask_count=$(grep -c '^ask alpha-profile --model alpha-model' "$ask_log")
  assert_eq "$ask_count" '1' 'git-commit should use a single model ask call when --pr is used'
  assert_contains "$(<"$git_api_log")" 'repos/get octo demo' 'git-commit should query the repository default branch when PR mode implies apply and push'
  assert_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'git-commit should create the pull request when PR mode implies apply and push'
  assert_contains "$(<"$git_api_log")" 'title=feat(11222): add repository notes' 'git-commit should use the AI-provided PR title from the single planning response'
  assert_contains "$(<"$git_api_log")" 'body=## Summary' 'git-commit should use the AI-provided PR body from the single planning response'
}

@test "applies and pushes a single planned commit with --push" {
  local stub_path jq_stub remote repo output head_subject remote_head_subject upstream_branch status_after

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}],"pull_request":{"title":"feat(11222): add repository notes","body":"## Summary\n- add repository notes"}}' \
    "$TOOL" --push 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat(11222): add repository notes' 'git-commit should create the planned commit before pushing'
  remote_head_subject=$(git -C "$remote" log -1 --pretty=%s refs/heads/feat/11222)
  assert_eq "$remote_head_subject" 'feat(11222): add repository notes' 'git-commit should push the created commit to the remote branch'
  upstream_branch=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
  assert_eq "$upstream_branch" 'origin/feat/11222' 'git-commit should set upstream when pushing a new branch'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after apply and push mode'
  assert_contains "$output" "$(preview_git_add_command README.md notes.txt)" 'git-commit should print the add command using the planned file list before applying in apply and push mode'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add repository notes')" 'git-commit should print the planned commit command before applying in apply and push mode'
  assert_contains "$output" 'feat(11222): add repository notes' 'git-commit should show the created commit title in apply and push mode'
}

@test "applies, pushes, and opens a pull request with --pr using the default branch from git-api" {
  local stub_path jq_stub git_api_stub git_api_log remote repo output head_subject remote_head_subject upstream_branch status_after

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}],"pull_request":{"title":"feat(11222): add repository notes","body":"## Summary\n- add repository notes"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    "$TOOL" --pr 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat(11222): add repository notes' 'git-commit should create the planned commit before opening a pull request'
  remote_head_subject=$(git -C "$remote" log -1 --pretty=%s refs/heads/feat/11222)
  assert_eq "$remote_head_subject" 'feat(11222): add repository notes' 'git-commit should push the created commit before opening a pull request'
  upstream_branch=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
  assert_eq "$upstream_branch" 'origin/feat/11222' 'git-commit should set upstream before opening a pull request'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after apply, push, and PR mode'
  assert_contains "$output" "$(preview_git_add_command README.md notes.txt)" 'git-commit should print the add command using the planned file list before applying in PR mode'
  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): add repository notes')" 'git-commit should print the planned commit command before applying in PR mode'
  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should print the created pull request URL'
  assert_contains "$(<"$git_api_log")" 'repos/get octo demo' 'git-commit should query the repository default branch through git-api'
  assert_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'git-commit should create the pull request through git-api'
  assert_contains "$(<"$git_api_log")" 'base=main' 'git-commit should target the main branch'
  assert_contains "$(<"$git_api_log")" 'head=feat/11222' 'git-commit should use the current branch as the PR head'
}

@test "updates an existing pull request when one is already open" {
  local stub_path jq_stub git_api_stub git_api_log remote repo ask_log output head_subject remote_head_subject upstream_branch status_after

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api-args.log"
  ask_log="$TMP_HOME/model-profile-ask.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"
  printf 'new file\n' >"$repo/notes.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add repository notes","files":["README.md","notes.txt"]}],"pull_request":{"title":"feat(11222): add repository notes","body":"## Summary\n- existing PR changes\n- current local changes"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_PULLS_LIST_RESPONSE='[{"number":77,"title":"feat(11222): previous scope","body":"## Existing Summary\n- previous PR changes","html_url":"https://github.com/octo/demo/pull/77"}]' \
    "$TOOL" --pr 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  assert_eq "$head_subject" 'feat(11222): add repository notes' 'git-commit should still create the planned commit before updating an existing pull request'
  remote_head_subject=$(git -C "$remote" log -1 --pretty=%s refs/heads/feat/11222)
  assert_eq "$remote_head_subject" 'feat(11222): add repository notes' 'git-commit should still push the created commit before updating an existing pull request'
  upstream_branch=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
  assert_eq "$upstream_branch" 'origin/feat/11222' 'git-commit should still set upstream before updating an existing pull request'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after updating an existing pull request'
  assert_contains "$(strip_ansi "$output")" 'Pull request updated: https://github.com/octo/demo/pull/77' 'git-commit should report the updated pull request URL instead of creating a new one'
  assert_contains "$(<"$ask_log")" 'Existing open pull request:' 'git-commit should tell the model when an open pull request already exists'
  assert_contains "$(<"$ask_log")" '## Existing Summary' 'git-commit should include the existing pull request body in the planning prompt before asking the model'
  assert_contains "$(<"$git_api_log")" 'repos/get octo demo' 'git-commit should still resolve the default branch before checking for an existing pull request'
  assert_contains "$(<"$git_api_log")" 'pulls/list octo demo' 'git-commit should query open pull requests for the branch'
  assert_contains "$(<"$git_api_log")" '--head octo:feat/11222' 'git-commit should look up existing pull requests by owner-qualified head branch'
  assert_contains "$(<"$git_api_log")" '--base main' 'git-commit should look up existing pull requests against the resolved base branch'
  assert_contains "$(<"$git_api_log")" 'pulls/update octo demo 77' 'git-commit should update the existing pull request when one already exists'
  assert_contains "$(<"$git_api_log")" 'title=feat(11222): add repository notes' 'git-commit should send the AI-generated title when updating an existing pull request'
  assert_contains "$(<"$git_api_log")" 'body=## Summary' 'git-commit should send the AI-generated body when updating an existing pull request'
  assert_not_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'git-commit should not create a new pull request when one already exists'
}

@test "updates an existing pull request when existing title and body are empty" {
  local stub_path jq_stub git_api_stub git_api_log remote repo ask_log output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api-args.log"
  ask_log="$TMP_HOME/model-profile-ask.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_PULLS_LIST_RESPONSE='[{"number":77,"title":"","body":"","html_url":"https://github.com/octo/demo/pull/77"}]' \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request updated: https://github.com/octo/demo/pull/77' 'git-commit should still update an existing PR when its title and body are empty'
  assert_contains "$(<"$ask_log")" $'Existing open pull request:\nYes' 'git-commit should still describe the empty-title PR as an existing pull request in the planning prompt'
  assert_contains "$(<"$git_api_log")" 'title=feat(11222): update readme' 'git-commit should fall back to a generated PR title when the existing PR title is empty'
  assert_contains "$(<"$git_api_log")" 'body=## Summary' 'git-commit should use the required AI-provided PR body when the existing PR body is empty'
}

@test "fails when pulls/update returns no html_url" {
  local stub_path jq_stub git_api_stub git_api_log remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_PULLS_LIST_RESPONSE='[{"number":77,"title":"feat(11222): prior","body":"prior body","html_url":"https://github.com/octo/demo/pull/77"}]' \
    GIT_API_PULLS_UPDATE_RESPONSE='{"html_url":""}' \
    "$TOOL" --pr 2>&1); then
    fail 'git-commit should fail when pulls/update omits html_url'
  fi

  assert_contains "$output" 'Error: git-api pulls/update response missing html_url' 'git-commit should reject malformed pulls/update responses without printing the body'
}

@test "uses the configured git-api profile for pull request operations" {
  local stub_path jq_stub git_api_stub git_profile_stub git_api_log remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  git_api_log="$TMP_HOME/git-api-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model '' '' work

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_PROFILE_BIN="$git_profile_stub" \
    GIT_PROFILE_TOKEN_ERROR='Error: no git profile is recorded in this repository' \
    GIT_API_ARGS_LOG="$git_api_log" \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should still create the pull request with a configured git-api profile'
  assert_contains "$(strip_ansi "$output")" 'Pull request auth: configured git-api profile.' 'git-commit should report configured git-api profile authentication'
  assert_contains "$(<"$git_api_log")" '--profile work repos/get octo demo' 'git-commit should pass the configured git-api profile when resolving the default branch'
  assert_contains "$(<"$git_api_log")" '--profile work pulls/create octo demo' 'git-commit should pass the configured git-api profile when creating the pull request'
}

@test "uses the repository git profile PAT for PR create calls and retrieves it once" {
  local stub_path jq_stub git_api_stub git_profile_stub git_api_log git_api_stdin_log git_profile_log remote repo output token

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  git_api_log="$TMP_HOME/git-api-args.log"
  git_api_stdin_log="$TMP_HOME/git-api-stdin.log"
  git_profile_log="$TMP_HOME/git-profile-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  token='repo-profile-token-sentinel'
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model '' '' work

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_STDIN_LOG="$git_api_stdin_log" \
    GIT_PROFILE_BIN="$git_profile_stub" \
    GIT_PROFILE_ARGS_LOG="$git_profile_log" \
    GIT_PROFILE_TOKEN_STDOUT="$token" \
    "$TOOL" --debug --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should create the pull request when a repository PAT is available'
  assert_contains "$(strip_ansi "$output")" 'Pull request auth: current git-profile PAT.' 'git-commit should report repository git-profile PAT authentication'
  assert_contains "$(<"$git_api_log")" '--token-stdin repos/get octo demo' 'git-commit should use stdin token auth when resolving the default branch'
  assert_contains "$(<"$git_api_log")" '--token-stdin pulls/list octo demo' 'git-commit should use stdin token auth when checking for an existing pull request'
  assert_contains "$(<"$git_api_log")" '--token-stdin pulls/create octo demo' 'git-commit should use stdin token auth when creating the pull request'
  assert_not_contains "$(<"$git_api_log")" '--profile work' 'git-commit should not pass the configured git-api profile when a repository PAT is available'
  assert_eq "$(<"$git_api_stdin_log")" "$token
$token
$token
$token" 'git-commit should pass the repository PAT over stdin to each PR-related git-api call'
  assert_contains "$(<"$git_profile_log")" $'ARGV_BEGIN\ntoken\nARGV_END' 'git-profile argv should be captured losslessly'
  assert_contains "$(<"$git_profile_log")" 'token' 'git-commit should resolve the repository PAT only once per PR run'
  assert_not_contains "$(<"$git_api_log")" "$token" 'git-api argv should not contain the repository PAT'
  assert_not_contains "$output" "$token" 'git-commit debug output should not contain the repository PAT'
}

@test "uses the repository git profile PAT for PR update calls" {
  local stub_path jq_stub git_api_stub git_profile_stub git_api_log git_api_stdin_log remote repo output token

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  git_api_log="$TMP_HOME/git-api-args.log"
  git_api_stdin_log="$TMP_HOME/git-api-stdin.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  token='repo-profile-token-sentinel'
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model '' '' work

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_STDIN_LOG="$git_api_stdin_log" \
    GIT_API_PULLS_LIST_RESPONSE='[{"number":77,"title":"feat(11222): prior","body":"prior body","html_url":"https://github.com/octo/demo/pull/77"}]' \
    GIT_PROFILE_BIN="$git_profile_stub" \
    GIT_PROFILE_TOKEN_STDOUT="$token" \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request updated: https://github.com/octo/demo/pull/77' 'git-commit should update an existing pull request when a repository PAT is available'
  assert_contains "$(<"$git_api_log")" '--token-stdin repos/get octo demo' 'git-commit should use stdin token auth when resolving the default branch for update flows'
  assert_contains "$(<"$git_api_log")" '--token-stdin pulls/list octo demo' 'git-commit should use stdin token auth when searching for an existing pull request'
  assert_contains "$(<"$git_api_log")" '--token-stdin pulls/update octo demo 77' 'git-commit should use stdin token auth when updating an existing pull request'
  assert_not_contains "$(<"$git_api_log")" '--profile work' 'git-commit should not pass the configured git-api profile when a repository PAT is available'
  assert_eq "$(<"$git_api_stdin_log")" "$token
$token
$token
$token" 'git-commit should pass the repository PAT over stdin to each PR-related git-api call'
}

@test "falls back to the configured git-api profile when the active repository profile has no PAT" {
  local stub_path jq_stub git_api_stub git_profile_stub git_api_log remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  git_api_log="$TMP_HOME/git-api-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model '' '' work

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_PROFILE_BIN="$git_profile_stub" \
    GIT_PROFILE_TOKEN_ERROR="Error: PAT not configured for profile 'work'" \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should still create the pull request when the repository profile has no PAT'
  assert_contains "$(<"$git_api_log")" '--profile work repos/get octo demo' 'git-commit should fall back to the configured git-api profile for default branch lookup'
  assert_contains "$(<"$git_api_log")" '--profile work pulls/create octo demo' 'git-commit should fall back to the configured git-api profile for pull request creation'
  assert_not_contains "$(<"$git_api_log")" '--token-stdin' 'git-commit should not use stdin token auth when the repository profile has no PAT'
}

@test "omits explicit git-api auth selectors when neither a repository PAT nor configured profile exists" {
  local stub_path jq_stub git_api_stub git_profile_stub git_api_log remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  git_api_log="$TMP_HOME/git-api-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_PROFILE_BIN="$git_profile_stub" \
    GIT_PROFILE_TOKEN_ERROR='Error: no git profile is recorded in this repository' \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should still create the pull request when no explicit auth selector is available'
  assert_contains "$(strip_ansi "$output")" 'Pull request auth: git-api fallback resolution.' 'git-commit should report fallback authentication resolution'
  assert_contains "$(<"$git_api_log")" 'repos/get octo demo' 'git-commit should still resolve the default branch through git-api'
  assert_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'git-commit should still create the pull request through git-api'
  assert_not_contains "$(<"$git_api_log")" '--profile' 'git-commit should not pass a configured git-api profile when none is configured'
  assert_not_contains "$(<"$git_api_log")" '--token-stdin' 'git-commit should not use stdin token auth when no repository PAT exists'
}

@test "uses the explicit base branch provided to --pr" {
  local stub_path jq_stub git_api_stub git_api_log remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    "$TOOL" --pr release-1.0 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should print the created pull request URL when an explicit base is provided'
  assert_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'git-commit should create the pull request through git-api when an explicit base is provided'
  assert_contains "$(<"$git_api_log")" 'base=release-1.0' 'git-commit should use the provided PR base branch'
}

@test "supports GitHub SSH remotes without a .git suffix in PR mode" {
  local stub_path jq_stub git_api_stub git_api_log remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin git@github.com:octo/demo
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should support GitHub SSH remotes without a .git suffix when creating a pull request'
  assert_contains "$(<"$git_api_log")" 'repos/get octo demo' 'git-commit should resolve the owner and repo correctly from an SSH remote without .git'
  assert_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'git-commit should create the pull request using the parsed owner and repo from an SSH remote without .git'
}

@test "fails in PR mode for unsupported non-GitHub remotes" {
  local stub_path jq_stub git_api_stub remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin git@gitlab.com:octo/demo
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    GIT_API_BIN="$git_api_stub" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    "$TOOL" --pr 2>&1); then
    fail 'git-commit should fail in PR mode for unsupported non-GitHub remotes'
  fi

  assert_contains "$output" 'Error: unsupported GitHub remote URL: git@gitlab.com:octo/demo' 'git-commit should reject unsupported PR remotes clearly'
}

@test "fails when the model returns invalid pull request fields" {
  local stub_path jq_stub git_api_stub remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":{},"body":[]}}' \
    GIT_API_BIN="$git_api_stub" \
    "$TOOL" --pr 2>&1); then
    fail 'git-commit should fail when the model returns invalid pull request fields'
  fi

  assert_contains "$output" 'Error: pull_request.title must be a nonempty string' 'git-commit should reject invalid pull request fields from the model'
}

@test "fails when --pr planning response omits pull request metadata" {
  local stub_path jq_stub git_api_stub remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}' \
    GIT_API_BIN="$git_api_stub" \
    "$TOOL" --pr 2>&1); then
    fail 'git-commit should fail when --pr planning omits pull request metadata'
  fi

  assert_contains "$output" 'Error: pull_request must be an object when --pr is used' 'git-commit should require PR metadata in --pr mode'
}

@test "falls back to git metadata when git-api cannot resolve the default branch" {
  local stub_path jq_stub git_api_stub git_api_log remote repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api-args.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat(11222): update readme","body":"## Summary\n- update readme"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_REPOS_GET_FAIL=true \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should still create a pull request when git-api default-branch lookup fails'
  assert_contains "$(<"$git_api_log")" 'repos/get octo demo' 'git-commit should try git-api before falling back to git metadata'
  assert_contains "$(<"$git_api_log")" 'base=main' 'git-commit should fall back to the git remote default branch'
}

@test "applies grouped commits with --apply" {
  local stub_path jq_stub repo output head_subject previous_subject status_after

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"fix","message":"update application logic","files":["src/app.txt"]},{"type":"test","message":"add coverage for application logic","files":["tests/app.txt"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  previous_subject=$(git -C "$repo" log -2 --pretty=%s | sed -n '2p')
  assert_eq "$head_subject" 'test(445566): add coverage for application logic' 'git-commit should create the last grouped commit in apply mode'
  assert_eq "$previous_subject" 'fix(445566): update application logic' 'git-commit should create grouped commits in order'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after grouped apply mode'
  assert_contains "$output" 'Commit 1:' 'git-commit should print the first grouped commit plan before applying it'
  assert_contains "$output" 'git add -A -- :\(top\,literal\)src/app.txt' 'git-commit should print the first grouped add command before applying it'
  assert_contains "$output" "$(preview_git_commit_command 'fix(445566): update application logic')" 'git-commit should print the first grouped commit command before applying it'
  assert_contains "$output" 'Commit 2:' 'git-commit should print the second grouped commit plan before applying it'
  assert_contains "$output" 'git add -A -- :\(top\,literal\)tests/app.txt' 'git-commit should print the second grouped add command before applying it'
  assert_contains "$output" "$(preview_git_commit_command 'test(445566): add coverage for application logic')" 'git-commit should print the second grouped commit command before applying it'
  assert_contains "$output" 'fix(445566): update application logic' 'git-commit should show the first created grouped commit'
  assert_contains "$output" 'test(445566): add coverage for application logic' 'git-commit should show the second created grouped commit'
}

@test "pushes commits for the selected directory scope without touching unrelated changes" {
  local stub_path jq_stub remote repo output head_subject remote_subject status_after

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  mkdir -p "$repo/docs" "$repo/src"
  printf 'guide\n' >"$repo/docs/guide.md"
  printf 'code change\n' >"$repo/src/app.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"docs","message":"add guide","files":["docs/guide.md"]}]}' \
    "$TOOL" --push --path docs 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  remote_subject=$(git --git-dir="$remote" log -1 --pretty=%s feat/11222)
  status_after=$(git -C "$repo" status --short)
  assert_eq "$head_subject" 'docs(11222): add guide' 'git-commit should create a commit only for the selected directory scope'
  assert_eq "$remote_subject" 'docs(11222): add guide' 'git-commit should push the selected-scope commit to the remote branch'
  assert_contains "$status_after" '?? src/' 'git-commit should leave unrelated changes untouched after --push with --path'
  assert_contains "$output" 'docs(11222): add guide' 'git-commit should preview and apply the selected-scope commit before pushing'
}

@test "keeps pull request planning scoped to the selected path set" {
  local stub_path jq_stub git_api_stub remote repo ask_log git_api_log output remote_head_subject status_after ask_payload

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  git_api_log="$TMP_HOME/git-api.log"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  mkdir -p "$repo/docs" "$repo/src"
  printf 'guide\n' >"$repo/docs/guide.md"
  printf 'code change\n' >"$repo/src/app.txt"

  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"docs","message":"add guide","files":["docs/guide.md"]}],"pull_request":{"title":"docs(11222): add guide","body":"## Summary\n- add guide"}}' \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    "$TOOL" --pr --path docs 2>&1)

  ask_payload=$(<"$ask_log")
  remote_head_subject=$(git -C "$remote" log -1 --pretty=%s refs/heads/feat/11222)
  status_after=$(git -C "$repo" status --short)
  assert_not_contains "$ask_payload" 'src/app.txt' 'git-commit should exclude unrelated changes from PR planning when --path is used'
  assert_contains "$ask_payload" 'docs/guide.md' 'git-commit should keep selected-scope files in PR planning when --path is used'
  assert_contains "$ask_payload" '"pull_request":{"title":"short pr title","body":"detailed markdown description"}' 'git-commit should still request PR details in scoped PR mode'
  assert_eq "$remote_head_subject" 'docs(11222): add guide' 'git-commit should push only the scoped commit before creating the pull request'
  assert_contains "$status_after" '?? src/' 'git-commit should leave unrelated changes untouched after scoped PR mode'
  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'git-commit should still create the pull request in scoped PR mode'
}

@test "applies grouped commits when the model returns exact paths for duplicate basenames" {
  local stub_path jq_stub repo output head_subject previous_subject status_after

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"docs","message":"update readme","files":["README.md"]},{"type":"feat","message":"add asdf upgrade tool","files":["tools/bin/asdf-upgrade"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  previous_subject=$(git -C "$repo" log -2 --pretty=%s | sed -n '2p')
  assert_eq "$head_subject" 'feat(11222): add asdf upgrade tool' 'git-commit should apply the exact changed path'
  assert_eq "$previous_subject" 'docs(11222): update readme' 'git-commit should preserve earlier grouped commits'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after applying exact-path commits'
  assert_contains "$output" 'feat(11222): add asdf upgrade tool' 'git-commit should show the exact-path commit title'
}

@test "applies grouped commits from a subdirectory using repo-root paths" {
  local stub_path jq_stub repo output head_subject previous_subject status_after

  stub_path="$TMP_HOME/model-profile-stub"
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
    MODEL_PROFILE_BIN="$stub_path" \
    MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"docs","message":"update readme","files":["README.md"]},{"type":"feat","message":"add asdf upgrade tool","files":["tools/bin/asdf-upgrade"]}]}' \
    "$TOOL" --apply 2>&1)

  head_subject=$(git -C "$repo" log -1 --pretty=%s)
  previous_subject=$(git -C "$repo" log -2 --pretty=%s | sed -n '2p')
  assert_eq "$head_subject" 'feat(11222): add asdf upgrade tool' 'git-commit should stage exact repo-root files correctly from a subdirectory'
  assert_eq "$previous_subject" 'docs(11222): update readme' 'git-commit should keep grouped commit order from a subdirectory'
  status_after=$(git -C "$repo" status --short)
  assert_eq "$status_after" '' 'git-commit should leave a clean worktree after subdirectory apply mode'
  assert_contains "$output" 'feat(11222): add asdf upgrade tool' 'git-commit should show the exact-path commit title from a subdirectory'
}

@test "accepts a commit plan wrapped in a json markdown fence" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  local fenced
  fenced=$'Looking at the changes:\n```json\n{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}\n```\nHope that helps.'

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_RESPONSE="$fenced" \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should accept a fenced commit plan response ($output)"
  fi

  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): update readme')" 'git-commit should print the planned commit parsed from inside the markdown fence'
}

@test "accepts a commit plan wrapped in a plain markdown fence" {
  local stub_path jq_stub repo output

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  local fenced
  fenced=$'Here you go:\n```\n{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}]}\n```'

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_RESPONSE="$fenced" \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should accept a plain-fenced commit plan response ($output)"
  fi

  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): update readme')" 'git-commit should print the planned commit parsed from inside the plain markdown fence'
}

@test "retries once when the first commit plan duplicates a file across commits" {
  local stub_path jq_stub repo output ask_log
  local sequence_file index_file

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  sequence_file="$TMP_HOME/ask.sequence"
  index_file="$TMP_HOME/ask.index"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  mkdir -p "$repo/src" "$repo/tests"
  printf 'code change\n' >"$repo/src/app.txt"
  printf 'test change\n' >"$repo/tests/app.txt"

  write_git_commit_config alpha-profile alpha-model

  printf '%s\n' \
    '{"commits":[{"type":"feat","message":"duplicate layout","files":["src/app.txt","tests/app.txt"]},{"type":"test","message":"coverage","files":["tests/app.txt"]}]}' \
    '{"commits":[{"type":"feat","message":"update app logic","files":["src/app.txt"]},{"type":"test","message":"add coverage for app logic","files":["tests/app.txt"]}]}' \
    >"$sequence_file"
  rm -f "$index_file"

  if ! output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE="$sequence_file" \
      MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE="$index_file" \
      "$TOOL" 2>&1
  ); then
    fail "git-commit should retry once after a duplicate-file commit plan and accept the corrected plan ($output)"
  fi

  assert_contains "$output" "$(preview_git_commit_command 'feat(11222): update app logic')" 'git-commit should print the first corrected grouped commit after retry'
  assert_contains "$output" "$(preview_git_commit_command 'test(11222): add coverage for app logic')" 'git-commit should print the second corrected grouped commit after retry'
  assert_contains "$(<"$ask_log")" 'Correction required:' 'git-commit should send correction guidance to the model on the retry request'
  assert_contains "$(<"$ask_log")" 'Remove duplicate file assignments.' 'git-commit should give duplicate-file-specific correction guidance on retry'
  assert_contains "$(<"$ask_log")" 'Re-check the changed-file list and your final response string before returning.' 'git-commit should tell the model to re-check both file coverage and the final response string on retry'
}

@test "surfaces duplicate-file validation errors without also reporting a JSON parse failure" {
  local stub_path jq_stub repo output ask_log
  local sequence_file index_file

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  sequence_file="$TMP_HOME/ask.sequence"
  index_file="$TMP_HOME/ask.index"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  mkdir -p "$repo/src" "$repo/tests"
  printf 'code change\n' >"$repo/src/app.txt"
  printf 'test change\n' >"$repo/tests/app.txt"

  write_git_commit_config alpha-profile alpha-model

  printf '%s\n' \
    '{"commits":[{"type":"feat","message":"duplicate layout","files":["src/app.txt","tests/app.txt"]},{"type":"test","message":"coverage","files":["tests/app.txt"]}]}' \
    '{"commits":[{"type":"feat","message":"duplicate layout","files":["src/app.txt","tests/app.txt"]},{"type":"test","message":"coverage","files":["tests/app.txt"]}]}' \
    >"$sequence_file"
  rm -f "$index_file"

  if output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE="$sequence_file" \
      MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE="$index_file" \
      "$TOOL" 2>&1
  ); then
    fail 'git-commit should fail when every retry keeps duplicating a file across commits'
  fi

  assert_contains "$output" 'Error: commit plan assigned the same file to multiple commits: tests/app.txt' 'git-commit should surface the duplicate-file validation error directly'
  assert_not_contains "$output" 'Raw model response:' 'git-commit should not print the raw model response for duplicate-file validation failures'
  assert_not_contains "$output" 'Error: model-profile ask did not return valid commit plan JSON' 'git-commit should not report a JSON parse failure when the model returned valid but invalid-plan JSON'
  assert_contains "$(<"$ask_log")" 'Remove duplicate file assignments.' 'git-commit should keep the duplicate-file-specific retry guidance in the retry prompt'
}

@test "surfaces the underlying validation error after exhausting the commit plan retry budget" {
  local stub_path jq_stub git_api_stub remote repo output ask_log
  local sequence_file index_file

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  git_api_stub="$TMP_HOME/git-api"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  sequence_file="$TMP_HOME/ask.sequence"
  index_file="$TMP_HOME/ask.index"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"
  create_git_api_stub "$git_api_stub"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  printf '%s\n' \
    '{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":{},"body":[]}}' \
    '{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":{},"body":[]}}' \
    >"$sequence_file"
  rm -f "$index_file"

  if output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE="$sequence_file" \
      MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE="$index_file" \
      GIT_API_BIN="$git_api_stub" \
      "$TOOL" --pr 2>&1
  ); then
    fail 'git-commit should fail when every commit plan attempt returns invalid pull request fields'
  fi

  assert_contains "$output" 'Error: pull_request.title must be a nonempty string' 'git-commit should surface the original validation error after exhausting commit plan retries'
  assert_not_contains "$output" 'Raw model response:' 'git-commit should not print the raw model response after exhausting commit plan retries on validation errors'
  assert_not_contains "$output" '"pull_request":{"title":{},"body":[]}' 'git-commit should not show the invalid raw response body for validation failures'
  assert_contains "$(<"$ask_log")" 'Correction required:' 'git-commit should retry the commit plan once before giving up on validation errors'
}

@test "fails when every commit plan attempt returns invalid JSON" {
  local stub_path jq_stub repo output ask_log
  local sequence_file index_file

  stub_path="$TMP_HOME/model-profile-stub"
  jq_stub="$TMP_HOME/jq"
  repo="$TMP_HOME/repo"
  ask_log="$TMP_HOME/model-profile-ask.log"
  sequence_file="$TMP_HOME/ask.sequence"
  index_file="$TMP_HOME/ask.index"
  create_model_provider_stub "$stub_path"
  create_jq_stub "$jq_stub"

  init_repo "$repo"
  create_initial_commit "$repo"
  git -C "$repo" checkout -q -b feat/11222
  printf 'updated\n' >>"$repo/README.md"

  write_git_commit_config alpha-profile alpha-model

  printf '%s\n' \
    'Sorry, I am not sure how to format the commit plan.' \
    'I really cannot do this.' \
    >"$sequence_file"
  rm -f "$index_file"

  if output=$(
    cd "$repo" || return 1
    PATH="$TMP_HOME:$PATH" \
      MODEL_PROFILE_BIN="$stub_path" \
      MODEL_PROFILE_ASK_ARGS_LOG="$ask_log" \
      MODEL_PROFILE_ASK_RESPONSE_SEQUENCE_FILE="$sequence_file" \
      MODEL_PROFILE_ASK_RESPONSE_INDEX_FILE="$index_file" \
      "$TOOL" 2>&1
  ); then
    fail 'git-commit should fail when every commit plan attempt returns invalid JSON'
  fi

  assert_contains "$output" 'Error: model-profile ask did not return valid commit plan JSON' 'git-commit should surface the parseable-JSON error after exhausting commit plan retries'
  assert_not_contains "$output" 'Raw model response:' 'git-commit should not print the raw model response after exhausting commit plan retries on invalid JSON'
  assert_not_contains "$output" 'I really cannot do this.' 'git-commit should not show the final raw non-JSON response on invalid JSON failures'
  assert_contains "$(<"$ask_log")" 'Return ONLY the JSON object with the exact shape requested' 'git-commit should ask the model for clean JSON after a parseable-JSON failure'
}
