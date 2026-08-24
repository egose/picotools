#!/usr/bin/env bats

load 'helpers/git-commit'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-commit"
# shellcheck disable=SC2034
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  setup_git_commit_test_home
  ensure_real_jq_on_path "$TMP_HOME"
  export PATH="$TMP_HOME:$PATH"
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

strip_ansi() {
  printf '%s' "$1" | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g'
}

git_commit_config_file() {
  printf '%s/config\n' "$GIT_COMMIT_CONFIG_DIR"
}

write_git_commit_config() {
  local profile="$1"
  local model="$2"
  local git_api_profile="${3:-}"
  local file

  mkdir -p "$GIT_COMMIT_CONFIG_DIR"
  file="$(git_commit_config_file)"
  printf '[model]\n\tprofile = %s\n\tname = %s\n' "$profile" "$model" >"$file"
  if [ -n "$git_api_profile" ]; then
    printf '[git-api]\n\tprofile = %s\n' "$git_api_profile" >>"$file"
  fi
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

if [ "${1:-}" = '--debug' ]; then
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
  if [ -n "${MODEL_PROFILE_ASK_LOG:-}" ]; then
    printf '%s\n' 'ARGV_BEGIN' >>"$MODEL_PROFILE_ASK_LOG"
    rendered=''
    for arg in "$@"; do
      printf '%q\n' "$arg" >>"$MODEL_PROFILE_ASK_LOG"
      printf -v rendered '%s%s%s' "$rendered" "${rendered:+ }" "$arg"
    done
    printf '%s\n%s\n' 'ARGV_END' "$rendered" >>"$MODEL_PROFILE_ASK_LOG"
  fi
  if [ -n "${MODEL_PROFILE_ASK_RESPONSE:-}" ]; then
    printf '%s\n' "$MODEL_PROFILE_ASK_RESPONSE"
  else
    printf '%s\n' '{"commits":[{"type":"feat","message":"update readme","files":["README.md"]}],"pull_request":{"title":"feat: update readme","body":"## Summary"}}'
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

case "${1:-}" in
token)
  printf '%s\n' "${GIT_PROFILE_TOKEN_STDOUT:-}"
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
  if [ -n "${GIT_API_REPOS_GET_RESPONSE:-}" ]; then
    printf '%s\n' "$GIT_API_REPOS_GET_RESPONSE"
  else
    printf '%s\n' '{"default_branch":"main"}'
  fi
  ;;
