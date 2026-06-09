#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/gh-actions-upgrade"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"
  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

header=''
if [ "${1:-}" = '-c' ]; then
  header="${2:-}"
  shift 2
fi

if [ "${1:-}" != 'ls-remote' ] || [ "${2:-}" != '--tags' ]; then
  echo "unexpected git invocation: $*" >&2
  exit 1
fi

if [ -n "${GIT_LS_REMOTE_LOG:-}" ]; then
  if [ -n "$header" ]; then
    printf '%s\n' "-c $header $*" >>"$GIT_LS_REMOTE_LOG"
  else
    printf '%s\n' "$*" >>"$GIT_LS_REMOTE_LOG"
  fi
fi

case "${3:-}" in
https://github.com/actions/checkout.git)
  cat <<'OUT'
1111111111111111111111111111111111111111	refs/tags/v4.1.0
6666666666666666666666666666666666666666	refs/tags/v6.0.2
7777777777777777777777777777777777777777	refs/tags/v6.0.3-rc1
OUT
  ;;
https://github.com/actions/upload-artifact.git)
  cat <<'OUT'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	refs/tags/v4.0.0
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	refs/tags/v4.6.2
OUT
  ;;
https://github.com/softprops/action-gh-release.git)
  cat <<'OUT'
1234512345123451234512345123451234512345	refs/tags/v2.0.0
9999999999999999999999999999999999999999	refs/tags/v2.2.3
OUT
  ;;
https://github.com/octo/private-action.git)
  if [ "$header" != 'http.extraHeader=Authorization: Bearer secret-token' ]; then
    echo 'missing auth header for private action lookup' >&2
    exit 1
  fi
  cat <<'OUT'
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee	refs/tags/v1.0.0
ffffffffffffffffffffffffffffffffffffffff	refs/tags/v1.2.0
OUT
  ;;
*)
  echo "unexpected remote: ${3:-}" >&2
  exit 1
  ;;
esac
EOF
  chmod +x "$TMP_DIR/bin/git"
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

@test "preserves each action ref type by default" {
  local workflow_file nested_action_file output log_file

  mkdir -p "$TMP_DIR/work/.github/workflows" "$TMP_DIR/work/.github/actions/release"
  workflow_file="$TMP_DIR/work/.github/workflows/test.yml"
  nested_action_file="$TMP_DIR/work/.github/actions/release/action.yml"
  log_file="$TMP_DIR/git-ls-remote.log"

  cat >"$workflow_file" <<'EOF'
name: Test
jobs:
  test:
    steps:
    - uses: actions/checkout@v4.1.0
    - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    - uses: ./.github/actions/local-setup
EOF

  cat >"$nested_action_file" <<'EOF'
runs:
  using: composite
  steps:
  - uses: softprops/action-gh-release@1234512345123451234512345123451234512345
EOF

  run env GIT_LS_REMOTE_LOG="$log_file" "$TOOL" --debug "$TMP_DIR/work/.github"

  [ "$status" -eq 0 ] || fail 'gh-actions-upgrade should succeed for default ref preservation'
  assert_contains "$output" '[gh-actions-upgrade] Updated' 'debug mode should log updated action refs'
  assert_contains "$output" 'Updated 3 action reference(s) across 2 file(s).' 'tool should report the number of updated refs and files'
  assert_eq "$(<"$workflow_file")" $'name: Test\njobs:\n  test:\n    steps:\n    - uses: actions/checkout@v6.0.2\n    - uses: actions/upload-artifact@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n    - uses: ./.github/actions/local-setup' 'default mode should keep tag refs as tags and hash refs as hashes'
  assert_eq "$(<"$nested_action_file")" $'runs:\n  using: composite\n  steps:\n  - uses: softprops/action-gh-release@9999999999999999999999999999999999999999' 'default mode should also update nested action files under .github'
  assert_contains "$(<"$log_file")" 'ls-remote --tags https://github.com/actions/checkout.git' 'tool should query action tags from git ls-remote'
}

