#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to private fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets every isolated environment.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers.

load 'helpers/k8s-profile'
load 'helpers/k8s-profile-tty'

@test "use accepts one optional nonempty name before dependencies and preserves global debug grammar" {
  local restricted_path
  restricted_path=$(path_with_commands "$TMP_HOME/restricted" bash dirname cat)
  run env PATH="$restricted_path" "$TOOL" use
  [ "$status" -ne 0 ]
  assert_contains "$output" 'kubectl is required but not installed' 'optional-name use must check dependencies before prompting'
  run env PATH="$restricted_path" "$TOOL" use ''
  [ "$status" -ne 0 ]
  assert_contains "$output" 'use accepts at most one nonempty profile name' 'empty names cannot clear current-context'
  run env PATH="$restricted_path" "$TOOL" use work extra
  [ "$status" -ne 0 ]
  assert_contains "$output" 'use accepts at most one nonempty profile name' 'extra operands must be rejected'
  assert_not_contains "$output" 'required but not installed' 'grammar must precede dependencies'
  run env PATH="$restricted_path" "$TOOL" use --debug
  [ "$status" -ne 0 ]
  assert_contains "$output" '--debug is a global option' 'debug stays global-only'
  run env PATH="$restricted_path" "$TOOL" use work
  [ "$status" -ne 0 ]
  assert_contains "$output" 'kubectl is required but not installed' 'valid use grammar must check dependencies'
  assert_file_not_exists "$KUBECONFIG" 'invalid calls must not write'
  assert_no_artifacts
}

@test "use without a name selects from the sorted menu while retaining exact escaped external identity" {
  local name=$'z space "quote"|é-🔑\nnext'
  seed_basic "$KUBECONFIG" "$name" cluster user previous
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context alpha --cluster=cluster --user=user >/dev/null
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  printf '2\n' | run_tool use >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" 'Select profile' 'omitted name should offer the profile menu'
  assert_contains "$(<"$TMP_HOME/stdout")" '\u007c' 'result must escape display punctuation'
  assert_not_contains "$(<"$TMP_HOME/stdout")" $'\nnext' 'escaped menu labels must not corrupt output'
  assert_config_expr "$KUBECONFIG" '. == ($before[0] | .["current-context"] = $name)' --slurpfile before "$TMP_HOME/before.json" --arg name "$name"
  assert_no_artifacts
}

@test "use without a name on an empty config is friendly and creates no config or directories" {
  run run_tool use </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" 'No Kubernetes profiles found.' 'empty menu should explain why nothing can be selected'
  assert_file_not_exists "$KUBECONFIG" 'empty selection must not create a config'
  [ ! -d "$HOME/.kube" ]
  assert_no_artifacts
}

@test "use menu cancellation EOF partial input invalid indexes and NUL leave the current profile byte-identical" {
  local input
  seed_basic "$KUBECONFIG" work cluster user previous
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for input in $'q\n' $'Q\n' '' '1' $'0\n' $'2\n' $'bad\n' $'\n'; do
    if printf '%s' "$input" | run_tool use >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'cancelled or invalid selection must fail'; fi
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'menu failure must not publish a switch'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'menu failure must not claim success'
    assert_no_artifacts
  done
  if printf '1\000suffix\n' | run_tool use >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'NUL selection must fail'; fi
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'NUL-bearing selection must not authorize a different choice'
  assert_no_artifacts
}

@test "use menu cannot activate an empty-named context or clear the current profile" {
  seed_basic "$KUBECONFIG" work cluster user previous
  "$K8S_TEST_REAL_JQ" '.contexts[0].name = ""' "$KUBECONFIG" >"$TMP_HOME/empty-name.json"
  mv "$TMP_HOME/empty-name.json" "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  if printf '1\n' | run_tool use >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'empty context cannot be activated'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'an empty context name cannot be activated' 'empty context must not act as a clear command'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'empty selection must not clear current-context'
  assert_no_artifacts
}

