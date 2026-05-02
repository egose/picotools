#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/asdf-clean-unused"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export WORKSPACE_DIR="$TMP_DIR/workspace"
  export PATH="$TMP_DIR/bin:$PATH"
  export ASDF_LOG="$TMP_DIR/asdf.log"

  mkdir -p "$TMP_DIR/bin" "$WORKSPACE_DIR/apps/api"

  cat >"$TMP_DIR/bin/asdf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$ASDF_LOG"

case "$1" in
plugin)
  case "$2" in
  list)
    printf '%s\n' nodejs python ruby
    ;;
  remove)
    ;;
  *)
    exit 1
    ;;
  esac
  ;;
list)
  case "$2" in
  nodejs)
    printf '%s\n' '  20.10.0' '* 20.11.1'
    ;;
  python)
    printf '%s\n' '  3.11.9'
    ;;
  ruby)
    printf '%s\n' '  3.3.0'
    ;;
  *)
    exit 1
    ;;
  esac
  ;;
uninstall|reshim)
  ;;
*)
  exit 1
  ;;
esac
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*)
    fail "$message (unexpected '$needle')"
    ;;
  *) ;;
  esac
}

@test "removes unused versions and plugins while honoring ignored paths" {
  local output log_contents

  printf '%s\n' 'nodejs 20.11.1' >"$WORKSPACE_DIR/.tool-versions"
  printf '%s\n' 'python 3.11.9' >"$WORKSPACE_DIR/apps/api/.tool-versions"

  output=$("$TOOL" --yes --ignore-path apps/api "$WORKSPACE_DIR")

  assert_contains "$output" 'Scanned .tool-versions files: 1' 'should only count non-ignored tool-versions files'
  assert_contains "$output" 'Unused asdf plugins:' 'should print the unused plugin section'
  assert_contains "$output" '  python' 'should treat ignored-path tools as unused'
  assert_contains "$output" '  ruby' 'should include fully unused plugins'
  assert_contains "$output" 'Unused asdf versions:' 'should print the unused versions section'
  assert_contains "$output" '  nodejs 20.10.0' 'should include unused installed versions for used tools'
  assert_not_contains "$output" 'apps/api/.tool-versions' 'should not list ignored tool-versions files in the scan summary'

  log_contents="$(<"$ASDF_LOG")"
  assert_contains "$log_contents" 'uninstall nodejs 20.10.0' 'should uninstall unused versions before removing plugins'
  assert_contains "$log_contents" 'plugin remove python' 'should remove the ignored-path plugin when it is otherwise unused'
  assert_contains "$log_contents" 'plugin remove ruby' 'should remove plugins not referenced by any scanned file'
  assert_contains "$log_contents" 'reshim' 'should reshim after removals complete'
}
