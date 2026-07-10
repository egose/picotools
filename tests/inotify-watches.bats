#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/inotify-watches"

setup() {
  ROOT_DIR="$(mktemp -d)" || return 1
  export ROOT_DIR

  PROC="$ROOT_DIR/proc"
  MAX_FILE="$PROC/sys/fs/inotify/max_user_watches"
  mkdir -p "$(dirname "$MAX_FILE")"
  echo '524288' >"$MAX_FILE"

  mkdir -p "$PROC/100/fdinfo" "$PROC/200/fdinfo" "$PROC/300/fdinfo"

  cat >"$PROC/100/fdinfo/3" <<'EOF'
pos:	0
flags:	02000002
inotify wd:1 ino:2 sdev:3 mask:280 ignored_mask:0
inotify wd:2 ino:4 sdev:3 mask:280 ignored_mask:0
EOF
  printf '\0/bin/sh\0-c\0echo hi\0' >"$PROC/100/cmdline"

  cat >"$PROC/200/fdinfo/3" <<'EOF'
pos:	0
flags:	02000002
EOF
  printf '\0node\0/app/server.js\0' >"$PROC/200/cmdline"

  printf '\0' >"$PROC/300/cmdline"
  echo 'kworker' >"$PROC/300/comm"
  cat >"$PROC/300/fdinfo/5" <<'EOF'
inotify wd:1 ino:9 sdev:3 mask:280 ignored_mask:0
EOF
}

teardown() {
  [ -n "${ROOT_DIR:-}" ] && rm -rf "$ROOT_DIR"
}

fail() {
  echo "FAIL: $1" >&2
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

run_tool() {
  "$TOOL" --proc "$PROC" --max-file "$MAX_FILE" "$@"
}

@test "renders summary and top consumers table" {
  local output
  output=$(run_tool --all)

  assert_contains "$output" '| Total watches    | 3' 'summary should render the total watch count'
  assert_contains "$output" '| max_user_watches | 524288' 'summary should render the limit value'
  assert_contains "$output" 'Usage bar' 'summary should include a usage bar row'
  assert_contains "$output" '| Watches |' 'consumer table should render the Watches column header'
  assert_contains "$output" '| Usage % |' 'consumer table should render the Usage % column header'
  assert_contains "$output" '| Usage Bar' 'consumer table should render the Usage Bar column header'
  assert_contains "$output" '| Command' 'consumer table should render the Command column header'
  assert_contains "$output" '| 2       | 100 |' 'table should list PID 100 with two watches first'
  assert_contains "$output" '| 1       | 300 |' 'table should list PID 300 with one watch second'
  assert_not_contains "$output" '| 0       | 200 |' 'table should omit zero-watch processes by default'
  assert_contains "$output" '/bin/sh -c echo hi' 'table should render the decoded PID 100 command line'
  assert_contains "$output" '| kworker' 'table should fall back to /proc/<pid>/comm for empty cmdline'
}

@test "respects --show-zeros to include zero-watch processes" {
  local output
  output=$(run_tool --all --show-zeros)

  assert_contains "$output" '| 0       | 200 |' 'show-zeros should include zero-watch processes'
  assert_contains "$output" 'node /app/server.js' 'show-zeros should include the decoded PID 200 command line'
}

@test "respects --top N to limit consumer rows" {
  local output
  output=$(run_tool --top 1)

  assert_contains "$output" '| 2       | 100 |' 'top 1 should keep the highest consumer'
  assert_contains "$output" '| Total watches    | 3' 'summary should still render the cumulative total'
  assert_not_contains "$output" '| 1       | 300 |' 'top 1 should drop lower-ranked consumers'
}

@test "warns when total watches exceed the limit" {
  echo '1' >"$MAX_FILE"

  local output
  output=$(run_tool --all)

  assert_contains "$output" '| Total watches    | 3' 'summary should reflect the inflated total against a tiny limit'
  assert_contains "$output" 'Warning: total watches exceed max_user_watches limit.' 'tool should emit a warning when the total exceeds the limit'
}

@test "debug mode prints progress to stderr" {
  local stderr_output
  stderr_output=$(run_tool --all --debug 2>&1 >/dev/null)

  assert_contains "$stderr_output" '[inotify-watches] Proc root:' 'debug should log the proc root'
  assert_contains "$stderr_output" '[inotify-watches] Scanning PID 100' 'debug should log each scanned PID'
  assert_contains "$stderr_output" 'max_user_watches: 524288' 'debug should log the resolved limit'
}

@test "help documents debug mode and top flag" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'inotify-watches --help should succeed'
  assert_contains "$output" '--debug' 'help should list debug mode'
  assert_contains "$output" 'Usage: inotify-watches' 'help should show the usage line'
  assert_contains "$output" '-n, --top N' 'help should list the top flag'
  assert_contains "$output" '--show-zeros' 'help should list the show-zeros flag'
}