@test "use menu rechecks stale and disappeared contexts before planning a switch" {
  local scenario
  install_failure_wrappers
  for scenario in stale-selection disappeared-selection; do
    seed_basic "$KUBECONFIG" work cluster user previous
    rm -f "$TMP_HOME/marker"
    K8S_TEST_TARGET="$KUBECONFIG"
    K8S_TEST_SCENARIO="$scenario"
    if printf '1\n' | run_tool use >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'stale menu must not publish'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'changed since it was read' 'menu choice must be checked against the original snapshot'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'stale selection must not claim success'
    if [ "$scenario" = stale-selection ]; then
      assert_config_expr "$KUBECONFIG" '.["current-context"] == "newer-external"'
    else
      assert_config_expr "$KUBECONFIG" '(.contexts // [] | length) == 0 and .["current-context"] == "previous"'
    fi
    assert_no_artifacts
  done
}

@test "use real terminal arrow and redirected numbered selection restore exact terminal state" {
  local redirected
  for redirected in false true; do
    seed_basic "$KUBECONFIG" work cluster user previous
    k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context alpha --cluster=cluster --user=user >/dev/null
    if [ "$redirected" = true ]; then
      write_pty_plan <<'EOF'
{"redirect_stderr":true,"steps":[{"wait":"Select profile: ","input":"2\n"}]}
EOF
    else
      write_pty_plan <<'EOF'
{"steps":[{"wait":"Enter to confirm","input":"\u001b[B\n"}]}
EOF
    fi
    run k8s_test_pty use "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_config_expr "$KUBECONFIG" '.["current-context"] == "work"'
    assert_no_artifacts
  done
}

@test "use real terminal q and Esc cancellation restore state without changing selection" {
  local key
  seed_basic "$KUBECONFIG" work cluster user previous
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for key in q '\u001b'; do
    write_pty_plan <<EOF
{"expected_status":"failure","steps":[{"wait":"Enter to confirm","input":"$key"}]}
EOF
    run k8s_test_pty use "$TMP_HOME/pty-plan.json"
    assert_pty_passed
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'TTY cancellation must not switch or rewrite'
    assert_no_artifacts
  done
}

@test "use switches an external profile without prompting or changing any settings or credentials" {
  seed_basic "$KUBECONFIG" work cluster user previous
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  run run_tool --debug use work </dev/null
  [ "$status" -eq 0 ]
  assert_contains "$output" "Switched to profile 'work'." 'switch should report the selected profile'
  assert_not_contains "$output" 'Select profile' 'named switching must not prompt'
  assert_not_contains "$output" "$(<"$TMP_HOME/sentinel")" 'switch output must not disclose credentials'
  assert_config_expr "$KUBECONFIG" '. == ($before[0] | .["current-context"] = "work")' --slurpfile before "$TMP_HOME/before.json"
  run k8s_test_env "$K8S_TEST_REAL_KUBECTL" config current-context
  [ "$status" -eq 0 ]
  assert_eq "$output" work 'independent kubectl must see the switch'
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" '| yes' 'authoritative list must reflect the switch'
  assert_mode "$KUBECONFIG" 600 'switch publication must remain private'
  assert_no_artifacts
}