@test "prefers the latest stable tag over prerelease tags" {
  local workflow_file

  mkdir -p "$TMP_DIR/work/.github/workflows"
  workflow_file="$TMP_DIR/work/.github/workflows/test.yml"

  cat >"$workflow_file" <<'EOF'
jobs:
  test:
    steps:
    - uses: actions/checkout@v4.1.0
EOF

  run "$TOOL" "$TMP_DIR/work/.github"

  [ "$status" -eq 0 ] || fail 'gh-actions-upgrade should succeed when prerelease tags exist'
  assert_eq "$(<"$workflow_file")" $'jobs:\n  test:\n    steps:\n    - uses: actions/checkout@v6.0.2' 'default mode should prefer the latest stable tag over a newer prerelease tag'
}

@test "can force all action refs to tags" {
  local workflow_file

  mkdir -p "$TMP_DIR/work/.github/workflows"
  workflow_file="$TMP_DIR/work/.github/workflows/test.yml"

  cat >"$workflow_file" <<'EOF'
jobs:
  test:
    steps:
    - uses: actions/checkout@1111111111111111111111111111111111111111
    - uses: actions/upload-artifact@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF

  run "$TOOL" --ref-type tag "$TMP_DIR/work/.github"

  [ "$status" -eq 0 ] || fail 'gh-actions-upgrade should succeed when forcing tag refs'
  assert_contains "$output" 'Updated 2 action reference(s) across 1 file(s).' 'tool should report forced tag updates'
  assert_eq "$(<"$workflow_file")" $'jobs:\n  test:\n    steps:\n    - uses: actions/checkout@v6.0.2\n    - uses: actions/upload-artifact@v4.6.2' 'forced tag mode should rewrite all refs to latest tags'
}

@test "can force all action refs to commit hashes" {
  local workflow_file

  mkdir -p "$TMP_DIR/work/.github/workflows"
  workflow_file="$TMP_DIR/work/.github/workflows/test.yml"

  cat >"$workflow_file" <<'EOF'
jobs:
  test:
    steps:
    - uses: actions/checkout@v4.1.0
    - uses: actions/upload-artifact@v4.0.0
EOF

  run "$TOOL" --ref-type hash "$TMP_DIR/work/.github"

  [ "$status" -eq 0 ] || fail 'gh-actions-upgrade should succeed when forcing commit-hash refs'
  assert_contains "$output" 'Updated 2 action reference(s) across 1 file(s).' 'tool should report forced hash updates'
  assert_eq "$(<"$workflow_file")" $'jobs:\n  test:\n    steps:\n    - uses: actions/checkout@6666666666666666666666666666666666666666\n    - uses: actions/upload-artifact@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'forced hash mode should rewrite all refs to latest tag commit hashes'
}

@test "uses an auth header for private action repositories when a token is configured" {
  local workflow_file log_file

  mkdir -p "$TMP_DIR/work/.github/workflows"
  workflow_file="$TMP_DIR/work/.github/workflows/test.yml"
  log_file="$TMP_DIR/git-ls-remote.log"

  cat >"$workflow_file" <<'EOF'
jobs:
  test:
    steps:
    - uses: octo/private-action@v1.0.0
EOF

  run env GH_TOKEN='secret-token' GIT_LS_REMOTE_LOG="$log_file" "$TOOL" "$TMP_DIR/work/.github"

  [ "$status" -eq 0 ] || fail 'gh-actions-upgrade should support authenticated private action lookups'
  assert_eq "$(<"$workflow_file")" $'jobs:\n  test:\n    steps:\n    - uses: octo/private-action@v1.2.0' 'tool should update private action refs when a GitHub token is available'
  assert_contains "$(<"$log_file")" '-c http.extraHeader=Authorization: Bearer secret-token ls-remote --tags https://github.com/octo/private-action.git' 'tool should pass the GitHub token as a git auth header for private action lookups'
}

@test "help documents the ref type override" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'gh-actions-upgrade --help should succeed'
  assert_contains "$output" '--ref-type TYPE' 'help should document the ref type override option'
}
