#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/gh-release-assets"

setup() {
  : "${HOME_ORIG:=$HOME}"
  export HOME_ORIG

  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export HOME="$TMP_DIR/home"
  export XDG_DATA_HOME="$TMP_DIR/data"
  export PATH="$TMP_DIR/bin:$PATH"

  mkdir -p "$HOME" "$XDG_DATA_HOME" "$TMP_DIR/bin"

  export GIT_API_BIN="$TMP_DIR/bin/git-api"

  local real_jq=''
  local candidate version installed_root
  for candidate in /usr/bin/jq /usr/local/bin/jq /opt/homebrew/bin/jq; do
    if [ -x "$candidate" ]; then
      real_jq="$candidate"
      break
    fi
  done
  if [ -z "$real_jq" ]; then
    for installed_root in \
      "${ASDF_DATA_HOME:-$HOME_ORIG/.asdf}"/installs/jq \
      "${ASDF_DIR:-$HOME_ORIG/.asdf}"/installs/jq \
      "$HOME_ORIG/.asdf"/installs/jq; do
      [ -d "$installed_root" ] || continue
      for version in $(find "$installed_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort -Vr); do
        candidate="$installed_root/$version/bin/jq"
        if [ -x "$candidate" ]; then
          real_jq="$candidate"
          break 2
        fi
      done
    done
  fi
  if [ -z "$real_jq" ]; then
    echo 'Error: jq binary not found for tests' >&2
    exit 1
  fi
  cat >"$TMP_DIR/bin/jq" <<EOF
#!/usr/bin/env bash
exec $real_jq "\$@"
EOF
  chmod +x "$TMP_DIR/bin/jq"

  cat >"$TMP_DIR/bin/git-api" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

debug='false'
if [ "${1:-}" = '--debug' ]; then
  debug='true'
  shift
fi

printf '%s|%s\n' "$debug" "$*" >>"$TMP_DIR/git-api.log"

owner=''
repo=''
per_page=''
page=''
operation="${1:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
  --per-page)
    per_page="$2"
    shift 2
    ;;
  --page)
    page="$2"
    shift 2
    ;;
  repos/list-releases)
    operation='repos/list-releases'
    owner="$2"
    repo="$3"
    shift 3
    ;;
  *)
    shift
    ;;
  esac
done

if [ "$operation" != 'repos/list-releases' ]; then
  echo "unexpected git-api invocation: $*" >&2
  exit 1
fi

if [ "$owner/$repo" != 'octo/demo' ]; then
  printf '[]\n'
  exit 0
fi

case "${page:-1}" in
1)
  if [ "${FAIL_PAGE_1:-0}" = '1' ]; then
    printf '[]\n'
    exit 0
  fi
  if [ -n "${PAGE_1_JSON:-}" ]; then
    printf '%s\n' "$PAGE_1_JSON"
  else
    printf '%s\n' '[{"name":"v1.1.0","published_at":"2026-07-10T03:44:44Z","assets":[{"name":"demo-1.1.0.tar.gz"}]},{"name":"v1.0.0","published_at":"2026-06-01T10:00:00Z","assets":[{"name":"demo-1.0.0.tar.gz"},{"name":"demo-1.0.0.sha256"}]},{"name":"v0.9.0","published_at":"2026-05-01T08:00:00Z","assets":[]}]'
  fi
  ;;
2)
  if [ -n "${PAGE_2_JSON:-}" ]; then
    printf '%s\n' "$PAGE_2_JSON"
  else
    printf '[]\n'
  fi
  ;;
*)
  printf '[]\n'
  ;;
esac
EOF
  chmod +x "$TMP_DIR/bin/git-api"
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

@test "shows help text" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'gh-release-assets --help should succeed'
  assert_contains "$output" 'Usage: gh-release-assets [options] [owner repo]' 'help should describe the entrypoint'
  assert_contains "$output" '--max-releases N' 'help should document --max-releases'
  assert_contains "$output" '--output PATH' 'help should document --output'
  assert_contains "$output" '--debug' 'help should document --debug'
}

@test "shows version" {
  run "$TOOL" --version

  [ "$status" -eq 0 ] || fail 'gh-release-assets --version should succeed'
  [ -n "$output" ] || fail 'version output should not be empty'
}

@test "writes releases json with name, published_at, and asset names" {
  cd "$TMP_DIR"
  run "$TOOL" octo demo

  [ "$status" -eq 0 ] || fail "tool should succeed (got $status): $output"
  [ -f "$TMP_DIR/octo-demo-releases.json" ] || fail 'expected releases json file'

  run jq -c 'length' "$TMP_DIR/octo-demo-releases.json"
  [ "$status" -eq 0 ] || fail "jq length should succeed: $output"
  [ "$output" = '3' ] || fail "expected 3 releases, got $output"

  run jq -c '.[0]' "$TMP_DIR/octo-demo-releases.json"
  [ "$status" -eq 0 ] || fail "jq .[0] should succeed: $output"
  assert_contains "$output" '"name":"v1.1.0"' 'first release name should be v1.1.0'
  assert_contains "$output" '"published_at":"2026-07-10T03:44:44Z"' 'first release should carry published_at'
  assert_contains "$output" '"assets":["demo-1.1.0.tar.gz"]' 'first release should expose asset names as strings'

  run jq -c '.[1].assets' "$TMP_DIR/octo-demo-releases.json"
  [ "$status" -eq 0 ] || fail "jq assets should succeed: $output"
  [ "$output" = '["demo-1.0.0.tar.gz","demo-1.0.0.sha256"]' ] || fail "expected two asset names, got $output"

  run jq -c '.[2].assets' "$TMP_DIR/octo-demo-releases.json"
  [ "$status" -eq 0 ] || fail "jq empty assets should succeed: $output"
  [ "$output" = '[]' ] || fail "expected empty assets array, got $output"
}