@test "use activates a newly created profile without changing its Token or TLS configuration" {
  create_profile work >/dev/null 2>"$TMP_HOME/create.err"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  run run_tool use work
  [ "$status" -eq 0 ]
  assert_config_expr "$KUBECONFIG" '. == ($before[0] | .["current-context"] = "work")' --slurpfile before "$TMP_HOME/before.json"
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "use already-current is a byte mode and inode preserving no-op even with a foreign lock" {
  seed_basic "$KUBECONFIG" work cluster user work
  chmod 644 "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  local before
  before=$(stat -c '%d:%i:%a:%y:%z' "$KUBECONFIG")
  printf 'foreign-lock' >"$KUBECONFIG.lock"
  run run_tool use work
  [ "$status" -eq 0 ]
  assert_contains "$output" "Profile 'work' is already current." 'no-op should be explicit'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'no-op must preserve bytes'
  assert_eq "$(stat -c '%d:%i:%a:%y:%z' "$KUBECONFIG")" "$before" 'no-op must not rewrite the file'
  assert_eq "$(<"$KUBECONFIG.lock")" foreign-lock 'no-op must not touch a lock'
  assert_no_artifacts true
}

@test "use first existing chain member takes precedence without creating missing files or moving resources" {
  local first="$HOME/first/config" second="$HOME/second/config" missing="$HOME/missing/config" last="$HOME/last/config"
  seed_empty "$first"
  seed_basic "$second" work cluster user fallback
  cp "$first" "$TMP_HOME/before-first"
  cp "$second" "$TMP_HOME/before-second"
  KUBECONFIG="$missing:$first:$second:$last"
  run run_tool use work
  [ "$status" -eq 0 ]
  assert_config_expr '' '.["current-context"] == "work" and .contexts[0].name == "work"'
  assert_config_expr "$first" '.["current-context"] == "work" and (.contexts // [] | length) == 0 and (.users // [] | length) == 0 and (.clusters // [] | length) == 0'
  assert_same_file "$second" "$TMP_HOME/before-second" 'lower physical resource/current state must stay byte-identical'
  assert_file_not_exists "$missing" 'missing higher file must not be created'
  assert_file_not_exists "$last" 'missing lower file must not be created'
  [ ! -d "$HOME/missing" ]
  assert_no_artifacts
}

@test "use replaces the effective higher current-context while preserving all lower fallbacks" {
  local first="$HOME/first/config" second="$HOME/second/config" third="$HOME/third/config"
  seed_basic "$first" previous previous-cluster previous-user previous
  seed_basic "$second" work cluster user hidden-one
  seed_empty "$third"
  "$K8S_TEST_REAL_JQ" '.["current-context"] = "hidden-two"' "$third" >"$TMP_HOME/third.json"
  mv "$TMP_HOME/third.json" "$third"
  read_config_json "$TMP_HOME/before-first.json" "$first"
  cp "$second" "$TMP_HOME/before-second"
  cp "$third" "$TMP_HOME/before-third"
  KUBECONFIG="$first:$second:$third"
  run run_tool use work
  [ "$status" -eq 0 ]
  assert_config_expr '' '.["current-context"] == "work" and (.contexts | length) == 2'
  assert_config_expr "$first" '. == ($before[0] | .["current-context"] = "work")' --slurpfile before "$TMP_HOME/before-first.json"
  assert_same_file "$second" "$TMP_HOME/before-second" 'lower current fallback must remain untouched'
  assert_same_file "$third" "$TMP_HOME/before-third" 'hidden different fallback must remain untouched'
  assert_no_artifacts
}

@test "use inherited lower current-context is also a byte-preserving no-op" {
  local first="$HOME/first/config" second="$HOME/second/config"
  seed_empty "$first"
  seed_basic "$second" work cluster user work
  cp "$first" "$TMP_HOME/before-first"
  cp "$second" "$TMP_HOME/before-second"
  KUBECONFIG="$first:$second"
  run run_tool use work
  [ "$status" -eq 0 ]
  assert_contains "$output" 'already current' 'effective inherited selection needs no write'
  assert_same_file "$first" "$TMP_HOME/before-first" 'no-op must not populate a higher current value'
  assert_same_file "$second" "$TMP_HOME/before-second" 'no-op must not rewrite the selected origin'
  assert_no_artifacts
}

@test "use supports literal colon HOME defaults with unset or empty KUBECONFIG" {
  local spelling config
  HOME="$TMP_HOME/home:colon"
  config="$HOME/.kube/config"
  for spelling in unset empty; do
    seed_basic "$config" work cluster user previous
    if [ "$spelling" = unset ]; then unset KUBECONFIG; else KUBECONFIG=''; fi
    run run_tool use work
    [ "$status" -eq 0 ]
    assert_config_expr "$config" '.["current-context"] == "work"'
    assert_no_artifacts
  done
}

@test "use relative multi-file chains retain native origins beneath a colon cwd" {
  local root="$HOME/cwd:colon"
  seed_empty "$root/first"
  seed_basic "$root/second" work cluster user previous
  cp "$root/second" "$TMP_HOME/before-second"
  KUBECONFIG='first:second'
  (
    cd "$root" || exit 1
    run_tool use work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  )
  KUBECONFIG="$root/first" # Explicit per-file reads below do not split this path.
  assert_config_expr "$root/first" '.["current-context"] == "work"'
  assert_same_file "$root/second" "$TMP_HOME/before-second" 'relative chain switching must not relocate credentials'
  assert_no_artifacts
}

@test "use exact external UTF8 quoted option-like and control-bearing names never interprets them as options or display labels" {
  local name
  for name in '--option-like' $'space "quote"|é-🔑-é\nnext' $'separator-\u2028-\u2029'; do
    seed_basic "$KUBECONFIG" "$name" cluster user previous
    read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
    run run_tool use "$name"
    [ "$status" -eq 0 ]
    assert_config_expr "$KUBECONFIG" '. == ($before[0] | .["current-context"] = $name)' --slurpfile before "$TMP_HOME/before.json" --arg name "$name"
    assert_not_contains "$output" $'\nnext' 'control names must not create fake output lines'
    assert_no_artifacts
  done
}

@test "use refuses invalid UTF8 argument bytes that would otherwise match a literal replacement-character context" {
  seed_basic "$KUBECONFIG" 'name-�' cluster user previous
  cp "$KUBECONFIG" "$TMP_HOME/before"
  run run_tool use $'name-\377'
  [ "$status" -ne 0 ]
  assert_contains "$output" 'profile name must match an existing context exactly' 'lossy jq argument conversion must not select a different context'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'lossy name must not change current-context'
  run run_tool use 'name-�'
  [ "$status" -eq 0 ]
  assert_config_expr "$KUBECONFIG" '.["current-context"] == "name-�"'
  assert_no_artifacts
}

@test "use unknown contexts preserves existing bytes and missing configs without creating directories" {
  run run_tool use missing
  [ "$status" -ne 0 ]
  assert_contains "$output" 'profile does not exist' 'unknown name must be a controlled failure'
  assert_file_not_exists "$KUBECONFIG" 'unknown name must not create config'
  [ ! -d "$HOME/.kube" ]
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  run run_tool use missing
  [ "$status" -ne 0 ]
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'unknown name must not clear a valid selection'
  KUBECONFIG='::'
  run run_tool use work
  [ "$status" -ne 0 ]
  assert_contains "$output" 'KUBECONFIG has no file paths' 'separator-only chain must not fall back to HOME'
  assert_no_artifacts
}

@test "use shadow refusal applies even when the ambiguous context is already current" {
  local shadow="$HOME/shadow/config" current
  seed_basic "$shadow" work hidden-cluster hidden-user hidden
  cp "$shadow" "$TMP_HOME/before-shadow"
  for current in previous work; do
    KUBECONFIG="$HOME/.kube/config"
    seed_basic "$KUBECONFIG" work cluster user "$current"
    cp "$KUBECONFIG" "$TMP_HOME/before"
    KUBECONFIG="$KUBECONFIG:$shadow"
    run run_tool use work
    [ "$status" -ne 0 ]
    assert_contains "$output" 'multiple physical definitions' 'shadowed names must not switch or claim a safe no-op'
    assert_same_file "$HOME/.kube/config" "$TMP_HOME/before" 'shadow refusal must preserve the effective file'
    assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'shadow refusal must preserve hidden file bytes'
    assert_no_artifacts
  done
}

@test "use retains split relative CA tokenFile and exec authentication without opening files or executing plugins" {
  local first="$HOME/first/config" source="$HOME/source/config" material
  seed_empty "$first"
  seed_basic "$source" work cluster user previous
  "$K8S_TEST_REAL_JQ" --arg plugin "$HOME/plugin" '
    .clusters[0].cluster["certificate-authority"] = "ca.pem" |
    .users[0].user = {tokenFile:"token-file",exec:{apiVersion:"client.authentication.k8s.io/v1",command:$plugin,interactiveMode:"Never"}}
  ' "$source" >"$TMP_HOME/source.json"
  mv "$TMP_HOME/source.json" "$source"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 99\n' "$HOME/plugin-ran" >"$HOME/plugin"
  chmod +x "$HOME/plugin"
  # FIFOs would block if credential/CA files were read, proving no file access.
  for material in ca.pem token-file; do mkfifo "$HOME/source/$material"; done
  cp "$source" "$TMP_HOME/before-source"
  KUBECONFIG="$first:$source"
  run k8s_test_env timeout 15 "$TOOL" use work
  [ "$status" -eq 0 ]
  assert_same_file "$source" "$TMP_HOME/before-source" 'relative origins and authentication must stay byte-identical'
  assert_file_not_exists "$HOME/plugin-ran" 'switch must never execute a credential plugin'
  [ -p "$HOME/source/ca.pem" ]
  [ -p "$HOME/source/token-file" ]
  assert_no_artifacts
}

@test "use accepts existing incomplete contexts without inventing cluster or user resources" {
  write_fixture "$KUBECONFIG" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"incomplete","context":{"cluster":"missing","user":"missing","namespace":"kept"}}],"current-context":"previous"}
