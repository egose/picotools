#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/asdf-install"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"
  export ASDF_LOG="$TMP_DIR/asdf.log"

  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/asdf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$ASDF_LOG"

if [ "$1" = 'plugin' ] && [ "$2" = 'add' ] && [ "$3" = 'python' ]; then
  exit 1
fi
EOF
  chmod +x "$TMP_DIR/bin/asdf"
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

@test "adds plugins installs versions and reshims" {
  local tool_versions_file log_contents

  tool_versions_file="$TMP_DIR/.tool-versions"
  printf '%s\n' \
    '# runtime tools' \
    'nodejs 20.11.1' \
    'python 3.11.9 # existing plugin add failure should be ignored' \
    >"$tool_versions_file"

  run "$TOOL" --debug "$tool_versions_file"

  [ "$status" -eq 0 ] || fail 'asdf-install should succeed for a valid tool-versions file'
  assert_contains "$output" "[asdf-install] Using tool versions file '$tool_versions_file'" 'should print the selected file in debug mode'
  assert_contains "$output" "[asdf-install] Ensuring asdf plugin 'nodejs' is installed" 'should log plugin discovery in debug mode'
  assert_contains "$output" 'Installing nodejs 20.11.1...' 'should print the nodejs install step'
  assert_contains "$output" 'Installing python 3.11.9...' 'should print the python install step'

  log_contents="$(<"$ASDF_LOG")"
  assert_contains "$log_contents" 'plugin add nodejs' 'should try to add the nodejs plugin'
  assert_contains "$log_contents" 'plugin add python' 'should try to add the python plugin even if it already exists'
  assert_contains "$log_contents" 'plugin update --all' 'should update all plugins before installing versions'
  assert_contains "$log_contents" 'install nodejs 20.11.1' 'should install the requested nodejs version'
  assert_contains "$log_contents" 'install python 3.11.9' 'should install the requested python version'
  assert_contains "$log_contents" 'reshim' 'should reshim after installations complete'
}

@test "fails when the tool-versions file does not exist" {
  run "$TOOL" "$TMP_DIR/missing.tool-versions"

  [ "$status" -eq 1 ] || fail 'asdf-install should fail when the input file is missing'
  assert_contains "$output" 'Error: file not found:' 'should explain that the input file does not exist'
}

@test "help documents debug mode" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'asdf-install --help should succeed'
  assert_contains "$output" '--debug' 'help should list debug mode'
}