@test "respects --max-releases" {
  cd "$TMP_DIR"
  run "$TOOL" --max-releases 1 octo demo

  [ "$status" -eq 0 ] || fail "tool should succeed (got $status): $output"
  [ -f "$TMP_DIR/octo-demo-releases.json" ] || fail 'expected releases json file'

  run jq -c 'length' "$TMP_DIR/octo-demo-releases.json"
  [ "$status" -eq 0 ] || fail "jq length should succeed: $output"
  [ "$output" = '1' ] || fail "expected 1 release with --max-releases 1, got $output"
}

@test "honors --output path" {
  cd "$TMP_DIR"
  run "$TOOL" --output "$TMP_DIR/custom.json" --max-releases 1 octo demo

  [ "$status" -eq 0 ] || fail "tool should succeed (got $status): $output"
  [ -f "$TMP_DIR/custom.json" ] || fail 'expected json at custom --output path'
  [ ! -f "$TMP_DIR/octo-demo-releases.json" ] || fail 'should not write default file when --output is set'
}

@test "paginates until the final short page" {
  cd "$TMP_DIR"
  # page-size is 100 internally; emit 100 items on page 1 plus 1 on page 2 to
  # force two API calls and confirm the loop stops after the short page.
  PAGE_1_JSON="$(for n in {1..100}; do printf '{"name":"v%s","published_at":"x","assets":[{"name":"a%s.tgz"}]}' "$n" "$n"; done | jq -s -c '.')" \
  PAGE_2_JSON='[{"name":"v0","published_at":"y","assets":[]}]' \
    run "$TOOL" --max-releases 101 octo demo

  [ "$status" -eq 0 ] || fail "tool should succeed (got $status): $output"

  run jq -c 'length' "$TMP_DIR/octo-demo-releases.json"
  [ "$status" -eq 0 ] || fail "jq length should succeed: $output"
  [ "$output" = '101' ] || fail "expected 101 releases after paging, got $output"

  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|repos/list-releases octo demo --per-page 100 --page 1' 'should request page 1'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|repos/list-releases octo demo --per-page 100 --page 2' 'should request page 2'
  [ "$(grep -c -- '--page 3' "$TMP_DIR/git-api.log")" -eq 0 ] || fail 'should stop paging after the final short page'
}

@test "stops paging when the page is empty" {
  cd "$TMP_DIR"
  FAIL_PAGE_1=1 run "$TOOL" --max-releases 100 octo demo

  [ "$status" -eq 0 ] || fail "tool should succeed (got $status): $output"

  run jq -c 'length' "$TMP_DIR/octo-demo-releases.json"
  [ "$status" -eq 0 ] || fail "jq length should succeed: $output"
  [ "$output" = '0' ] || fail "expected 0 releases when first page is empty, got $output"
}

@test "forwards debug mode to git-api" {
  cd "$TMP_DIR"
  PAGE_1_JSON='[{"name":"v1.0.0","published_at":"2026-01-01T00:00:00Z","assets":[{"name":"only.tar.gz"}]}]' \
    run "$TOOL" --debug --max-releases 1 octo demo

  [ "$status" -eq 0 ] || fail "tool should succeed (got $status): $output"
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'true|repos/list-releases octo demo --per-page 100 --page 1' 'debug mode should be forwarded to git-api'
  assert_contains "$output" '[gh-release-assets] Fetching release page 1' 'debug mode should log page fetches'
}

@test "rejects non-positive --max-releases" {
  run "$TOOL" --max-releases 0 octo demo
  [ "$status" -ne 0 ] || fail 'should fail for --max-releases 0'
  assert_contains "$output" 'must be a positive integer' 'should explain the validation error'

  run "$TOOL" --max-releases abc octo demo
  [ "$status" -ne 0 ] || fail 'should fail for non-numeric --max-releases'
  assert_contains "$output" 'must be a positive integer' 'should explain the validation error'
}

@test "rejects unknown options" {
  run "$TOOL" --nope octo demo
  [ "$status" -ne 0 ] || fail 'should fail for unknown options'
  assert_contains "$output" 'unknown option' 'should report the unknown option'
}

@test "rejects more than two positional arguments" {
  run "$TOOL" octo demo extra
  [ "$status" -ne 0 ] || fail 'should fail for too many positional arguments'
  assert_contains "$output" 'expected at most two positional arguments' 'should explain the argument count limit'
}

@test "fails cleanly when git-api returns a non-array response" {
  cd "$TMP_DIR"
  # Simulate an error payload (e.g. auth failure) shaped like an object, not
  # an array. The tool must not silently write garbage to the output file.
  PAGE_1_JSON='{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}' \
    run "$TOOL" --max-releases 5 octo demo

  [ "$status" -ne 0 ] || fail "tool should fail when git-api returns a non-array (got status 0): $output"
  assert_contains "$output" 'unexpected response' 'should explain the unexpected response'
  [ ! -f "$TMP_DIR/octo-demo-releases.json" ] || fail 'should not write a partial output file on error'
}