pulls/list)
  if [ "${GIT_API_PULLS_LIST_FAIL:-false}" = 'true' ]; then
    printf '%s\n' "${GIT_API_PULLS_LIST_ERROR:-Error: pulls/list failed}" >&2
    exit 7
  fi
  if [ -n "${GIT_API_PULLS_LIST_SEQUENCE_FILE:-}" ]; then
    index=1
    if [ -f "${GIT_API_PULLS_LIST_INDEX_FILE:-}" ]; then
      index=$(($(<"$GIT_API_PULLS_LIST_INDEX_FILE") + 1))
    fi
    printf '%s\n' "$index" >"$GIT_API_PULLS_LIST_INDEX_FILE"
    mapfile -t responses <"$GIT_API_PULLS_LIST_SEQUENCE_FILE"
    if [ "$index" -gt "${#responses[@]}" ]; then
      index=${#responses[@]}
    fi
    printf '%s\n' "${responses[$((index - 1))]}"
    exit 0
  fi
  printf '%s\n' "${GIT_API_PULLS_LIST_RESPONSE:-[]}"
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

prepare_pr_repo() {
  local remote="$1"
  local repo="$2"

  create_repo_with_remote "$remote" "$repo"
  git -C "$repo" remote set-url origin https://github.com/octo/demo.git
  git -C "$repo" remote set-url --push origin "$remote"
  git -C "$repo" checkout -q -b feat/pr-01
  printf '%s\n' 'updated' >>"$repo/README.md"
}

@test "failing pulls/list stops before model planning, commit, push, and create" {
  local model_stub git_api_stub git_profile_stub git_api_log model_log remote repo output head_before remote_status

  model_stub="$TMP_HOME/model-profile"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  git_api_log="$TMP_HOME/git-api.log"
  model_log="$TMP_HOME/model.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$model_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"
  prepare_pr_repo "$remote" "$repo"
  head_before=$(git -C "$repo" rev-parse HEAD)
  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$model_stub" \
    MODEL_PROFILE_ASK_LOG="$model_log" \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_PULLS_LIST_FAIL=true \
    GIT_PROFILE_BIN="$git_profile_stub" \
    "$TOOL" --pr 2>&1); then
    fail 'git-commit should fail when pulls/list fails'
  fi

  if git -C "$remote" show-ref --verify --quiet refs/heads/feat/pr-01; then
    remote_status='present'
  else
    remote_status='missing'
  fi
  assert_contains "$output" 'Error: git-api pulls/list failed while checking for an existing pull request' 'pulls/list failure should be explicit'
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" 'pulls/list failure should stop before creating commits'
  assert_eq "$remote_status" 'missing' 'pulls/list failure should stop before pushing'
  [ ! -f "$model_log" ] || fail 'pulls/list failure should stop before model planning'
  assert_not_contains "$(<"$git_api_log")" 'pulls/create' 'pulls/list failure should stop before creating a PR'
}

@test "empty lookup creates while existing lookup updates" {
  local model_stub git_api_stub git_profile_stub git_api_log remote repo output

  model_stub="$TMP_HOME/model-profile"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  git_api_log="$TMP_HOME/git-api.log"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$model_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"
  prepare_pr_repo "$remote" "$repo"
  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$model_stub" \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_PROFILE_BIN="$git_profile_stub" \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request: https://github.com/octo/demo/pull/42' 'empty successful lookup should create a PR'
  assert_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'empty lookup should call pulls/create'

  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b feat/pr-02
  printf '%s\n' 'second update' >>"$repo/README.md"
  : >"$git_api_log"

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$model_stub" \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_PULLS_LIST_RESPONSE='[{"number":77,"title":"feat: old","body":"old","html_url":"https://github.com/octo/demo/pull/77"}]' \
    GIT_PROFILE_BIN="$git_profile_stub" \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request updated: https://github.com/octo/demo/pull/77' 'valid existing lookup should update the PR'
  assert_contains "$(<"$git_api_log")" 'pulls/update octo demo 77' 'existing lookup should call pulls/update'
  assert_not_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'existing lookup should not create a new PR'
}

@test "divergent fetch and push URLs resolve base repo and qualified fork head" {
  local git_api_stub git_api_log repo output

  git_api_stub="$TMP_HOME/git-api"
  git_api_log="$TMP_HOME/git-api.log"
  repo="$TMP_HOME/repo"
  create_git_api_stub "$git_api_stub"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" remote add origin https://github.com/base-owner/base-repo.git
  git -C "$repo" remote set-url --push origin git@github.com:fork-owner/base-repo.git

  output=$(cd "$repo" && GIT_API_BIN="$git_api_stub" GIT_API_ARGS_LOG="$git_api_log" \
    bash -c '. "$1"; declare -A ctx=(); resolve_pull_request_context feat/pr main ctx; printf "base=%s/%s\nhead_owner=%s\nhead_ref=%s\n" "${ctx[owner]}" "${ctx[name]}" "${ctx[head_owner]}" "${ctx[head_ref]}"' bash "$TOOL")

  assert_contains "$output" 'base=base-owner/base-repo' 'fetch URL should define the base repository'
  assert_contains "$output" 'head_owner=fork-owner' 'push URL should define the head owner'
  assert_contains "$output" 'head_ref=fork-owner:feat/pr' 'fork heads should be owner-qualified'
  assert_contains "$(<"$git_api_log")" 'pulls/list base-owner base-repo --state open --head fork-owner:feat/pr --base main' 'lookup should target the base repo with the fork head'
}

@test "final refresh updates a concurrently-created pull request instead of creating" {
  local model_stub git_api_stub git_profile_stub git_api_log sequence_file sequence_index remote repo output

  model_stub="$TMP_HOME/model-profile"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  git_api_log="$TMP_HOME/git-api.log"
  sequence_file="$TMP_HOME/pulls-list-sequence.txt"
  sequence_index="$TMP_HOME/pulls-list-index.txt"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$model_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"
  prepare_pr_repo "$remote" "$repo"
  printf '%s\n' '[]' '[{"number":88,"title":"feat: concurrent","body":"created elsewhere","html_url":"https://github.com/octo/demo/pull/88"}]' >"$sequence_file"
  write_git_commit_config alpha-profile alpha-model

  output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$model_stub" \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_ARGS_LOG="$git_api_log" \
    GIT_API_PULLS_LIST_SEQUENCE_FILE="$sequence_file" \
    GIT_API_PULLS_LIST_INDEX_FILE="$sequence_index" \
    GIT_API_PULLS_UPDATE_RESPONSE='{"html_url":"https://github.com/octo/demo/pull/88"}' \
    GIT_PROFILE_BIN="$git_profile_stub" \
    "$TOOL" --pr 2>&1)

  assert_contains "$(strip_ansi "$output")" 'Pull request updated: https://github.com/octo/demo/pull/88' 'final refresh should deterministically update the concurrently-created PR'
  assert_contains "$(<"$git_api_log")" 'pulls/update octo demo 88' 'concurrent-create refresh should update the discovered PR number'
  assert_not_contains "$(<"$git_api_log")" 'pulls/create octo demo' 'concurrent-create refresh should not call pulls/create'
}