EOF
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  run run_tool use incomplete
  [ "$status" -eq 0 ]
  assert_config_expr "$KUBECONFIG" '. == ($before[0] | .["current-context"] = "incomplete")' --slurpfile before "$TMP_HOME/before.json"
  assert_no_artifacts
}

@test "use rejects symbolic hardlinked and FIFO chain inputs before publication" {
  local config="$HOME/real/config" path
  seed_basic "$config" work cluster user previous
  cp "$config" "$TMP_HOME/before"
  ln -s "$config" "$HOME/symlink"
  for path in "$HOME/symlink" "$HOME/fifo" "$HOME/hardlink"; do
    case "$path" in
    */fifo) mkfifo "$path" ;;
    */hardlink) ln "$config" "$path" ;;
    esac
    KUBECONFIG="$path"
    run k8s_test_env timeout 5 "$TOOL" use work
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    assert_contains "$output" 'unsafe kubeconfig path' 'unsafe file identity must fail promptly'
    assert_same_file "$config" "$TMP_HOME/before" 'unsafe chain must retain original config'
    assert_no_artifacts
  done
}

@test "use unsafe writable parents invalid UTF8 paths and distinct aliases are controlled refusals" {
  local config="$HOME/unsafe/config" invalid="$HOME/invalid-"$'\377'"/config"
  seed_basic "$config" work cluster user previous
  cp "$config" "$TMP_HOME/before"
  chmod 777 "$HOME/unsafe"
  KUBECONFIG="$config"
  run run_tool use work
  [ "$status" -ne 0 ]
  assert_contains "$output" 'group/world writable' 'unsafe destination ancestry must fail'
  assert_same_file "$config" "$TMP_HOME/before" 'unsafe parent must not authorize writes'
  seed_basic "$invalid" work cluster user previous
  cp "$invalid" "$TMP_HOME/before-invalid"
  KUBECONFIG="$invalid"
  run run_tool use work
  [ "$status" -ne 0 ]
  assert_contains "$output" 'must be valid UTF-8' 'switching must retain mutation path encoding policy'
  assert_same_file "$invalid" "$TMP_HOME/before-invalid" 'invalid path must stay byte-identical'
  chmod 700 "$HOME/unsafe"
  KUBECONFIG="$config:$HOME/unsafe/./config"
  run run_tool use work
  [ "$status" -ne 0 ]
  assert_contains "$output" 'alias the same file' 'distinct lexical aliases must remain refused'
  assert_no_artifacts
}

