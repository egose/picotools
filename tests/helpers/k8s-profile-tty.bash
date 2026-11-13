#!/usr/bin/env bash
# Tool and Token file paths, never Token bytes, reach the Python driver's argv.
k8s_test_pty() {
  k8s_test_env "$K8S_TEST_REAL_PYTHON" "$REPO_ROOT/tests/helpers/k8s-profile-pty.py" "$K8S_TEST_TOOL" "$1" "$2"
}

write_pty_plan() {
  cat >"$TMP_HOME/pty-plan.json"
}

assert_pty_passed() {
  # shellcheck disable=SC2154 # Bats run assigns status/output.
  [ "$status" -eq 0 ] || fail "PTY regression failed: $output"
  # shellcheck disable=SC2154 # Bats run assigns output.
  "$K8S_TEST_REAL_JQ" -e '.terminal_restored and (.echo_gap | not) and (.secret_in_output | not) and .assertion == null' <<<"$output" >/dev/null
}

install_stty_failure_wrapper() {
  mkdir -p "$TMP_HOME/stty-wrapper"
  cat >"$TMP_HOME/stty-wrapper/stty" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
-echo)
  count=0
  if [ -f "$K8S_TEST_COUNTER" ]; then count=$(<"$K8S_TEST_COUNTER"); fi
  count=$((count + 1))
  printf '%s' "$count" >"$K8S_TEST_COUNTER"
  "$K8S_TEST_REAL_STTY" "$@"
  if [ "$count" -eq 3 ]; then
    case "$K8S_TEST_SCENARIO" in
    stty-mode-fail) exit 42 ;; # Deliberately fail AFTER changing mode.
    stty-mode-signal) kill -TERM "$PPID" ;;
    esac
  fi
  ;;
--version | -g) exec "$K8S_TEST_REAL_STTY" "$@" ;;
*)
  if [ "$K8S_TEST_SCENARIO" = stty-restore-fail ] && [ "$(<"$K8S_TEST_COUNTER")" = 3 ] && [ ! -f "$K8S_TEST_MARKER" ]; then
    : >"$K8S_TEST_MARKER"
    exit 42
  fi
  exec "$K8S_TEST_REAL_STTY" "$@"
  ;;
esac
EOF
  chmod +x "$TMP_HOME/stty-wrapper/stty"
  PATH="$TMP_HOME/stty-wrapper:$PATH"
}
