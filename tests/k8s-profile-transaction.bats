#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets the isolated environment for every test.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers/k8s-profile.bash.

load 'helpers/k8s-profile'

@test "transaction locks interoperate with real kubectl cooperative writers" {
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  run_module_script '
    k8s_profile_init
    k8s_profile_snapshot_chain
    k8s_profile_tx_add_file 0
    k8s_profile_tx_prepare
    if "$K8S_TEST_REAL_KUBECTL" config set-context blocked --cluster=external-cluster --user=external-user >"$K8S_PROFILE_TMP_DIR/blocked-output" 2>"$K8S_PROFILE_TMP_DIR/blocked-error"; then
      exit 9
    fi
  '
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'real kubectl must respect the owned cooperative lock'
  assert_no_artifacts
}

@test "generic transaction supports ordered multi-file candidates without a merged raw replacement" {
  local first="$HOME/first/config" second="$HOME/second/config"
  seed_basic "$first" first first-cluster first-user first
  seed_basic "$second" second second-cluster second-user second
  KUBECONFIG="$first:$second"
  run_module_script '
    k8s_profile_init
    k8s_profile_snapshot_chain
    k8s_profile_tx_add_file 1
    k8s_profile_tx_add_file 0
    k8s_profile_tx_prepare
    for index in "${K8S_PROFILE_TX_WRITE_SET[@]}"; do
      k8s_profile_write_config "$K8S_PROFILE_TMP_DIR/edited-$index.json" "unable to stage generic transaction" '\''.["current-context"] = ""'\'' "${K8S_PROFILE_CHAIN_RAW[$index]}"
      cp -- "$K8S_PROFILE_TMP_DIR/edited-$index.json" "${K8S_PROFILE_TX_CANDIDATES[$index]}"
    done
    k8s_profile_tx_commit
  '
  assert_config_expr "$first" '(.contexts | length) == 1 and .contexts[0].name == "first" and (.["current-context"] // "") == ""'
  assert_config_expr "$second" '(.contexts | length) == 1 and .contexts[0].name == "second" and (.["current-context"] // "") == ""'
  assert_config_expr '' '(.["current-context"] // "") == "" and (.contexts | length) == 2'
  assert_no_artifacts
}

@test "create overwrite engine keeps exact external identities including quoted newline and empty names" {
  local name
  for name in $'--external "quote":/\n' ''; do
    seed_basic "$KUBECONFIG" "$name" actual-cluster actual-user "$name"
    # seed_basic defaults an omitted/empty context; set an explicit empty name
    # through JSON to exercise the same exact-identity engine used by K8S-03.
    "$K8S_TEST_REAL_JQ" --arg name "$name" '.contexts[0].name = $name | .["current-context"] = $name' "$KUBECONFIG" >"$TMP_HOME/named.json"
    mv "$TMP_HOME/named.json" "$KUBECONFIG"
    run_module_script '
      k8s_profile_init
      k8s_profile_snapshot_chain
      k8s_profile_profile_name 1 name
      k8s_profile_plan_change "$name" "https://replacement.invalid:6443" true true
      cp -- "$K8S_TEST_SENTINEL_FILE" "$K8S_PROFILE_TMP_DIR/token-input"
      chmod 600 "$K8S_PROFILE_TMP_DIR/token-input"
      k8s_profile_stage_change "$K8S_PROFILE_TMP_DIR/token-input"
      k8s_profile_tx_commit k8s_profile_verify_change
      k8s_profile_validate_ownership
    '
    assert_config_expr "$KUBECONFIG" '
      .contexts[0].name == $name and .["current-context"] == $name and .contexts[0].context.namespace == "kept" and
      any(.contexts[0].context.extensions[]; .name == "picotools.k8s-profile" and .extension.profile == $name and .extension.role == "context")
    ' --arg name "$name"
    assert_no_artifacts
  done
}

@test "candidate jq copy chmod and kubectl validation failures publish nothing and clean private state" {
  local scenario
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  install_failure_wrappers
  for scenario in jq-fail copy-fail chmod-fail validation-fail; do
    K8S_TEST_SCENARIO="$scenario"
    if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'injected candidate failure should fail create'; fi
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'candidate failure must leave original bytes'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'candidate failure must not report partial success'
    assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'injected diagnostics must remain private'
    assert_no_artifacts
  done
}

@test "existing target publication failure leaves original bytes and releases only owned locks" {
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  K8S_TEST_SCENARIO=publish-fail
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'publication failure should fail create'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'Previous configuration restored.' 'complete recovery should be reported'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'publication failure must preserve old bytes'
  assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'publication diagnostics must not leak Token'
  assert_no_artifacts
}