@test "use preserves an unavailable target lock and original config" {
  seed_basic "$KUBECONFIG" work cluster user previous
  cp "$KUBECONFIG" "$TMP_HOME/before"
  printf 'foreign-lock' >"$KUBECONFIG.lock"
  run run_tool use work
  [ "$status" -ne 0 ]
  assert_contains "$output" 'lock is unavailable' 'switching must use cooperative locks'
  assert_eq "$(<"$KUBECONFIG.lock")" foreign-lock 'foreign lock must not be replaced or removed'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'lock failure must precede publication'
  assert_no_artifacts true
}

@test "use staging validation publication post-publication and handled TERM failures preserve prior bytes and hide diagnostics" {
  local scenario
  install_failure_wrappers
  for scenario in use-stage-fail copy-fail chmod-fail validation-fail publish-fail verify-fail signal-publish; do
    seed_basic "$KUBECONFIG" work cluster user previous
    "$K8S_TEST_REAL_CP" "$KUBECONFIG" "$TMP_HOME/before"
    rm -f "$TMP_HOME/counter"
    K8S_TEST_SCENARIO="$scenario"
    if run_tool use work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'injected switch failure must fail'; fi
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'switch failure must preserve or restore original bytes'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed switching must never claim success'
    assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'injected raw diagnostics must stay private'
    if [ "$scenario" = verify-fail ]; then
      assert_contains "$(<"$TMP_HOME/stderr")" 'Previous configuration restored.' 'failed post-publication verification must restore prior state'
    fi
    assert_no_artifacts
  done
}

