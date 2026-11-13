#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets every isolated fixture.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers.

load 'helpers/k8s-profile'
load 'helpers/k8s-profile-tty'

@test "real PTY keeps ECHO off BETWEEN Token characters and restores exact terminal mode after success" {
  write_pty_plan <<'EOF'
{"initial_echonl":false,"expect_mask":true,"steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token_range":[0,1],"sample_echo":0.75,"after":"\n"}
]}
EOF
  run k8s_test_pty create "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "PTY stdin with REDIRECTED stderr keeps Token secret between reads and restores the original terminal" {
  write_pty_plan <<'EOF'
{"initial_echonl":false,"redirect_stderr":true,"steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token_range":[0,1],"sample_echo":0.75,"after":"\n"}
]}
EOF
  run k8s_test_pty create "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_eq "$(<"$TMP_HOME/pty-plan-terminal")" '' 'non-pretty terminal stdin must not echo secret or ordinary input bytes'
  assert_no_artifacts
}

@test "checked terminal editing retains backspace left-right Home-End deletion and Unicode Token bytes" {
  printf '%s' 'K8S_PTY_EDIT_é_漢_🔑_é' >"$TMP_HOME/sentinel"
  write_pty_plan <<'EOF'
{"expect_mask":true,"steps":[
  {"wait":"Name: ","input":"xwork\u0001\u001b[3~\u0005X\u007f\n"},
  {"wait":"Server: ","input":"https://api.invalix\b d\u0002\b\u0006\n"},
  {"wait":"Token: ","secret":true,"token":true},
  {"input":"\u001b[H\u001b[C\u001b[D\u001b[F"},
  {"token_range":[-2,null],"after":"\u007f\n"}
]}
EOF
  # Correct the last two Server characters with both backspace spellings and
  # left/right movement; the final value is the same credential-free default.
  run k8s_test_pty create "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_config_expr "$KUBECONFIG" '.contexts[0].name == "work" and .clusters[0].cluster.server == "https://api.invalid"'
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "TTY Name and Server NUL input is rejected instead of silently edited into another value" {
  local field
  for field in name server; do
    if [ "$field" = name ]; then
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"unsupported NUL character","steps":[
  {"wait":"Name: ","input":"work\u0000suffix\n"}
]}
EOF
    else
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"unsupported NUL character","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api\u0000.invalid\n"}
]}
EOF
    fi
    run k8s_test_pty create "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_file_not_exists "$KUBECONFIG" 'NUL-bearing ordinary terminal input must not publish config'
    assert_no_artifacts
  done
}

@test "TTY Token NUL is rejected in pretty AND redirected-stderr paths without unmasked output" {
  local redirected
  printf 'K8S_PTY_NUL\000_SENTINEL' >"$TMP_HOME/sentinel"
  for redirected in false true; do
    write_pty_plan <<EOF
{"redirect_stderr":$redirected,"expected_status":"failure","error":"unsupported NUL character","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"\n"}
]}
EOF
    run k8s_test_pty create "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_file_not_exists "$KUBECONFIG" 'terminal NUL must never be normalised into an accepted Token'
    assert_no_artifacts
  done
}

@test "TTY overwrite consent yes plus NUL cannot authorize replacement and terminal editing still supports default-no" {
  local redirected
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for redirected in false true; do
    write_pty_plan <<EOF
{"redirect_stderr":$redirected,"expected_status":"failure","error":"unsupported NUL character","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Overwrite? [y/N]: ","input":"yes\u0000\n"}
]}
EOF
    run k8s_test_pty create "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'TTY NUL must not authorize overwrite'
    assert_no_artifacts
  done
}

@test "TTY deletion consent yes plus NUL never deletes the selected context" {
  local redirected selection prompt
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for redirected in false true; do
    selection='\n'
    prompt='Enter to confirm'
    if [ "$redirected" = true ]; then
      selection='1\n'
      prompt='Select profile: '
    fi
    write_pty_plan <<EOF
{"redirect_stderr":$redirected,"expected_status":"failure","error":"unsupported NUL character","steps":[
  {"wait":"$prompt","input":"$selection"},
  {"wait":"Delete 'work'? [y/N]: ","input":"yes\u0000\n"}
]}
EOF
    run k8s_test_pty delete "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'TTY NUL-bearing deletion consent must preserve all bytes/current state'
    assert_no_artifacts
  done
}

