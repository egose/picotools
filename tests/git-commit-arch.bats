#!/usr/bin/env bats

load 'helpers/git-commit'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-commit"
# shellcheck disable=SC2034
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  setup_git_commit_test_home
  mkdir -p "$TMP_HOME/bin"
  ensure_real_jq_on_path "$TMP_HOME/bin"
  export PATH="$TMP_HOME/bin:$PATH"
}

teardown() {
  teardown_git_commit_test_home
}

create_model_profile_stub() {
  local stub_path="$1"

  cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
ask)
  printf '%s\n' '{"commits":[{"type":"feat","message":"update file","files":["file.txt"]}]}'
  ;;
*)
  exit 1
  ;;
esac
EOF
  chmod +x "$stub_path"
}

@test "git-commit modules load idempotently and expose direct contracts" {
  run bash -c '. "$1"; . "$1"; declare -A options=(); paths=(); parse_run_options options paths --path one --path-file "$2" --pr main; printf "apply=%s push=%s pr=%s base=%s paths=%s,%s\n" "${options[apply_commits]}" "${options[push_commits]}" "${options[create_pr]}" "${options[pr_base_branch]}" "${paths[0]}" "${paths[1]}"' bash "$TOOL" "$BATS_TEST_TMPDIR/paths.txt"
  [ "$status" -ne 0 ]
  assert_contains "$output" 'Error: --path-file not found:' 'missing path-file should return to caller with a diagnostic'

  printf '%s\n' 'two' >"$BATS_TEST_TMPDIR/paths.txt"
  run bash -c '. "$1"; . "$1"; declare -A options=(); paths=(); parse_run_options options paths --path one --path-file "$2" --pr main; printf "apply=%s push=%s pr=%s base=%s paths=%s,%s\n" "${options[apply_commits]}" "${options[push_commits]}" "${options[create_pr]}" "${options[pr_base_branch]}" "${paths[0]}" "${paths[1]}"' bash "$TOOL" "$BATS_TEST_TMPDIR/paths.txt"
  [ "$status" -eq 0 ]
  assert_eq "$output" 'apply=true push=true pr=true base=main paths=one,two' 'option parser should populate caller-owned state exactly once'
}

@test "module error paths return instead of exiting the caller shell" {
  run bash -c '. "$1"; if resolve_scope_path "$PWD" "$PWD" /definitely/outside/repo; then :; else printf "after-return\n"; fi' bash "$TOOL"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'after-return' 'resolve_scope_path failure should be catchable by callers'

  run bash -c '. "$1"; request_commit_plan() { printf "not json\n"; }; changed_files=(a.txt); request_validated_commit_plan plan p m "" "" branch "" changed_files "diff" false || printf "after-return\n"' bash "$TOOL"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Error: model-profile ask did not return valid commit plan JSON' 'model validation failure should print stable diagnostic'
  assert_contains "$output" 'after-return' 'request_validated_commit_plan failure should be catchable by callers'
}

@test "pull request response validation is direct and non-secret" {
  run bash -c '. "$1"; validate_pull_request_response_url "{\"secret\":\"TOKEN_VALUE\"}" pulls/create out' bash "$TOOL"
  [ "$status" -ne 0 ]
  assert_contains "$output" 'Error: git-api pulls/create response missing html_url' 'PR response validation should report the failed API contract'
  assert_not_contains "$output" 'TOKEN_VALUE' 'PR validation should not print response bodies'
}

@test "repository and installed layouts load all modules for preview smoke" {
  local repo install_dir output

  repo="$BATS_TEST_TMPDIR/repo"
  init_repo_with_initial_commit "$repo"
  printf '%s\n' 'change' >"$repo/file.txt"
  write_git_commit_config alpha model
  create_model_profile_stub "$TMP_HOME/bin/model-profile"

  run bash -c 'cd "$1" && MODEL_PROFILE_BIN="$2" "$3" --no-scope' bash "$repo" "$TMP_HOME/bin/model-profile" "$TOOL"
  [ "$status" -eq 0 ] || fail "repository layout preview should succeed ($output)"
  assert_contains "$output" 'git commit -m' 'repository layout should render a preview commit command'

  install_dir="$BATS_TEST_TMPDIR/install"
  mkdir -p "$install_dir/bin" "$install_dir/lib/picotools"
  cp "$TOOL" "$install_dir/bin/git-commit"
  cp "$REPO_ROOT/lib/picotools"/*.sh "$install_dir/lib/picotools/"
  chmod +x "$install_dir/bin/git-commit"

  run bash -c 'cd "$1" && HOME="$2" XDG_CONFIG_HOME="$2/.config" MODEL_PROFILE_BIN="$3" "$4" --no-scope' bash "$repo" "$TMP_HOME/installed-home" "$TMP_HOME/bin/model-profile" "$install_dir/bin/git-commit"
  [ "$status" -ne 0 ]
  assert_contains "$output" 'Warning: git-commit is not configured. Run git-commit configure.' 'installed layout should load modules before reporting missing isolated config'

  mkdir -p "$TMP_HOME/installed-home/.config/git-commit"
  printf '[model]\n\tprofile = alpha\n\tname = model\n' >"$TMP_HOME/installed-home/.config/git-commit/config"
  run bash -c 'cd "$1" && HOME="$2" XDG_CONFIG_HOME="$2/.config" MODEL_PROFILE_BIN="$3" "$4" --no-scope' bash "$repo" "$TMP_HOME/installed-home" "$TMP_HOME/bin/model-profile" "$install_dir/bin/git-commit"
  [ "$status" -eq 0 ] || fail "installed layout preview should succeed ($output)"
  assert_contains "$output" 'git commit -m' 'installed layout should render a preview commit command'
}