@test "version reports repository VERSION" {
  run "$TOOL" --version

  [ "$status" -eq 0 ] || fail 'inotify-watches --version should succeed'
  [ "$output" = "$(cat "$REPO_ROOT/VERSION")" ] || fail 'inotify-watches --version should match repo VERSION'
}

@test "rejects invalid --top value" {
  run "$TOOL" --proc "$PROC" --max-file "$MAX_FILE" --top abc

  [ "$status" -ne 0 ] || fail 'inotify-watches --top abc should fail'
}

@test "help documents kill flags" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'inotify-watches --help should succeed'
  assert_contains "$output" '-k, --kill' 'help should list the kill flag'
  assert_contains "$output" '--dry-run' 'help should list the dry-run flag'
  assert_contains "$output" '--yes' 'help should list the yes flag'
  assert_contains "$output" '-p, --pid PID' 'help should list the pid flag'
  assert_contains "$output" '-s, --signal SIG' 'help should list the signal flag'
}

@test "explicit positional PID with --dry-run emits kill commands" {
  local output
  output=$(run_tool --dry-run --yes 100 300)

  assert_contains "$output" 'Kill targets:' 'explicit kill mode should print a kill targets section'
  assert_contains "$output" '| 100 | 2' 'kill targets table should list the requested PID 100'
  assert_contains "$output" '| 300 | 1' 'kill targets table should list the requested PID 300'
  assert_contains "$output" 'Signal: TERM' 'kill mode should report the default signal'
  assert_contains "$output" 'kill -TERM 100' 'dry-run should print the kill command for PID 100'
  assert_contains "$output" 'kill -TERM 300' 'dry-run should print the kill command for PID 300'
}

@test "--pid flag accepts repeatable PIDs and forces kill mode" {
  local output
  output=$(run_tool --pid 100 --pid 300 --dry-run --yes)

  assert_contains "$output" 'kill -TERM 100' 'dry-run should print the kill command for PID 100'
  assert_contains "$output" 'kill -TERM 300' 'dry-run should print the kill command for PID 300'
}

@test "--signal overrides the kill signal" {
  local output
  output=$(run_tool --signal KILL --dry-run --yes 100)

  assert_contains "$output" 'Signal: KILL' 'kill mode should report the requested signal'
  assert_contains "$output" 'kill -KILL 100' 'dry-run should print the requested signal'
}

@test "--signal rejects invalid signal names" {
  run "$TOOL" --proc "$PROC" --max-file "$MAX_FILE" --dry-run --yes --signal BOGUS 100

  [ "$status" -ne 0 ] || fail 'inotify-watches --signal BOGUS should fail'
  assert_contains "$output" "Error: invalid signal 'BOGUS'" 'invalid signal should produce an error'
}

@test "explicit kill rejects PIDs that are not in proc" {
  run "$TOOL" --proc "$PROC" --max-file "$MAX_FILE" --dry-run --yes 9999

  [ "$status" -ne 0 ] || fail 'inotify-watches --dry-run 9999 should fail'
  assert_contains "$output" 'Error: PID 9999 not found' 'missing PID should produce an error'
}

@test "explicit kill deduplicates repeated PIDs" {
  local output
  output=$(run_tool --pid 100 --pid 100 --dry-run --yes)

  assert_contains "$output" 'kill -TERM 100' 'dry-run should print PID 100'
  [ "$(printf '%s' "$output" | grep -c 'kill -TERM 100')" -eq 1 ] || fail 'PID 100 should be killed only once'
}

@test "--kill --yes --all selects every consumer for dry-run" {
  local output
  output=$(run_tool --kill --dry-run --yes --all)

  assert_contains "$output" 'kill -TERM 100' 'auto-select kill should include PID 100'
  assert_contains "$output" 'kill -TERM 300' 'auto-select kill should include PID 300'
  assert_not_contains "$output" 'kill -TERM 200' 'auto-select kill should skip zero-watch PID 200'
}
