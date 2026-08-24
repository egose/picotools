#!/usr/bin/env bats

load 'helpers/git-commit'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-commit"
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

case "${1:-}" in
ask)
  message_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --message-file)
      message_file="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
    esac
  done
  if [ -n "${MODEL_PROFILE_MESSAGE_LOG:-}" ] && [ -n "$message_file" ]; then
    cp "$message_file" "$MODEL_PROFILE_MESSAGE_LOG"
  fi
  if [ -n "${MODEL_PROFILE_CREATE_DURING_ASK:-}" ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      printf '%s\n' 'created after planning' >"$file"
    done <<<"$MODEL_PROFILE_CREATE_DURING_ASK"
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

create_git_command_wrapper() {
  local wrapper_path="$1"

  cat >"$wrapper_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

logs_add=false
for arg in "$@"; do
  if [ "$arg" = 'add' ]; then
    logs_add=true
    break
  fi
done

if [ "$logs_add" = 'true' ] && [ -n "${GIT_ADD_ARGS_LOG:-}" ]; then
  printf '%s\n' 'BEGIN' >>"$GIT_ADD_ARGS_LOG"
  in_add=false
  for arg in "$@"; do
    if [ "$in_add" != 'true' ]; then
      [ "$arg" = 'add' ] || continue
      in_add=true
    fi
    printf '%q\n' "$arg" >>"$GIT_ADD_ARGS_LOG"
  done
  printf '%s\n' 'END' >>"$GIT_ADD_ARGS_LOG"
fi

exec "$REAL_GIT" "$@"
EOF
  chmod +x "$wrapper_path"
}

setup_path_repo() {
  local repo="$1"

  mkdir -p "$TMP_HOME/bin"
  REAL_GIT="$(command -v git)"
  MODEL_PROFILE_STUB="$TMP_HOME/model-profile"
  GIT_PROFILE_STUB="$TMP_HOME/git-profile"
  GIT_ADD_ARGS_LOG="$TMP_HOME/git-add-args.log"
  MODEL_PROFILE_MESSAGE_LOG="$TMP_HOME/model-message.log"
  export REAL_GIT MODEL_PROFILE_STUB GIT_PROFILE_STUB GIT_ADD_ARGS_LOG MODEL_PROFILE_MESSAGE_LOG

  create_model_provider_stub "$MODEL_PROFILE_STUB"
  create_git_profile_stub "$GIT_PROFILE_STUB"
  create_git_command_wrapper "$TMP_HOME/bin/git"
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
    GIT_PROFILE_BIN="$GIT_PROFILE_STUB" \
    GIT_ADD_ARGS_LOG="$GIT_ADD_ARGS_LOG" \
    "$TOOL" "$@"
}

commit_files() {
  local repo="$1"
  local revision="$2"

  git -C "$repo" diff-tree --no-commit-id --name-only -r "$revision"
}

commit_contains_file() {
  local repo="$1"
  local revision="$2"
  local expected_file="$3"
  local file
  local -a files=()

  mapfile -d '' -t files < <(git -C "$repo" diff-tree --no-commit-id -z --name-only -r "$revision")
  for file in "${files[@]}"; do
    if [ "$file" = "$expected_file" ]; then
      return 0
    fi
  done

  return 1
}

first_logged_git_add_command() {
  local line in_first=false

  while IFS= read -r line; do
    if [ "$line" = 'BEGIN' ]; then
      in_first=true
      continue
    fi
    if [ "$line" = 'END' ]; then
      return 0
    fi
    if [ "$in_first" = 'true' ]; then
      printf '%s\n' "$line"
    fi
  done <"$GIT_ADD_ARGS_LOG"
}

render_git_add_from_logged_argv() {
  local arg rendered='git'

  while IFS= read -r arg; do
    rendered="$rendered $arg"
  done < <(first_logged_git_add_command)

  printf '%s\n' "$rendered"
}

@test "literal wildcard path and matching post-plan file stay isolated" {
  local repo output first_commit_files second_commit_files post_plan_status

  repo="$TMP_HOME/repo"
  setup_path_repo "$repo"
  printf '%s\n' 'literal wildcard' >"$repo/a*.txt"
  printf '%s\n' 'plain abc' >"$repo/abc.txt"

  if ! output=$(MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add wildcard file","files":["a*.txt"]},{"type":"feat","message":"add abc file","files":["abc.txt"]}]}' \
    MODEL_PROFILE_CREATE_DURING_ASK='aZ.txt' \
    run_tool_in_repo "$repo" --apply --path 'a*.txt' --path abc.txt 2>&1); then
    fail "git-commit should apply literal wildcard commit plan ($output)"
  fi

  first_commit_files=$(commit_files "$repo" HEAD~1)
  second_commit_files=$(commit_files "$repo" HEAD)
  post_plan_status=$(git -C "$repo" status --short -- 'aZ.txt')

  [ "$first_commit_files" = 'a*.txt' ] || fail "first commit should contain only literal a*.txt ($first_commit_files)"
  [ "$second_commit_files" = 'abc.txt' ] || fail "second commit should contain only abc.txt ($second_commit_files)"
  [ "$post_plan_status" = '?? aZ.txt' ] || fail "post-plan glob match should remain untracked ($post_plan_status)"
}

@test "literal pathspecs cover question bracket colon space and shell metacharacters" {
  local repo output committed_files post_plan_status

  repo="$TMP_HOME/repo"
  setup_path_repo "$repo"
  printf '%s\n' 'question' >"$repo/q?.txt"
  printf '%s\n' 'bracket' >"$repo/br[ab].txt"
  printf '%s\n' 'colon' >"$repo/:leading.txt"
  printf '%s\n' 'space' >"$repo/space name.txt"
  printf '%s\n' 'shell' >"$repo/semi;dollar\$bang!.txt"

  # shellcheck disable=SC2016
  if ! output=$(MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add literal paths","files":["q?.txt","br[ab].txt",":leading.txt","space name.txt","semi;dollar$bang!.txt"]}]}' \
    MODEL_PROFILE_CREATE_DURING_ASK=$'qX.txt\nbra.txt' \
    run_tool_in_repo "$repo" --apply --path 'q?.txt' --path 'br[ab].txt' --path ':leading.txt' --path 'space name.txt' --path 'semi;dollar$bang!.txt' 2>&1); then
    fail "git-commit should apply metacharacter path plan ($output)"
  fi

  committed_files=$(commit_files "$repo" HEAD)
  assert_contains "$committed_files" 'q?.txt' 'question-mark filename should be committed literally'
  assert_contains "$committed_files" 'br[ab].txt' 'bracket filename should be committed literally'
  assert_contains "$committed_files" ':leading.txt' 'leading-colon filename should be committed literally'
  assert_contains "$committed_files" 'space name.txt' 'space filename should be committed literally'
  # shellcheck disable=SC2016
  assert_contains "$committed_files" 'semi;dollar$bang!.txt' 'shell metacharacter filename should be committed literally'
  post_plan_status=$(git -C "$repo" status --short -- 'qX.txt' 'bra.txt')
  assert_contains "$post_plan_status" '?? qX.txt' 'post-plan question-mark match should remain untracked'
  assert_contains "$post_plan_status" '?? bra.txt' 'post-plan bracket match should remain untracked'
}

@test "preview git add rendering matches apply argv literal pathspecs" {
  local repo output preview_command apply_command

  repo="$TMP_HOME/repo"
  setup_path_repo "$repo"
  printf '%s\n' 'literal wildcard' >"$repo/a*.txt"
  printf '%s\n' 'space' >"$repo/space name.txt"

  # shellcheck source=../tools/bin/git-commit disable=SC1091
  . "$TOOL"
  preview_command=$(print_git_add_command 'a*.txt' 'space name.txt')

  if ! output=$(MODEL_PROFILE_ASK_RESPONSE='{"commits":[{"type":"feat","message":"add literal preview","files":["a*.txt","space name.txt"]}]}' \
    run_tool_in_repo "$repo" --apply 2>&1); then
    fail "git-commit should apply preview comparison plan ($output)"
  fi

  apply_command=$(render_git_add_from_logged_argv)
  [ "$preview_command" = "$apply_command" ] || fail "preview should render the same argv used by apply (preview: $preview_command, apply: $apply_command)"
  assert_argv_record_contains_exact_arg "$GIT_ADD_ARGS_LOG" ':(top,literal)space name.txt'
  assert_argv_record_not_contains_exact_arg "$GIT_ADD_ARGS_LOG" ':(top,literal)space'
  assert_argv_record_not_contains_exact_arg "$GIT_ADD_ARGS_LOG" 'name.txt'
  assert_contains "$preview_command" 'top' 'preview should show top-anchored pathspec magic'
  assert_contains "$preview_command" 'literal' 'preview should show literal pathspec magic'
}

@test "apply and preview preserve unusual exact filenames" {
  local repo output response newline_file tab_file backslash_file quote_file colon_file space_file glob_file unicode_file file

  repo="$TMP_HOME/repo"
  setup_path_repo "$repo"
  mkdir -p "$repo/dir"
  newline_file=$'dir/new\nline.txt'
  tab_file=$'dir/tab\tname.txt'
  backslash_file=$'dir/back\\slash.txt'
  quote_file='dir/quote"name.txt'
  colon_file=':leading.txt'
  space_file='space name.txt'
  glob_file='glob[?]*.txt'
  unicode_file='cafe-é.txt'

  for file in "$newline_file" "$tab_file" "$backslash_file" "$quote_file" "$colon_file" "$space_file" "$glob_file" "$unicode_file"; do
    printf '%s\n' "content for $file" >"$repo/$file"
  done

  # shellcheck disable=SC2016
  response=$("$REAL_JQ_BIN" -n \
    --arg newline_file "$newline_file" \
    --arg tab_file "$tab_file" \
    --arg backslash_file "$backslash_file" \
    --arg quote_file "$quote_file" \
    --arg colon_file "$colon_file" \
    --arg space_file "$space_file" \
    --arg glob_file "$glob_file" \
    --arg unicode_file "$unicode_file" \
    '{commits:[{type:"feat",message:"add unusual paths",files:[$newline_file,$tab_file,$backslash_file,$quote_file,$colon_file,$space_file,$glob_file,$unicode_file]}]}')

  if ! output=$(MODEL_PROFILE_ASK_RESPONSE="$response" run_tool_in_repo "$repo" --apply 2>&1); then
    fail "git-commit should apply exact unusual path plan ($output)"
  fi

  assert_contains "$output" 'git add -A --' 'preview should render git add for unusual paths'
  for file in "$newline_file" "$tab_file" "$backslash_file" "$quote_file" "$colon_file" "$space_file" "$glob_file" "$unicode_file"; do
    commit_contains_file "$repo" HEAD "$file" || fail "commit should contain exact path: $file"
  done
}

@test "deleted and renamed files are represented in prompt and apply" {
  local repo output response prompt name_status

  repo="$TMP_HOME/repo"
  setup_path_repo "$repo"
  printf '%s\n' 'remove me' >"$repo/delete me.txt"
  printf '%s\n' 'rename me' >"$repo/old name.txt"
  git -C "$repo" add 'delete me.txt' 'old name.txt'
  git -C "$repo" commit -q -m 'chore: add tracked files'
  rm "$repo/delete me.txt"
  mv "$repo/old name.txt" "$repo/new name.txt"

  response=$("$REAL_JQ_BIN" -n '{commits:[{type:"feat",message:"update tracked paths",files:["delete me.txt","old name.txt","new name.txt"]}]}')
  if ! output=$(MODEL_PROFILE_ASK_RESPONSE="$response" run_tool_in_repo "$repo" --apply 2>&1); then
    fail "git-commit should apply deleted and renamed path plan ($output)"
  fi

  prompt=$(<"$MODEL_PROFILE_MESSAGE_LOG")
  assert_contains "$prompt" 'Changed files JSON array' 'prompt should identify the changed-file JSON array'
  assert_contains "$prompt" 'delete me.txt' 'prompt should include deleted file path'
  assert_contains "$prompt" 'old name.txt' 'prompt should include rename source path'
  assert_contains "$prompt" 'new name.txt' 'prompt should include rename destination path'
  name_status=$(git -C "$repo" diff-tree --no-commit-id --name-status -M -r HEAD)
  assert_contains "$name_status" $'D\tdelete me.txt' 'commit should include deleted file'
  assert_contains "$name_status" $'R100\told name.txt\tnew name.txt' 'commit should include renamed file'
}
