#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/gh-repo-sync"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export HOME="$TMP_DIR/home"
  export XDG_DATA_HOME="$TMP_DIR/data"
  export PATH="$TMP_DIR/bin:$PATH"

  mkdir -p "$HOME" "$XDG_DATA_HOME" "$TMP_DIR/bin"

  for command_name in curl jq unzip; do
    cat >"$TMP_DIR/bin/$command_name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
    chmod +x "$TMP_DIR/bin/$command_name"
  done
}

teardown() {
  rm -rf "$TMP_DIR"
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

assert_file_not_exists() {
  local path="$1"
  local message="$2"

  if [ -e "$path" ]; then
    fail "$message ($path)"
  fi
}

@test "shows help text" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'gh-repo-sync --help should succeed'
  assert_contains "$output" 'Usage: gh-repo-sync [--reset-pat]' 'help should describe the entrypoint'
  assert_contains "$output" '--reset-pat' 'help should document PAT reset support'
  assert_contains "$output" '--debug' 'help should document debug support'
}

@test "resets the stored PAT file" {
  local pat_file

  pat_file="$XDG_DATA_HOME/gh-repo-sync/pat"
  mkdir -p "$(dirname "$pat_file")"
  printf '%s\n' 'secret-token' >"$pat_file"

  run "$TOOL" --reset-pat

  [ "$status" -eq 0 ] || fail 'gh-repo-sync --reset-pat should succeed'
  assert_contains "$output" 'PAT has been reset.' 'should confirm the reset'
  assert_file_not_exists "$pat_file" 'should remove the stored PAT file'
}

@test "fails when the repository owner name is left blank" {
  run bash -c 'cd "$1" && printf "\n\n" | "$2"' _ "$TMP_DIR" "$TOOL"

  [ "$status" -eq 1 ] || fail 'gh-repo-sync should fail when no owner name is provided'
  assert_contains "$output" 'Continuing without authentication' 'should allow running without a PAT'
  assert_contains "$output" 'Error: name cannot be empty' 'should explain why execution stopped'
}
