#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/asdf-cli-install"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export HOME="$TMP_DIR/home"
  export ASDF_DATA_DIR="$TMP_DIR/asdf"
  export STUB_BIN="$TMP_DIR/bin"
  export PATH="$STUB_BIN:$PATH"

  mkdir -p "$TMP_DIR/bin" "$HOME" "$ASDF_DATA_DIR"
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

write_curl_stub() {
  cat >"$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

write_releases_file="${ASDF_CLI_INSTALL_CURL_FIXTURE:-}"
if [ -z "$write_releases_file" ]; then
  echo "Error: no curl fixture configured" >&2
  exit 1
fi

options=()
outfile=''
doing_releases=false

while [ "$#" -gt 0 ]; do
  case "$1" in
  -H)
    shift 2
    ;;
  -sSL|--fail|-f)
    shift
    ;;
  -o)
    outfile="$2"
    shift 2
    ;;
  *)
    doing_releases=true
    shift
    ;;
  esac
done

if [ "$doing_releases" = true ]; then
  cat "$write_releases_file"
  exit 0
fi

# download path - copy the prepared tarball to outfile
if [ -n "$outfile" ]; then
  cp "$ASDF_CLI_INSTALL_DOWNLOAD_FIXTURE" "$outfile"
  exit 0
fi

exit 0
EOF
  chmod +x "$STUB_BIN/curl"
}

write_releases_fixture() {
  local fixture_file="$1"
  shift
  local tag

  printf '[' >"$fixture_file"
  local first=true
  for tag in "$@"; do
    if [ "$first" = true ]; then
      first=false
    else
      printf ',' >>"$fixture_file"
    fi
    printf '{"tag_name":"%s","name":"%s"}' "$tag" "$tag" >>"$fixture_file"
  done
  printf ']' >>"$fixture_file"
}

write_asdf_stub() {
  local version="${1:-0.18.0}"
  cat >"$STUB_BIN/asdf" <<EOF
#!/usr/bin/env bash
echo "asdf version v${version} (revision 2114f1e)"
EOF
  chmod +x "$STUB_BIN/asdf"
}

write_tar_stub() {
  cat >"$STUB_BIN/tar" <<'EOF'
#!/usr/bin/env bash
# tar -xzf <archive> -C <dir>
set -euo pipefail

unpack_dir=''
while [ "$#" -gt 0 ]; do
  case "$1" in
  -xzf)
    shift
    ;;
  -C)
    unpack_dir="$2"
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done

printf '#!/usr/bin/env bash\necho asdf fake binary\n' >"$unpack_dir/asdf"
EOF
  chmod +x "$STUB_BIN/tar"
}

write_install_stub() {
  cat >"$STUB_BIN/install" <<'EOF'
#!/usr/bin/env bash
# install -m 0755 <src> <dst>
set -euo pipefail
mode=''
src=''
dst=''
while [ "$#" -gt 0 ]; do
  case "$1" in
  -m)
    mode="$2"
    shift 2
    ;;
  *)
    if [ -z "$src" ]; then
      src="$1"
    else
      dst="$1"
    fi
    shift
    ;;
  esac
done

mkdir -p "$(dirname "$dst")"
cp "$src" "$dst"
chmod "$mode" "$dst"
EOF
  chmod +x "$STUB_BIN/install"
}

@test "lists recent releases and marks the currently installed version" {
  write_curl_stub
  write_asdf_stub 0.18.0
  write_releases_fixture "$TMP_DIR/releases.json" v0.20.0 v0.19.0 v0.18.1 v0.18.0 v0.17.0 v0.16.7 v0.16.6 v0.16.5 v0.16.4 v0.16.3
  ASDF_CLI_INSTALL_CURL_FIXTURE="$TMP_DIR/releases.json" \
    run bash -c 'printf "1\nn\n" | "$1"' _ "$TOOL"

  [ "$status" -eq 1 ] || fail 'should exit non-zero when the user declines the install confirmation'
  assert_contains "$output" '1. v0.20.0' 'should list the latest release'
  assert_contains "$output" '4. v0.18.0 (installed)' 'should annotate the currently installed release'
  assert_contains "$output" 'Selected version: v0.20.0' 'should track the selected release'
  assert_contains "$output" 'Current asdf version: v0.18.0' 'should print the detected current version'
  assert_contains "$output" 'Install this version now? [y/N]:' 'should ask for confirmation before installing'
  assert_contains "$output" 'Cancelled.' 'should report cancellation when the confirmation is declined'
}