@test "malformed list and create responses fail with precise non-secret errors" {
  local model_stub git_api_stub git_profile_stub remote repo output

  model_stub="$TMP_HOME/model-profile"
  git_api_stub="$TMP_HOME/git-api"
  git_profile_stub="$TMP_HOME/git-profile"
  remote="$TMP_HOME/remote.git"
  repo="$TMP_HOME/repo"
  create_model_provider_stub "$model_stub"
  create_git_api_stub "$git_api_stub"
  create_git_profile_stub "$git_profile_stub"
  prepare_pr_repo "$remote" "$repo"
  write_git_commit_config alpha-profile alpha-model

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$model_stub" \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_PULLS_LIST_RESPONSE='[{"html_url":"https://github.com/octo/demo/pull/1","secret":"SENTINEL_SECRET"}]' \
    GIT_PROFILE_BIN="$git_profile_stub" \
    "$TOOL" --pr 2>&1); then
    fail 'git-commit should fail when pulls/list omits number'
  fi
  assert_contains "$output" 'Error: git-api pulls/list response item missing number' 'missing list fields should produce a precise error'
  assert_not_contains "$output" 'SENTINEL_SECRET' 'list response bodies should not be printed on shape errors'

  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b feat/pr-03
  printf '%s\n' 'third update' >>"$repo/README.md"

  if output=$(cd "$repo" && PATH="$TMP_HOME:$PATH" \
    MODEL_PROFILE_BIN="$model_stub" \
    GIT_API_BIN="$git_api_stub" \
    GIT_API_PULLS_CREATE_RESPONSE='{"message":"SENTINEL_SECRET"}' \
    GIT_PROFILE_BIN="$git_profile_stub" \
    "$TOOL" --pr 2>&1); then
    fail 'git-commit should fail when pulls/create omits html_url'
  fi
  assert_contains "$output" 'Error: git-api pulls/create response missing html_url' 'missing create fields should produce a precise error'
  assert_not_contains "$output" 'SENTINEL_SECRET' 'create response bodies should not be printed on shape errors'
}
