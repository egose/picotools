#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/asdf-upgrade"

setup() {
  TMP_HOME="$(mktemp -d)" || return 1
  export TMP_HOME
  export HOME="$TMP_HOME"
  export WORKSPACE_DIR="$TMP_HOME/workspace"
  export STUB_BIN="$TMP_HOME/bin"

  mkdir -p "$WORKSPACE_DIR" "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
}

teardown() {
  rm -rf "$TMP_HOME"
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

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

write_asdf_stub() {
  cat >"$STUB_BIN/asdf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
current)
  case "${ASDF_STUB_SCENARIO:-}" in
  upgrades)
    printf 'Name Version Source Installed\n'
    printf 'nodejs 20.10.0 %s/.tool-versions true\n' "$WORKSPACE_DIR"
    printf 'python 3.11.7 %s/apps/api/.tool-versions true\n' "$WORKSPACE_DIR"
    printf 'erlang 26.0.2 %s/.tool-versions false\n' "$WORKSPACE_DIR"
    printf 'poetry latest %s/.tool-versions true\n' "$WORKSPACE_DIR"
    ;;
  none)
    printf 'Name Version Source Installed\n'
    printf 'nodejs 20.11.1 %s/.tool-versions true\n' "$WORKSPACE_DIR"
    printf 'python latest %s/.tool-versions true\n' "$WORKSPACE_DIR"
    printf 'erlang 26.0.2 %s/.tool-versions false\n' "$WORKSPACE_DIR"
    ;;
  *)
    exit 1
    ;;
  esac
  ;;
list)
  if [ "$2" != 'all' ]; then
    exit 1
  fi

  case "$3" in
  nodejs)
    printf '%s\n' 18.19.1 20.10.0 20.11.1 21.0.0-rc1 latest
    ;;
  python)
    printf '%s\n' 3.11.7 3.11.9 3.12.0b1 ref:system
    ;;
  *)
    exit 1
    ;;
  esac
  ;;
*)
  exit 1
  ;;
esac
EOF

  chmod +x "$STUB_BIN/asdf"
}

@test "updates multiple selected tools across source files" {
  local root_versions_file nested_versions_file

  write_asdf_stub
  mkdir -p "$WORKSPACE_DIR/apps/api"

  root_versions_file="$WORKSPACE_DIR/.tool-versions"
  nested_versions_file="$WORKSPACE_DIR/apps/api/.tool-versions"

  printf '%s\n' 'nodejs 20.10.0' 'poetry latest' >"$root_versions_file"
  printf '%s\n' 'python 3.11.7 # app runtime' >"$nested_versions_file"

  ASDF_STUB_SCENARIO=upgrades run bash -c 'cd "$1" && printf "1 2\n" | bash "$2"' _ "$WORKSPACE_DIR" "$TOOL"

  [ "$status" -eq 0 ] || fail 'asdf-upgrade should succeed when selections are provided'
  assert_contains "$output" 'Checking nodejs 20.10.0' 'should print progress before fetching nodejs versions'
  assert_contains "$output" 'Checking python 3.11.7' 'should print progress before fetching python versions'
  assert_contains "$output" 'Checked 2 tool(s).' 'should print a final progress summary'
  assert_contains "$output" '| Tool' 'should print the upgrade table'
  assert_contains "$output" 'nodejs' 'should list the nodejs upgrade'
  assert_contains "$output" 'python' 'should list the python upgrade'
  assert_contains "$output" 'Select tools to upgrade:' 'should prompt for multi-selection in non-interactive mode'
  assert_contains "$output" 'Updated 2 tool(s) across 2 source file(s).' 'should confirm both files were updated'

  assert_eq "$(<"$root_versions_file")" $'nodejs 20.11.1\npoetry latest' 'should update the selected root tool version only'
  assert_eq "$(<"$nested_versions_file")" 'python 3.11.9 # app runtime' 'should update the selected nested tool version and preserve the comment'
}

@test "prints no upgrades when only unsupported or current versions are present" {
  write_asdf_stub
  printf '%s\n' 'nodejs 20.11.1' 'python latest' >"$WORKSPACE_DIR/.tool-versions"

  ASDF_STUB_SCENARIO=none run bash -c 'cd "$1" && bash "$2"' _ "$WORKSPACE_DIR" "$TOOL"

  [ "$status" -eq 0 ] || fail 'asdf-upgrade should succeed when nothing is upgradeable'
  assert_contains "$output" 'Checking nodejs 20.11.1' 'should print progress for eligible tools even when no upgrade exists'
  assert_contains "$output" 'Checked 1 tool(s).' 'should print the count of checked tools when no upgrades exist'
  assert_contains "$output" 'No upgrades found.' 'should report when no strict-semver upgrades are available'
}