@test "missing target publication failure leaves no config directories Token stages or locks" {
  K8S_TEST_SCENARIO=publish-fail
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'missing target publication failure should fail'; fi
  assert_file_not_exists "$KUBECONFIG" 'failed new publication must not create config'
  [ ! -d "$HOME/.kube" ]
  assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'new publication diagnostics must remain private'
  assert_no_artifacts
}

@test "post-publication kubectl verification failure restores an existing config" {
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  K8S_TEST_SCENARIO=verify-fail
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'post-publication verification failure should fail'; fi
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'post-publication failure should recover original bytes'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Previous configuration restored.' 'successful recovery should be reported'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'failure after registration must not claim success'
  assert_no_artifacts
}

@test "post-publication verification failure removes a newly created config" {
  K8S_TEST_SCENARIO=verify-fail
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'post-publication verification failure should fail'; fi
  assert_file_not_exists "$KUBECONFIG" 'rollback must remove our newly created config'
  assert_no_artifacts
}

@test "chain snapshot detects edits after prompts before staging without overwriting them" {
  seed_basic "$KUBECONFIG"
  K8S_TEST_TARGET="$KUBECONFIG"
  K8S_TEST_SCENARIO=stale-plan
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'stale prompt snapshot should fail'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'changed since it was read' 'stale state should tell the user to retry'
  assert_config_expr "$KUBECONFIG" '.contexts[0].context.namespace == "newer-external" and (.contexts | length) == 1'
  assert_no_artifacts
}

@test "chain snapshot also detects newer edits in an unaffected physical member" {
  local first="$HOME/one/config" other="$HOME/two/config"
  seed_basic "$first" first first-cluster first-user
  seed_basic "$other" second second-cluster second-user
  cp "$first" "$TMP_HOME/before-first"
  KUBECONFIG="$first:$other"
  K8S_TEST_TARGET="$other"
  K8S_TEST_SCENARIO=stale-unaffected
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'changed non-write chain member should fail'; fi
  assert_same_file "$first" "$TMP_HOME/before-first" 'stale unaffected member must prevent target publication'
  assert_config_expr "$other" '.contexts[0].context.namespace == "newer-external"'
  assert_no_artifacts
}

@test "rechecking around staging detects live edits during real kubectl candidate validation" {
  seed_basic "$KUBECONFIG"
  K8S_TEST_TARGET="$KUBECONFIG"
  K8S_TEST_SCENARIO=stale-validation
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'changed live state during validation should fail'; fi
  assert_config_expr "$KUBECONFIG" '.contexts[0].context.namespace == "newer-external" and (.contexts | length) == 1'
  assert_not_contains "$(<"$TMP_HOME/stdout")" 'Saved profile' 'stale staging must not claim success'
  assert_no_artifacts
}

@test "a candidate changed during validation is not published" {
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  K8S_TEST_SCENARIO=changed-candidate
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'changed candidate should fail'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'candidate changed during validation' 'candidate integrity must be checked'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'changed private stage must not reach live state'
  assert_no_artifacts
}

@test "candidate permission drift and edits after substituted-chain validation prevent publication" {
  local scenario
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  install_failure_wrappers
  for scenario in candidate-permission candidate-after-chain; do
    K8S_TEST_SCENARIO="$scenario"
    if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'candidate drift must fail'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'candidate' 'candidate integrity failure should be explicit'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'candidate drift must not publish anything'
    assert_no_artifacts
  done
}

@test "all multi-file cleanup targets are preflighted before any candidate is published" {
  seed_split_owned
  chmod 777 "$HOME/cluster"
  if create_profile work https://replacement.invalid:6443 yes >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'unsafe cleanup origin must fail'; fi
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'unsafe cleanup origin must prevent context publication'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'unsafe cleanup origin must retain bytes'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'unaffected cleanup origin must retain bytes'
  assert_contains "$(<"$TMP_HOME/stderr")" 'group/world writable' 'whole write-set preflight should be explicit'
  assert_no_artifacts
}

@test "multi-file second publication failure restores every earlier published file" {
  seed_split_owned
  K8S_TEST_SCENARIO='second-publish-fail'
  install_failure_wrappers
  if create_profile work https://replacement.invalid:6443 yes >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'second publication should fail'; fi
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'first published context file must roll back'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'failed cluster publication must preserve original'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'unattempted user publication must preserve original'
  assert_config_expr '' '.["current-context"] == "work"'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Previous configuration restored.' 'full multi-file recovery should be reported'
  assert_no_artifacts
}