@test "TTY update Server and Token NUL rejects every pending proposal and restores exact terminal mode" {
  local field
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  printf 'K8S_PTY_UPDATE\000_SENTINEL' >"$TMP_HOME/sentinel"
  for field in server token; do
    if [ "$field" = server ]; then
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"unsupported NUL character","steps":[
  {"wait":"Enter to confirm","input":"\n"},
  {"wait":"Update fields","input":"\u001b[A\u001b[A\n"},
  {"wait":"Server [https://external.invalid:6443]: ","input":"https://new\u0000.invalid\n"}
]}
EOF
    else
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"unsupported NUL character","steps":[
  {"wait":"Enter to confirm","input":"\n"},
  {"wait":"Update fields","input":"\u001b[A\u001b[A\n"},
  {"wait":"Server [https://external.invalid:6443]: ","input":"https://not-published.invalid\n"},
  {"wait":"Update fields","input":"\u001b[A\n"},
  {"wait":"Keep Token [configured]","input":"\u001b[B\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"\n"}
]}
EOF
    fi
    run k8s_test_pty update "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'TTY NUL validation must reject pending Server/Token updates'
    assert_no_artifacts
  done
}

@test "TTY arrow menus keep exact selection q-Esc cancellation and checked NUL behavior" {
  local action input
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for action in update delete; do
    for input in '\u001b' q '\u0000\n'; do
      write_pty_plan <<EOF
{"expected_status":"failure","steps":[{"wait":"Enter to confirm","input":"$input"}]}
EOF
      run k8s_test_pty "$action" "$TMP_HOME/pty-plan.json"
      assert_pty_passed
      assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'cancellation or NUL menu input must not select/mutate a profile'
      assert_no_artifacts
    done
  done
}

@test "TTY arrow selection and Server cursor editing update only the intended external profile" {
  seed_basic "$KUBECONFIG" a cluster user a
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context b --cluster=cluster --user=user >/dev/null
  write_pty_plan <<'EOF'
{"steps":[
  {"wait":"Enter to confirm","input":"\u001b[B\u001b[A\u001b[B\n"},
  {"wait":"Update fields","input":"\u001b[A\u001b[A\n"},
  {"wait":"Server [https://external.invalid:6443]: ","input":"wrong\u0015https://selected.invalid/trash\u001b[D\u001b[D\u001b[D\u001b[D\u001b[D\u000b\n"},
  {"wait":"Update fields","input":"\n"}
]}
EOF
  run k8s_test_pty update "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_config_expr "$KUBECONFIG" '
    .["current-context"] == "a" and any(.contexts[]; .name == "a" and .context.cluster == "cluster") and
    any(.contexts[]; .name == "b" and .context.cluster == "k8s-profile:b:cluster:1") and
    any(.clusters[]; .name == "k8s-profile:b:cluster:1" and .cluster.server == "https://selected.invalid/")
  '
  assert_no_artifacts
}

@test "TTY completed blank Server keeps its safe default but partial-line EOF never applies it" {
  local input expected
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for input in '\n' '\u0004' 'https://partial.invalid\u0004'; do
    expected='"failure"'
    if [ "$input" = '\n' ]; then expected=0; fi
    write_pty_plan <<EOF
{"expected_status":$expected,"steps":[
  {"wait":"Enter to confirm","input":"\n"},
  {"wait":"Update fields","input":"\u001b[A\u001b[A\n"},
  {"wait":"Server [https://external.invalid:6443]: ","input":"$input"}
]}
EOF
    if [ "$expected" = 0 ]; then
      "$K8S_TEST_REAL_JQ" '.steps += [{wait:"Update fields",input:"\n"}]' "$TMP_HOME/pty-plan.json" >"$TMP_HOME/edited-plan.json"
      mv "$TMP_HOME/edited-plan.json" "$TMP_HOME/pty-plan.json"
    fi
    run k8s_test_pty update "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'blank completed default is a no-op; EOF must not authorize it'
    assert_no_artifacts
  done
}

@test "TTY Token empty or partial EOF restores terminal state in pretty and redirected-stderr flows" {
  local redirected partial
  for redirected in false true; do
    for partial in false true; do
      write_pty_plan <<EOF
{"redirect_stderr":$redirected,"expected_status":"failure","error":"input ended before required value","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token":$partial,"after":"\u0004"}
]}
EOF
      run k8s_test_pty create "$TMP_HOME/pty-plan.json"
      assert_pty_passed
      assert_file_not_exists "$KUBECONFIG" 'partial or missing EOF Token must never be published'
      assert_no_artifacts
    done
  done
}

