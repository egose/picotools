#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/pip-upgrade"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"

  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${@: -1}"

case "$url" in
  'https://pypi.org/pypi/requests/json')
    cat <<'JSON'
{"releases":{"2.31.0":[{"yanked":false}],"2.31.5":[{"yanked":false}],"2.32.0":[{"yanked":false}],"3.0.0b1":[{"yanked":false}]}}
JSON
    ;;
  'https://pypi.org/pypi/urllib3/json')
    cat <<'JSON'
{"releases":{"1.26.18":[{"yanked":false}],"1.26.20":[{"yanked":false}],"2.0.0":[{"yanked":false}]}}
JSON
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$TMP_DIR/bin/curl"
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

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

@test "updates exact requirement pins within the requested scope" {
  local requirements_file

  requirements_file="$TMP_DIR/requirements.txt"
  printf '%s\n' \
    '# app requirements' \
    'requests==2.31.0' \
    'urllib3===1.26.18 ; python_version >= "3.9"' \
    'editable @ git+https://example.com/repo.git' \
    >"$requirements_file"

  run "$TOOL" --debug --yes --scope minor "$requirements_file"

  [ "$status" -eq 0 ] || fail 'pip-upgrade should succeed for a valid requirements file'
  assert_contains "$output" '[pip-upgrade] Fetching PyPI metadata for' 'should log package lookups in debug mode'
  assert_contains "$output" 'requirements.txt updated.' 'should report that the requirements file changed'
  assert_eq "$(<"$requirements_file")" $'# app requirements\nrequests==2.32.0\nurllib3===1.26.20 ; python_version >= "3.9"\neditable @ git+https://example.com/repo.git' 'should update only eligible exact pins and preserve other lines'
}

@test "fails fast for an invalid scope" {
  local requirements_file

  requirements_file="$TMP_DIR/requirements.txt"
  printf '%s\n' 'requests==2.31.0' >"$requirements_file"

  run "$TOOL" --scope invalid "$requirements_file"

  [ "$status" -eq 1 ] || fail 'pip-upgrade should fail for an unsupported scope'
  assert_contains "$output" "Error: invalid scope 'invalid'" 'should explain the invalid scope value'
}

@test "fails when curl is unavailable" {
  local requirements_file isolated_bin

  requirements_file="$TMP_DIR/requirements.txt"
  printf '%s\n' 'requests==2.31.0' >"$requirements_file"
  isolated_bin="$TMP_DIR/no-curl-bin"
  mkdir -p "$isolated_bin"
  ln -s "$(command -v bash)" "$isolated_bin/bash"
  ln -s "$(command -v dirname)" "$isolated_bin/dirname"
  ln -s "$(command -v python3)" "$isolated_bin/python3"

  run env PATH="$isolated_bin" bash "$TOOL" --yes "$requirements_file"

  [ "$status" -eq 1 ] || fail 'pip-upgrade should fail when curl is unavailable'
  assert_contains "$output" 'Error: missing required tools: curl' 'should explain that curl is required'
}

@test "continues when PyPI metadata is missing" {
  local requirements_file

  requirements_file="$TMP_DIR/requirements.txt"
  printf '%s\n' 'missing-package==1.0.0' >"$requirements_file"

  run "$TOOL" --debug --yes "$requirements_file"

  [ "$status" -eq 0 ] || fail 'pip-upgrade should skip packages without PyPI metadata'
  assert_contains "$output" "No PyPI metadata found for 'missing-package'" 'should log missing metadata in debug mode'
  assert_contains "$output" 'No updates found.' 'should report that no updates were produced'
}

@test "help documents debug mode" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'pip-upgrade --help should succeed'
  assert_contains "$output" '--debug' 'help should list debug mode'
}
