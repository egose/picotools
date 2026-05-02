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

  run "$TOOL" --yes --scope minor "$requirements_file"

  [ "$status" -eq 0 ] || fail 'pip-upgrade should succeed for a valid requirements file'
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