@test "TTY partial Name EOF fails promptly without publication and restores the exact terminal" {
  write_pty_plan <<'EOF'
{"expected_status":"failure","error":"input ended before required value","steps":[
  {"wait":"Name: ","input":"partial\u0004"}
]}
EOF
  run k8s_test_pty create "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_file_not_exists "$KUBECONFIG" 'partial Name EOF must not be accepted'
  assert_no_artifacts
}

@test "TERM INT and HUP to the tool PID during secret input restore terminal state with either stderr layout" {
  local handled expected redirected
  for redirected in false true; do
    for handled in TERM INT HUP; do
      case "$handled" in TERM) expected=143 ;; INT) expected=130 ;; HUP) expected=129 ;; esac
      write_pty_plan <<EOF
{"redirect_stderr":$redirected,"expected_status":$expected,"steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token":true},
  {"signal":"$handled"}
]}
EOF
      run k8s_test_pty create "$TMP_HOME/pty-plan.json"
      assert_pty_passed
      assert_file_not_exists "$KUBECONFIG" 'handled signal during Token capture must not publish config'
      assert_no_artifacts
    done
  done
}

@test "TTY invalid UTF-8 and Unicode controls fail private validation with exact terminal restoration" {
  local encoded redirected
  for encoded in 'K8S_PTY_INVALID_\377_END' 'K8S_PTY_CONTROL_\302\233_END'; do
    printf '%b' "$encoded" >"$TMP_HOME/sentinel"
    for redirected in false true; do
      write_pty_plan <<EOF
{"redirect_stderr":$redirected,"expected_status":"failure","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"\n"}
]}
EOF
      run k8s_test_pty create "$TMP_HOME/pty-plan.json"
      assert_pty_passed
      assert_file_not_exists "$KUBECONFIG" 'invalid encoding/control Token must fail before publication'
      assert_no_artifacts
    done
  done
}

@test "TTY update with redirected stderr retains numbered menus and exact replacement Token editing" {
  seed_basic "$KUBECONFIG" work cluster user work
  printf '%s' 'K8S_PTY_REPLACEMENT_é_🔑' >"$TMP_HOME/sentinel"
  write_pty_plan <<'EOF'
{"redirect_stderr":true,"steps":[
  {"wait":"Select profile: ","input":"1\n"},
  {"wait":"Select field [3]: ","input":"2\n"},
  {"wait":"Select Token action [1]: ","input":"2\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"X\b\n"},
  {"wait":"Select field [3]: ","input":"\n"}
]}
EOF
  run k8s_test_pty update "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_config_expr "$KUBECONFIG" '.["current-context"] == "work" and .clusters[0].cluster.server == "https://external.invalid:6443"'
  assert_no_artifacts
}

@test "TTY initially disabled ECHO stays disabled after successful secret input" {
  write_pty_plan <<'EOF'
{"initial_echo":false,"expect_mask":true,"steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"\n"}
]}
EOF
  run k8s_test_pty create "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "completed blank TTY required inputs retry without a secret ECHO window or loss of completed-line rules" {
  write_pty_plan <<'EOF'
{"expect_mask":true,"steps":[
  {"wait":"Name: ","input":"\n"},
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"input":"\n"},
  {"wait":"Token: ","secret":true,"token_range":[0,1],"sample_echo":0.5,"after":"\n"}
]}
EOF
  run k8s_test_pty create "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "TTY inherited allexport protects every secret editor local across ALL child commands on create and update" {
  local action redirected
  install_environment_audit_wrappers
  for action in create update; do
    for redirected in false true; do
      if [ "$action" = update ]; then printf '%s' '_REPLACEMENT' >>"$TMP_HOME/sentinel"; fi
      if [ "$action" = create ]; then
        rm -f "$KUBECONFIG"
        write_pty_plan <<EOF
{"redirect_stderr":$redirected,"steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"X\b\n"}
]}
EOF
      elif [ "$redirected" = false ]; then
        write_pty_plan <<'EOF'
{"steps":[
  {"wait":"Enter to confirm","input":"\n"},
  {"wait":"Update fields","input":"\u001b[A\n"},
  {"wait":"Keep Token [configured]","input":"\u001b[B\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"X\b\n"},
  {"wait":"Update fields","input":"\n"}
]}
EOF
      else
        write_pty_plan <<'EOF'
{"redirect_stderr":true,"steps":[
  {"wait":"Select profile: ","input":"1\n"},
  {"wait":"Select field [3]: ","input":"2\n"},
  {"wait":"Select Token action [1]: ","input":"2\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"X\b\n"},
  {"wait":"Select field [3]: ","input":"\n"}
]}
EOF
      fi
      rm -f "$TMP_HOME/audit"
      run k8s_test_env env SHELLOPTS=allexport:xtrace k8s_profile_token_value=public-inherited \
        k8s_profile_tty_line_buffer=public-inherited k8s_profile_tty_line_key=public-inherited \
        k8s_profile_key_bytes=public-inherited k8s_profile_key_suffix=public-inherited \
        "$K8S_TEST_REAL_PYTHON" "$REPO_ROOT/tests/helpers/k8s-profile-pty.py" "$TOOL" "$action" "$TMP_HOME/pty-plan.json"
      assert_pty_passed
      if grep -F -q -f "$TMP_HOME/sentinel" "$TMP_HOME/audit" "$TMP_HOME/pty-plan-stdout" "$TMP_HOME/pty-plan-stderr" "$TMP_HOME/pty-plan-terminal"; then fail 'TTY editor re-exported or displayed Token under inherited allexport/xtrace'; fi
      assert_token_bytes "$TMP_HOME/sentinel"
      assert_no_artifacts
    done
  done
}

@test "handled TERM while an arrow menu waits restores the terminal and cursor without a child-reader dependency" {
  local action attempt
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for action in update delete; do
    for attempt in {1..10}; do
      write_pty_plan <<'EOF'
{"expected_status":143,"steps":[
  {"wait":"\u001b[?25l"},
  {"signal":"TERM"}
]}
EOF
      run k8s_test_pty "$action" "$TMP_HOME/pty-plan.json"
      assert_pty_passed
      assert_contains "$(<"$TMP_HOME/pty-plan-terminal")" $'\033[?25h' 'handled signal must restore the visible menu cursor too'
      assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'menu signal must preserve config'
      assert_no_artifacts
    done
  done
}

@test "TTY partial yes plus EOF cannot authorize overwrite or deletion" {
  local action
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for action in create delete; do
    if [ "$action" = create ]; then
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"input ended before required value","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Overwrite? [y/N]: ","input":"yes\u0004"}
]}
EOF
    else
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"input ended before required value","steps":[
  {"wait":"Enter to confirm","input":"\n"},
  {"wait":"Delete 'work'? [y/N]: ","input":"yes\u0004"}
]}
EOF
    fi
    run k8s_test_pty "$action" "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'partial affirmative consent must not authorize mutation'
    assert_no_artifacts
  done
}