@test "use candidate drift and permissions are rejected before publication" {
  local scenario
  install_failure_wrappers
  for scenario in changed-candidate candidate-permission candidate-after-chain; do
    seed_basic "$KUBECONFIG" work cluster user previous
    "$K8S_TEST_REAL_CP" "$KUBECONFIG" "$TMP_HOME/before"
    K8S_TEST_SCENARIO="$scenario"
    if run_tool use work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'candidate drift must fail switching'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'candidate' 'candidate integrity errors must remain controlled'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'corrupt candidate must never be published'
    assert_no_artifacts
  done
}

@test "use rechecks concurrent edits in untouched chain members during planning and validation" {
  local first="$HOME/first/config" other="$HOME/other/config" scenario
  install_failure_wrappers
  for scenario in stale-use-plan stale-validation; do
    seed_empty "$first"
    seed_basic "$other" work cluster user previous
    "$K8S_TEST_REAL_CP" "$first" "$TMP_HOME/before-first"
    rm -f "$TMP_HOME/marker"
    KUBECONFIG="$first:$other"
    K8S_TEST_TARGET="$other"
    K8S_TEST_SCENARIO="$scenario"
    if run_tool use work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'stale chain must fail switching'; fi
    # Drift in an untouched file can also change the substituted merged view;
    # its semantic verifier then refuses before the next fingerprint recheck.
    case "$(<"$TMP_HOME/stderr")" in
    *'changed since it was read'* | *'context switching changed unrelated configuration'*) ;;
    *) fail 'whole chain drift must be refused before publication' ;;
    esac
    assert_same_file "$first" "$TMP_HOME/before-first" 'untouched member drift must block target publication'
    assert_config_expr "$other" '.contexts[0].context.namespace == "newer-external" and .["current-context"] == "newer-external"'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'stale state must not claim success'
    assert_no_artifacts
  done
}

