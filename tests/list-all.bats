#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/bin/list-all"
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export HOME="$TMP_DIR/home"
  export PATH="$TMP_DIR/bin:$PATH"
  export ASDF_PICOTOOLS_GITHUB_REPOSITORY='egose/picotools'

  mkdir -p "$HOME" "$TMP_DIR/bin" "$TMP_DIR/fixtures"
  ln -s "$REAL_JQ_BIN" "$TMP_DIR/bin/jq"

  cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=''
auth_header=''

while [ "$#" -gt 0 ]; do
  case "$1" in
  -H)
    if [[ "$2" == Authorization:* ]]; then
      auth_header="$2"
    fi
    shift 2
    ;;
  -f | -s | -S | -L | -fsSL)
    shift
    ;;
  *)
    url="$1"
    shift
    ;;
  esac
done

printf '%s\n' "$auth_header" >"${TMP_DIR}/curl-auth.log"
printf '%s\n' "$url" >>"${TMP_DIR}/curl-urls.log"

if [[ "$url" =~ page=([0-9]+)$ ]]; then
  page="${BASH_REMATCH[1]}"
else
  echo 'missing page parameter' >&2
  exit 1
fi

if [ "${LIST_ALL_FAIL_PAGE:-}" = "$page" ]; then
  echo 'simulated curl failure' >&2
  exit 22
fi

fixture="${TMP_DIR}/fixtures/page-${page}.json"
if [ -f "$fixture" ]; then
  cat "$fixture"
else
  printf '[]'
fi
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

write_page_fixture() {
  local page="$1"
  local content="$2"

  printf '%s\n' "$content" >"$TMP_DIR/fixtures/page-${page}.json"
}

write_repeated_tag_page_fixture() {
  local page="$1"
  local tag_name="$2"
  local count="$3"
  local json='['
  local i=1

  while [ "$i" -le "$count" ]; do
    if [ "$i" -gt 1 ]; then
      json+=','
    fi
    json+="{\"tag_name\":\"${tag_name}\"}"
    i=$((i + 1))
  done
  json+=']'

  printf '%s\n' "$json" >"$TMP_DIR/fixtures/page-${page}.json"
}

@test "lists versions across more than three GitHub release pages" {
  write_repeated_tag_page_fixture 1 'v1.0.0' 100
  write_repeated_tag_page_fixture 2 'v1.1.0' 100
  write_repeated_tag_page_fixture 3 'v1.2.0' 100
  write_page_fixture 4 '[{"tag_name":"v2.0.0"}]'
  write_page_fixture 5 '[]'

  run "$TOOL"

  [ "$status" -eq 0 ] || fail 'list-all should succeed for paginated responses'
  assert_contains "$(<"$TMP_DIR/curl-urls.log")" 'page=4' 'should keep requesting pages beyond the original three-page limit'
  assert_contains "$output" '2.0.0' 'should include tags discovered after the third page'
}

@test "forwards a supported GitHub token header" {
  write_page_fixture 1 '[]'

  run env GH_TOKEN='secret-token' "$TOOL"

  [ "$status" -eq 0 ] || fail 'list-all should succeed when using GH_TOKEN auth'
  assert_contains "$(<"$TMP_DIR/curl-auth.log")" 'Authorization: token secret-token' 'should forward the selected GitHub token as an Authorization header'
}

@test "fails cleanly when curl reports an API error" {
  run env LIST_ALL_FAIL_PAGE='1' "$TOOL"

  [ "$status" -ne 0 ] || fail 'list-all should fail when curl fails'
  assert_contains "$output" 'simulated curl failure' 'should surface curl failures'
}