@test "TTY consent backspace navigation and completed blank retain default-no for overwrite and delete" {
  local action
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for action in create delete; do
    if [ "$action" = create ]; then
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"Cancelled.","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Overwrite? [y/N]: ","input":"yes\u0001\u000b\n"}
]}
EOF
    else
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"Cancelled.","steps":[
  {"wait":"Enter to confirm","input":"\n"},
  {"wait":"Delete 'work'? [y/N]: ","input":"yeX\b\u001b[Hs\u0015\u0005\u0015\n"}
]}
EOF
    fi
    run k8s_test_pty "$action" "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'completed blank consent must remain default-no after editing'
    assert_no_artifacts
  done
}

@test "partially failed terminal mode change and first restoration failure both restore saved fd state before EXIT" {
  local scenario
  install_stty_failure_wrapper
  for scenario in stty-mode-fail stty-restore-fail; do
    rm -f "$TMP_HOME/counter" "$TMP_HOME/marker"
    K8S_TEST_SCENARIO="$scenario"
    if [ "$scenario" = stty-mode-fail ]; then
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"unable to secure terminal input","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"}
]}
EOF
    else
      write_pty_plan <<'EOF'
{"expected_status":"failure","error":"unable to restore terminal state","steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"},
  {"wait":"Token: ","secret":true,"token":true,"after":"\n"}
]}
EOF
    fi
    run k8s_test_pty create "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_file_not_exists "$KUBECONFIG" 'terminal setup/restoration error must prevent successful publication'
    assert_no_artifacts
  done
}

@test "TERM immediately after terminal mode change restores state before the first Token read" {
  install_stty_failure_wrapper
  K8S_TEST_SCENARIO=stty-mode-signal
  write_pty_plan <<'EOF'
{"expected_status":143,"steps":[
  {"wait":"Name: ","input":"work\n"},
  {"wait":"Server: ","input":"https://api.invalid\n"}
]}
EOF
  run k8s_test_pty create "$TMP_HOME/pty-plan.json"
  assert_pty_passed
  assert_file_not_exists "$KUBECONFIG" 'mode-change signal must never publish config'
  assert_no_artifacts
}