@test "use already-current rechecks plan-time external edits instead of reporting an obsolete no-op" {
  seed_basic "$KUBECONFIG" work cluster user work
  K8S_TEST_TARGET="$KUBECONFIG"
  K8S_TEST_SCENARIO=stale-use-plan
  install_failure_wrappers
  if run_tool use work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'stale no-op must fail'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'changed since it was read' 'no-op must not bypass stale-state checks'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'stale no-op must not report success'
  assert_config_expr "$KUBECONFIG" '.["current-context"] == "newer-external"'
  assert_no_artifacts
}

@test "use semantic verifier refuses an unrelated visible context change" {
  seed_basic "$KUBECONFIG" work cluster user previous
  cp "$KUBECONFIG" "$TMP_HOME/before"
  if run_module_script '
    k8s_profile_init
    k8s_profile_snapshot_chain
    k8s_profile_plan_use work
    k8s_profile_stage_use
    k8s_profile_write_config "$K8S_PROFILE_TMP_DIR/corrupt.json" "private corruption failed" '\''.contexts[0].context.namespace = "corrupt"'\'' "${K8S_PROFILE_TX_CANDIDATES[0]}"
    cp -- "$K8S_PROFILE_TMP_DIR/corrupt.json" "${K8S_PROFILE_TX_CANDIDATES[0]}"
    k8s_profile_tx_commit k8s_profile_verify_use
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'schema-valid unrelated edit must fail verification'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'context switching changed unrelated configuration' 'merged semantic verifier must reject unrelated edits'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'unrelated edit must never reach live state'
  assert_no_artifacts
}

@test "use raw physical verifier refuses Token changes hidden by identical redacted merged views" {
  seed_basic "$KUBECONFIG" work cluster user previous
  cp "$KUBECONFIG" "$TMP_HOME/before"
  if run_module_script '
    k8s_profile_init
    k8s_profile_snapshot_chain
    k8s_profile_plan_use work
    k8s_profile_stage_use
    k8s_profile_write_config "$K8S_PROFILE_TMP_DIR/corrupt.json" "private corruption failed" '\''.users[0].user.token = "private-corruption"'\'' "${K8S_PROFILE_TX_CANDIDATES[0]}"
    cp -- "$K8S_PROFILE_TMP_DIR/corrupt.json" "${K8S_PROFILE_TX_CANDIDATES[0]}"
    k8s_profile_tx_commit k8s_profile_verify_use
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'raw Token edit must fail physical verification'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'context switching changed unrelated physical configuration' 'redacted projection must not hide credential corruption'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'corrupt Token must never reach live state'
  assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'raw verifier must keep credentials private'
  assert_no_artifacts
}

@test "use debug inherited xtrace and allexport keep existing URL and Token secrets out of argv env and output" {
  seed_basic "$KUBECONFIG" work cluster user previous
  "$K8S_TEST_REAL_JQ" --rawfile token "$TMP_HOME/sentinel" '
    .clusters[0].cluster.server = ("https://user:" + $token + "@api.invalid?token=" + $token + "#" + $token)
  ' "$KUBECONFIG" >"$TMP_HOME/secret-server.json"
  mv "$TMP_HOME/secret-server.json" "$KUBECONFIG"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  install_environment_audit_wrappers
  k8s_test_env bash -ax "$TOOL" --debug use work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  if grep -F -q -f "$TMP_HOME/sentinel" "$TMP_HOME/audit" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then
    fail 'switching leaked credentials through argv env or output'
  fi
  assert_contains "$(<"$TMP_HOME/stderr")" '[k8s-profile]' 'safe debug remains useful'
  assert_not_contains "$(<"$TMP_HOME/stdout")" '[k8s-profile]' 'debug belongs on stderr'
  assert_config_expr "$KUBECONFIG" '. == ($before[0] | .["current-context"] = "work")' --slurpfile before "$TMP_HOME/before.json"
  assert_no_artifacts
}