@test "skips re-install when the picker selects the currently installed version" {
  write_curl_stub
  write_asdf_stub 0.18.0
  write_releases_fixture "$TMP_DIR/releases.json" v0.20.0 v0.19.0 v0.18.1 v0.18.0
  ASDF_CLI_INSTALL_CURL_FIXTURE="$TMP_DIR/releases.json" \
    run bash -c 'printf "4\n" | "$1"' _ "$TOOL"

  [ "$status" -eq 0 ] || fail 'should succeed when the selected version matches the installed one'
  assert_contains "$output" '4. v0.18.0 (installed)' 'should mark the installed version'
  assert_contains "$output" 'Version v0.18.0 is already installed. Skipping re-install.' 'should skip without re-installing'
}

@test "skips re-install when the requested version matches the current asdf CLI version" {
  write_curl_stub
  write_asdf_stub 0.18.0

  run "$TOOL" 0.18.0

  [ "$status" -eq 0 ] || fail 'should succeed when the requested version is already installed'
  assert_contains "$output" 'Installing requested version v0.18.0...' 'should accept a bare version argument'
  assert_contains "$output" 'Version v0.18.0 is already installed. Skipping re-install.' 'should skip when current matches requested'
}

@test "accepts a leading v in the requested version" {
  write_curl_stub
  write_asdf_stub 0.18.0

  run "$TOOL" --yes v0.18.0

  [ "$status" -eq 0 ] || fail 'should handle leading-v version syntax'
  assert_contains "$output" 'Version v0.18.0 is already installed. Skipping re-install.' 'should normalise a v-prefixed tag before comparison'
}

@test "installs the selected version under the configured prefix and runs asdf" {
  write_curl_stub
  write_asdf_stub 0.18.0
  write_tar_stub
  write_install_stub
  write_releases_fixture "$TMP_DIR/releases.json" v0.20.0 v0.19.0
  printf '#!/usr/bin/env bash\necho "fake asdf tarball"\n' >"$TMP_DIR/download.tar.gz"

  local prefix="$TMP_DIR/asdf-bin"
  ASDF_CLI_INSTALL_CURL_FIXTURE="$TMP_DIR/releases.json" \
    ASDF_CLI_INSTALL_DOWNLOAD_FIXTURE="$TMP_DIR/download.tar.gz" \
    run "$TOOL" --yes --prefix "$prefix" 0.20.0

  [ "$status" -eq 0 ] || fail 'should complete the install successfully with --yes'
  assert_contains "$output" "Downloading asdf v0.20.0 (linux/amd64)..." 'should print the download progress'
  assert_contains "$output" '🚀 asdf installed successfully' 'should print the plain stdout success line'
  [ -x "$prefix/asdf" ] || fail 'should place the asdf binary into the prefix directory'
}

@test "prompts and cancels when the user does not confirm the install" {
  write_curl_stub
  write_asdf_stub 0.18.0
  write_tar_stub
  write_install_stub
  write_releases_fixture "$TMP_DIR/releases.json" v0.20.0 v0.19.0
  printf '#!/usr/bin/env bash\necho "fake asdf tarball"\n' >"$TMP_DIR/download.tar.gz"

  local prefix="$TMP_DIR/asdf-bin"
  ASDF_CLI_INSTALL_CURL_FIXTURE="$TMP_DIR/releases.json" \
    ASDF_CLI_INSTALL_DOWNLOAD_FIXTURE="$TMP_DIR/download.tar.gz" \
    run bash -c 'printf "n\n" | "$1" --prefix "$2" 0.20.0' _ "$TOOL" "$prefix"

  [ "$status" -eq 1 ] || fail 'should exit non-zero when the confirmation is declined'
  assert_contains "$output" 'Install this version now? [y/N]:' 'should prompt before installing'
  assert_contains "$output" 'Cancelled.' 'should report cancellation before exiting'
  [ ! -e "$prefix/asdf" ] || fail 'should not write the binary when the user cancels'
}

@test "fails when no releases are returned from GitHub" {
  write_curl_stub
  write_asdf_stub 0.18.0
  printf '[]' >"$TMP_DIR/empty-releases.json"

  ASDF_CLI_INSTALL_CURL_FIXTURE="$TMP_DIR/empty-releases.json" \
    run bash -c 'printf "" | "$1"' _ "$TOOL"

  [ "$status" -eq 1 ] || fail 'should exit non-zero when no releases are returned'
  assert_contains "$output" 'Error: no asdf releases found.' 'should report the missing-release error'
}

@test "rejects an invalid --max-releases value" {
  run "$TOOL" --max-releases 0 1.0.0

  [ "$status" -eq 1 ] || fail 'should reject a zero max-releases value'
  assert_contains "$output" 'Error: --max-releases must be a positive integer' 'should explain the validation failure'
}

@test "help documents debug mode and the picker" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'asdf-cli-install --help should succeed'
  assert_contains "$output" '--debug' 'help should list debug mode'
  assert_contains "$output" 'interactive picker' 'help should describe the picker flow'
  assert_contains "$output" '--yes' 'help should list the --yes flag'
}