@test "newer external edits during failed multi-file recovery are preserved with private recovery evidence" {
  local recovery
  seed_split_owned
  K8S_TEST_SCENARIO=newer-recovery
  install_failure_wrappers
  if create_profile work https://replacement.invalid:6443 yes >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'newer-edit recovery should fail'; fi
  assert_config_expr "$HOME/context/config" '.contexts[0].context.namespace == "newer-external"'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'failed second publication must preserve cluster file'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'unattempted member must retain bytes'
  assert_contains "$(<"$TMP_HOME/stderr")" 'recovery incomplete' 'incomplete recovery must not be called successful'
  recovery=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'k8s-profile.*')
  [ -n "$recovery" ]
  assert_mode "$recovery" 700 'retained backup directory must be private'
  assert_mode "$recovery/backup-0" 600 'retained raw backup must be private'
  assert_mode "$recovery/recovery.json" 600 'recovery manifest must be private'
  if grep -F -q -f "$TMP_HOME/sentinel" "$recovery/recovery.json" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'recovery evidence must not expose credential content'; fi
  "$K8S_TEST_REAL_JQ" -e '.version == 1 and (.files | length) == 2' "$recovery/recovery.json" >/dev/null
  assert_file_not_exists "$HOME/context/config.lock" 'owned locks must be released even for retained recovery'
  [ -z "$(find "$HOME" -name '.k8s-profile.*' -print)" ]
}

@test "recovery keeps a builtin nonsecret manifest even if jq fails while writing JSON evidence" {
  local recovery
  seed_split_owned
  K8S_TEST_SCENARIO=newer-recovery-manifest-fail
  install_failure_wrappers
  if create_profile work https://replacement.invalid:6443 yes >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'incomplete recovery must fail'; fi
  assert_config_expr "$HOME/context/config" '.contexts[0].context.namespace == "newer-external"'
  recovery=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'k8s-profile.*')
  assert_mode "$recovery/recovery.txt" 600 'builtin fallback manifest should remain private'
  assert_file_not_exists "$recovery/recovery.json" 'failed partial JSON manifest should not be retained as evidence'
  if grep -F -q -f "$TMP_HOME/sentinel" "$recovery/recovery.txt" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'fallback evidence must not contain Token bytes'; fi
  assert_contains "$(<"$recovery/recovery.txt")" 'path=' 'fallback should contain usable recovery paths'
  assert_file_not_exists "$HOME/context/config.lock" 'fallback recovery must release owned locks'
}

@test "atomic no-replace publication preserves a concurrently created missing target" {
  local recovery
  K8S_TEST_SCENARIO=missing-race
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'new target race must fail'; fi
  assert_config_expr "$KUBECONFIG" '.contexts[0].name == "newer-external" and (.contexts | length) == 1'
  assert_contains "$(<"$TMP_HOME/stderr")" 'recovery incomplete' 'ambiguous publication must retain recovery information'
  recovery=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'k8s-profile.*')
  assert_file_exists "$recovery/recovery.json" 'ambiguous no-replace race should keep a nonsecret manifest'
  assert_file_not_exists "$KUBECONFIG.lock" 'owned lock must be released after no-replace failure'
}

@test "handled TERM after rename restores an existing file before exiting" {
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  K8S_TEST_SCENARIO=signal-publish
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'handled TERM must fail the operation'; fi
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'TERM between rename and bookkeeping must restore old bytes'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'handled signal must not claim success'
  assert_no_artifacts
}

@test "handled TERM after no-replace link removes only our newly published config" {
  K8S_TEST_SCENARIO=signal-publish
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'handled TERM must fail the operation'; fi
  assert_file_not_exists "$KUBECONFIG" 'TERM between link and bookkeeping must remove our target'
  assert_no_artifacts
}

@test "handled TERM while acquiring a lock releases the just-created owned lock" {
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  K8S_TEST_SCENARIO=signal-lock
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'lock acquisition TERM should fail'; fi
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'lock acquisition signal must not change config'
  assert_no_artifacts
}

@test "a replaced cooperative lock is preserved and its lost lease prevents successful publication" {
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  K8S_TEST_SCENARIO=replace-lock
  install_failure_wrappers
  if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'lost lock lease should fail'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'lock changed during the transaction' 'lost lock should be detected'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'lost lease must roll back our publication'
  assert_eq "$(<"$KUBECONFIG.lock")" newer-lock-owner 'cleanup must never remove or overwrite a replacement lock'
  assert_no_artifacts true
}
