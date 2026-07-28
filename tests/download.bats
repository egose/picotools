#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/bin/download"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export HOME="$TMP_DIR/home"
  export PATH="$TMP_DIR/bin:$PATH"
  export ASDF_PICOTOOLS_GITHUB_REPOSITORY='egose/picotools'

  mkdir -p "$HOME" "$TMP_DIR/bin" "$TMP_DIR/downloads"

  cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

outfile=''
url=''
auth_header=''

while [ "$#" -gt 0 ]; do
  case "$1" in
  -o)
    outfile="$2"
    shift 2
    ;;
  -H)
    if [[ "$2" == Authorization:* ]]; then
      auth_header="$2"
    fi
    shift 2
    ;;
  -L | --fail)
    shift
    ;;
  --connect-timeout | --retry)
    shift 2
    ;;
  -sS)
    shift
    ;;
  *)
    url="$1"
    shift
    ;;
  esac
done

printf '%s\n' "$auth_header" >"${TMP_DIR}/curl-auth.log"
printf '%s\n' "$url" >"${TMP_DIR}/curl-url.log"

if [ "${DOWNLOAD_FAIL:-false}" = 'true' ]; then
  echo 'simulated download failure' >&2
  exit 22
fi

printf '%s\n' 'fake tarball payload' >"$outfile"
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

assert_file_exists() {
  local path="$1"
  local message="$2"

  [ -f "$path" ] || fail "$message ($path)"
}

@test "downloads the requested release artifact and normalizes a leading v" {
  local expected_file

  expected_file="$TMP_DIR/downloads/picotools-1.2.3.tar.gz"
  run env ASDF_INSTALL_VERSION='v1.2.3' ASDF_DOWNLOAD_PATH="$TMP_DIR/downloads" "$TOOL"

  [ "$status" -eq 0 ] || fail 'download should succeed for a valid version'
  assert_file_exists "$expected_file" 'should write the downloaded artifact into the requested directory'
  assert_contains "$(<"$TMP_DIR/curl-url.log")" '/releases/download/v1.2.3/picotools-1.2.3.tar.gz' 'should use a single v-prefixed release tag in the download URL'
}

@test "forwards a supported GitHub token header for downloads" {
  run env ASDF_INSTALL_VERSION='1.2.3' ASDF_DOWNLOAD_PATH="$TMP_DIR/downloads" GITHUB_TOKEN='secret-token' "$TOOL"

  [ "$status" -eq 0 ] || fail 'download should succeed when using authenticated downloads'
  assert_contains "$(<"$TMP_DIR/curl-auth.log")" 'Authorization: token secret-token' 'should forward the selected GitHub token as an Authorization header'
}

@test "fails when ASDF_INSTALL_VERSION is missing" {
  run env -u ASDF_INSTALL_VERSION ASDF_DOWNLOAD_PATH="$TMP_DIR/downloads" "$TOOL"

  [ "$status" -ne 0 ] || fail 'download should fail when ASDF_INSTALL_VERSION is missing'
  assert_contains "$output" 'Error: ASDF_INSTALL_VERSION must be set' 'should explain the missing version requirement'
}

@test "fails cleanly when curl cannot download the artifact" {
  run env ASDF_INSTALL_VERSION='1.2.3' ASDF_DOWNLOAD_PATH="$TMP_DIR/downloads" DOWNLOAD_FAIL='true' "$TOOL"

  [ "$status" -ne 0 ] || fail 'download should fail when curl fails'
  assert_contains "$output" 'simulated download failure' 'should surface curl failures'
  assert_contains "$output" 'Error: Failed to download picotools-1.2.3.tar.gz for v1.2.3.' 'should print the tool-specific failure message'
}
