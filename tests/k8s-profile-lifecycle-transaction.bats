#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets the isolated environment for every test.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers/k8s-profile.bash.

load 'helpers/k8s-profile'

@test "update staging copy permission jq validation and publication failures leave original bytes with private diagnostics" {
  local scenario
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  install_failure_wrappers
  for scenario in jq-fail copy-fail chmod-fail validation-fail publish-fail; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_CP" "$KUBECONFIG" "$TMP_HOME/before"
    K8S_TEST_SCENARIO="$scenario"
    if update_profile 1 https://not-published.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'injected update failure must fail'; fi
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'returned update failure must preserve or restore original bytes'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed update must not claim success'
    assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'raw command diagnostics must remain private'
    assert_no_artifacts
  done
}

@test "delete staging jq copy permission validation and publication failures preserve the current profile" {
  local scenario
  install_failure_wrappers
  for scenario in delete-stage-fail copy-fail chmod-fail validation-fail publish-fail; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_CP" "$KUBECONFIG" "$TMP_HOME/before"
    K8S_TEST_SCENARIO="$scenario"
    if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'injected deletion failure must fail'; fi
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'returned deletion failure must preserve or restore current profile bytes'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed deletion must not claim complete cleanup'
    assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'deletion diagnostics must not dump credentials'
    assert_no_artifacts
  done
}

@test "post-publication real kubectl verification failure rolls back both lifecycle actions" {
  local action
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  install_failure_wrappers
  for action in update delete; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_CP" "$KUBECONFIG" "$TMP_HOME/before"
    rm -f "$TMP_HOME/counter"
    K8S_TEST_SCENARIO=verify-fail
    if [ "$action" = update ]; then
      if update_profile 1 https://not-published.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'failed post-update verification must fail'; fi
    else
      if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'failed post-delete verification must fail'; fi
    fi
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'post-publication verifier failure must restore prior bytes'
    assert_contains "$(<"$TMP_HOME/stderr")" 'Previous configuration restored.' 'returned complete recovery must be accurately reported'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'post-publication failure must not claim success'
    assert_no_artifacts
  done
}

@test "both lifecycle selections detect stale and disappeared contexts before offering subsequent mutation prompts" {
  local action scenario
  install_failure_wrappers
  for action in update delete; do
    for scenario in stale-selection disappeared-selection; do
      seed_basic "$KUBECONFIG" work cluster user work
      rm -f "$TMP_HOME/marker"
      K8S_TEST_TARGET="$KUBECONFIG"
      K8S_TEST_SCENARIO="$scenario"
      if printf '1\n3\nyes\n' | run_tool "$action" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'stale selected context must fail'; fi
      assert_contains "$(<"$TMP_HOME/stderr")" 'changed since it was read' 'selection must recheck the full snapshot'
      assert_not_contains "$(<"$TMP_HOME/stderr")" 'Select field' 'stale selection must not proceed to editing'
      assert_not_contains "$(<"$TMP_HOME/stderr")" 'Review Profile Deletion' 'stale selection must not offer outdated cleanup consent'
      assert_eq "$(<"$TMP_HOME/stdout")" '' 'stale selection must not claim completion'
      if [ "$scenario" = stale-selection ]; then
        assert_config_expr "$KUBECONFIG" '.contexts[0].context.namespace == "newer-external"'
      else
        assert_config_expr "$KUBECONFIG" '(.contexts // [] | length) == 0'
      fi
      assert_no_artifacts
    done
  done
}

@test "no-op Done still rechecks changes made during the final field prompt instead of reporting an obsolete success" {
  seed_basic "$KUBECONFIG" work cluster user work
  K8S_TEST_TARGET="$KUBECONFIG"
  if printf '1\n' | run_module_script '
    k8s_profile_prompt_update_field() {
      "$K8S_TEST_REAL_JQ" '\''.contexts[0].context.namespace = "newer-external"'\'' "$K8S_TEST_TARGET" >"$K8S_TEST_TARGET.external"
      "$K8S_TEST_REAL_MV" -fT -- "$K8S_TEST_TARGET.external" "$K8S_TEST_TARGET"
      printf "4\n"
    }
    k8s_profile_update
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'stale no-op Done must not claim success'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'changed since it was read' 'even a no-op must recheck after prompts'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'stale no-op must not report unchanged state'
  assert_config_expr "$KUBECONFIG" '.contexts[0].context.namespace == "newer-external"'
  assert_no_artifacts
}

@test "delete rechecks state changed during consent and never publishes the old cleanup plan" {
  seed_basic "$KUBECONFIG" work cluster user work
  K8S_TEST_TARGET="$KUBECONFIG"
  if printf '1\n' | run_module_script '
    k8s_profile_prompt_delete_confirmation() {
      "$K8S_TEST_REAL_JQ" '\''.contexts[0].context.namespace = "newer-external" | .["current-context"] = "newer-external"'\'' "$K8S_TEST_TARGET" >"$K8S_TEST_TARGET.external"
      "$K8S_TEST_REAL_MV" -fT -- "$K8S_TEST_TARGET.external" "$K8S_TEST_TARGET"
      printf "yes\n"
    }
    k8s_profile_delete
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'configuration changed during consent must reject deletion'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'changed since it was read' 'confirmation must not authorize stale cleanup'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'stale consent must not claim success'
  assert_config_expr "$KUBECONFIG" '.contexts[0].context.namespace == "newer-external" and .["current-context"] == "newer-external"'
  assert_no_artifacts
}

@test "update and delete planners cannot overwrite concurrent changes even in an otherwise untouched physical member" {
  local action other="$HOME/other/config"
  install_failure_wrappers
  for action in update delete; do
    seed_split_owned
    seed_basic "$other" neighbour neighbour-cluster neighbour-user
    KUBECONFIG="$KUBECONFIG:$other"
    rm -f "$TMP_HOME/marker"
    K8S_TEST_TARGET="$other"
    if [ "$action" = update ]; then
      K8S_TEST_SCENARIO=stale-unaffected
      if update_profile 2 https://not-published.invalid >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'stale non-write member must reject update'; fi
    else
      K8S_TEST_SCENARIO=stale-delete-plan
      if delete_profile 2 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'stale non-write member must reject delete'; fi
    fi
    assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'newer unrelated member must prevent target publication'
    assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'stale chain must prevent orphan cleanup'
    assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'stale chain must preserve authentication'
    assert_config_expr "$other" '.contexts[0].context.namespace == "newer-external"'
    assert_no_artifacts
  done
}

@test "real candidate validation rechecks concurrent live edits for both lifecycle commands" {
  local action
  install_failure_wrappers
  for action in update delete; do
    seed_basic "$KUBECONFIG" work cluster user work
    K8S_TEST_TARGET="$KUBECONFIG"
    K8S_TEST_SCENARIO=stale-validation
    if [ "$action" = update ]; then
      if update_profile 1 https://not-published.invalid >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'live validation edit must reject update'; fi
    else
      if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'live validation edit must reject delete'; fi
    fi
    assert_config_expr "$KUBECONFIG" '.contexts[0].context.namespace == "newer-external" and .["current-context"] == "newer-external" and (.contexts | length) == 1'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'live drift must not produce a success message'
    assert_no_artifacts
  done
}

@test "both lifecycle actions reject candidate changes permissions and post-chain validation drift before publication" {
  local action scenario
  install_failure_wrappers
  for action in update delete; do
    for scenario in changed-candidate candidate-permission candidate-after-chain; do
      seed_basic "$KUBECONFIG" work cluster user work
      "$K8S_TEST_REAL_CP" "$KUBECONFIG" "$TMP_HOME/before"
      K8S_TEST_SCENARIO="$scenario"
      if [ "$action" = update ]; then
        if update_profile 1 https://not-published.invalid >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'changed candidate must reject update'; fi
      else
        if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'changed candidate must reject delete'; fi
      fi
      assert_contains "$(<"$TMP_HOME/stderr")" 'candidate' 'candidate integrity failure must be controlled'
      assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'candidate drift must never reach the live file'
      assert_no_artifacts
    done
  done
}

@test "whole split update write-set is preflighted before any changed resources are published" {
  seed_split_owned
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  chmod 777 "$HOME/cluster"
  if update_profile 1 https://not-published.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'unsafe split cleanup must block update'; fi
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'unsafe cleanup must block selected context publication'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'unsafe cluster cleanup origin must retain bytes'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'other credentials must retain bytes'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'preflight failure must not claim update success'
  assert_no_artifacts
}

@test "delete verifier rejects a schema-valid candidate that changes an unrelated visible context" {
  seed_basic "$KUBECONFIG" work cluster user neighbour
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=cluster --user=user --namespace=kept >/dev/null
  cp "$KUBECONFIG" "$TMP_HOME/before"
  if run_module_script '
    k8s_profile_init
    k8s_profile_snapshot_chain
    k8s_profile_plan_delete work
    k8s_profile_stage_delete
    k8s_profile_write_config "$K8S_PROFILE_TMP_DIR/corrupt.json" "private candidate edit failed" '\''(.contexts[] | select(.name == "neighbour")).context.namespace = "corrupt-private-candidate"'\'' "${K8S_PROFILE_TX_CANDIDATES[0]}"
    cp -- "$K8S_PROFILE_TMP_DIR/corrupt.json" "${K8S_PROFILE_TX_CANDIDATES[0]}"
    k8s_profile_tx_commit k8s_profile_verify_delete
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'schema validity alone must not approve unrelated deletion edits'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'did not preserve the requested cleanup or current context' 'merged semantic verifier must reject unrelated visible changes'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'semantic verification must fail before publication'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed verifier must not output partial state'
  assert_no_artifacts
}

@test "delete verifier checks hidden physical contexts even when a corrupted candidate has the correct merged projection" {
  local shadow="$HOME/shadow/config"
  seed_split_owned
  "$K8S_TEST_REAL_JQ" '.contexts += [{name:"neighbour",context:{cluster:"missing-visible",user:"missing-visible",namespace:"visible-kept"}}]' "$HOME/context/config" >"$TMP_HOME/context-extra.json"
  mv "$TMP_HOME/context-extra.json" "$HOME/context/config"
  write_fixture "$shadow" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"neighbour","context":{"cluster":"missing-hidden","user":"missing-hidden","namespace":"hidden-kept"}}],"clusters":[{"name":"k8s-profile:work:cluster:9","cluster":{"server":"https://orphan.invalid","extensions":[{"name":"picotools.k8s-profile","extension":{"version":1,"profile":"work","role":"cluster"}}]}}]}
EOF
  cp "$HOME/context/config" "$TMP_HOME/before-context"
  cp "$shadow" "$TMP_HOME/before-shadow"
  KUBECONFIG="$KUBECONFIG:$shadow"
  if run_module_script '
    k8s_profile_init
    k8s_profile_snapshot_chain
    k8s_profile_plan_delete work
    k8s_profile_stage_delete
    k8s_profile_write_config "$K8S_PROFILE_TMP_DIR/corrupt.json" "private candidate edit failed" '\''.contexts[0].context.namespace = "corrupt-private-candidate"'\'' "${K8S_PROFILE_TX_CANDIDATES[3]}"
    cp -- "$K8S_PROFILE_TMP_DIR/corrupt.json" "${K8S_PROFILE_TX_CANDIDATES[3]}"
    k8s_profile_tx_commit k8s_profile_verify_delete
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'correct merged projection must not hide unrelated physical changes'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'changed unrelated physical configuration' 'private per-file verifier must cover hidden definitions'
  assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'hidden physical edit must never be published'
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'all candidate files must remain unpublished on verification failure'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'semantic verification failure must preserve source clusters'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'semantic verification failure must preserve credentials'
  assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'semantic verifier errors must not dump raw configurations'
  assert_no_artifacts
}

@test "pre-existing cross-file locks prevent lifecycle writes and remain untouched while acquired locks are cleaned" {
  local action lock="$HOME/user/config.lock"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  for action in update delete; do
    seed_split_owned
    printf 'foreign-lock-owner' >"$lock"
    if [ "$action" = update ]; then
      if update_profile 1 https://not-published.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'foreign lock must prevent update'; fi
    else
      if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'foreign lock must prevent delete'; fi
    fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'lock is unavailable' 'cooperative lock must block the whole write-set'
    assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'blocked lock must prevent selected context writes'
    assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'blocked lock must prevent resource cleanup'
    assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'blocked credential origin must retain bytes'
    assert_eq "$(<"$lock")" foreign-lock-owner 'cleanup must not remove or rewrite a pre-existing lock'
    assert_no_artifacts true
    assert_file_not_exists "$HOME/context/config.lock" 'our earlier acquired locks must be released'
    assert_file_not_exists "$HOME/cluster/config.lock" 'our earlier resource lock must be released'
    rm "$lock"
  done
}

@test "split update second publication failure restores every already-published member and its hidden current state" {
  seed_split_owned
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  K8S_TEST_SCENARIO=second-publish-fail
  install_failure_wrappers
  if update_profile 1 https://not-published.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'second update publication must fail'; fi
  assert_eq "$(<"$TMP_HOME/counter")" 2 'failure must occur at the second actual publication'
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'earlier published update file must roll back'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'failed publication must retain original cluster'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'unattempted user file must retain bytes'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Previous configuration restored.' 'full recovery must be reported accurately'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'recovered update failure must not report success'
  assert_no_artifacts
}

@test "split delete second publication failure restores low-precedence credentials and every original current reference" {
  seed_split_owned
  K8S_TEST_SCENARIO=second-publish-fail
  install_failure_wrappers
  if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'second deletion publication must fail'; fi
  assert_eq "$(<"$TMP_HOME/counter")" 2 'delete must exercise a second actual publication'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'first low-precedence credential cleanup must roll back'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'failed second cleanup must preserve its hidden current reference'
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'unattempted high-precedence context must retain bytes'
  assert_config_expr '' '.["current-context"] == "work"'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'partial delete must never be reported as complete'
  assert_no_artifacts
}

@test "handled TERM after the second multi-file update rename restores every attempted member" {
  seed_split_owned
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  K8S_TEST_SCENARIO=signal-second-publish
  install_failure_wrappers
  if update_profile 1 https://not-published.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'handled update TERM must fail'; fi
  assert_eq "$(<"$TMP_HOME/counter")" 2 'TERM must arrive after a second actual rename'
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'first update member must be restored on TERM'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'just-renamed second member must be restored before bookkeeping'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'unattempted third member must be preserved'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'handled TERM must not claim success'
  assert_no_artifacts
}

@test "handled TERM after the second low-precedence delete rename restores all credentials and current values" {
  seed_split_owned
  K8S_TEST_SCENARIO=signal-second-publish
  install_failure_wrappers
  if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'handled deletion TERM must fail'; fi
  assert_eq "$(<"$TMP_HOME/counter")" 2 'TERM must arrive after the second low-precedence publication'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'first cleaned credential origin must roll back'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'second origin and hidden current value must roll back'
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'high-precedence current and selected context must remain untouched'
  assert_config_expr '' '.["current-context"] == "work"'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'interrupted delete must not claim cleanup success'
  assert_no_artifacts
}

@test "newer external edit during multi-file update recovery is preserved with private evidence instead of being overwritten" {
  local recovery
  seed_split_owned
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  K8S_TEST_SCENARIO=newer-recovery
  install_failure_wrappers
  if update_profile 1 https://not-published.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'incomplete update recovery must fail'; fi
  assert_config_expr "$HOME/context/config" '.contexts[0].context.namespace == "newer-external"'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'failed second publication must preserve cluster origin'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'unattempted authentication origin must retain bytes'
  assert_contains "$(<"$TMP_HOME/stderr")" 'recovery incomplete' 'newer edit must not be called fully restored'
  recovery=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'k8s-profile.*')
  assert_mode "$recovery" 700 'retained raw recovery workspace must be private'
  assert_mode "$recovery/backup-0" 600 'retained original credentials must be private'
  assert_mode "$recovery/recovery.json" 600 'retained recovery manifest must be private'
  "$K8S_TEST_REAL_JQ" -e '.version == 1 and (.files | length) == 2' "$recovery/recovery.json" >/dev/null
  if grep -F -q -f "$TMP_HOME/sentinel" -f "$TMP_HOME/replacement" "$recovery/recovery.json" "$TMP_HOME/stdout" "$TMP_HOME/stderr" "$TMP_HOME/audit"; then fail 'incomplete recovery leaked Token contents'; fi
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'incomplete update recovery must not report success'
  [ -z "$(find "$HOME" \( -name '.k8s-profile.*' -o -name '*.lock' \) -print)" ]
}

@test "newer low-precedence edit during failed deletion recovery is preserved and partial cleanup is never called complete" {
  local recovery
  seed_split_owned
  K8S_TEST_TARGET="$HOME/user/config"
  K8S_TEST_SCENARIO=newer-recovery
  install_failure_wrappers
  if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'incomplete deletion recovery must fail'; fi
  assert_config_expr "$HOME/user/config" '.["current-context"] == "newer-external" and .preferences.extensions[0].name == "newer-external" and (.users // [] | length) == 0'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'failed second publication must retain cluster and hidden current bytes'
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'unattempted selected context must not be deleted'
  assert_config_expr '' '.["current-context"] == "work"'
  assert_contains "$(<"$TMP_HOME/stderr")" 'recovery incomplete' 'a preserved newer edit must not be overwritten or reported as full recovery'
  assert_not_contains "$(<"$TMP_HOME/stderr")" 'Previous configuration restored.' 'incomplete credential recovery must not be called complete'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'partial deletion must not report success'
  recovery=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'k8s-profile.*')
  assert_mode "$recovery" 700 'retained raw workspace must remain private'
  assert_mode "$recovery/backup-2" 600 'original inline Token backup must remain private'
  assert_mode "$recovery/recovery.json" 600 'manifest must remain private'
  "$K8S_TEST_REAL_JQ" -e '.version == 1 and (.files | length) == 2 and .files[0].path == $path' --arg path "$HOME/user/config" "$recovery/recovery.json" >/dev/null
  if grep -F -q -f "$TMP_HOME/sentinel" "$recovery/recovery.json" "$TMP_HOME/stdout" "$TMP_HOME/stderr" "$TMP_HOME/audit"; then fail 'partial deletion recovery leaked Token contents'; fi
  [ -z "$(find "$HOME" \( -name '.k8s-profile.*' -o -name '*.lock' \) -print)" ]
}

@test "update and delete keep existing and replacement credentials out of argv environment streams and inherited xtrace" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  "$K8S_TEST_REAL_JQ" --rawfile token "$TMP_HOME/sentinel" '
    .clusters[0].cluster.server = ("https://user:" + $token + "@api.invalid?token=" + $token + "#" + $token)
  ' "$KUBECONFIG" >"$TMP_HOME/secret-server.json"
  mv "$TMP_HOME/secret-server.json" "$KUBECONFIG"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  install_failure_wrappers
  {
    printf '1\n2\n2\n'
    builtin printf '%s\n' "$(<"$TMP_HOME/replacement")"
    printf '4\n'
  } | k8s_test_env env k8s_profile_token_value=public-inherited k8s_profile_private_server=public-inherited bash -x "$TOOL" --debug update >"$TMP_HOME/update-stdout" 2>"$TMP_HOME/update-stderr"
  printf '1\nyes\n' | k8s_test_env bash -x "$TOOL" --debug delete >"$TMP_HOME/delete-stdout" 2>"$TMP_HOME/delete-stderr"
  if grep -F -q -f "$TMP_HOME/sentinel" -f "$TMP_HOME/replacement" "$TMP_HOME/audit" "$TMP_HOME/update-stdout" "$TMP_HOME/update-stderr" "$TMP_HOME/delete-stdout" "$TMP_HOME/delete-stderr"; then
    fail 'lifecycle command leaked existing URL or Token data across a public/process boundary'
  fi
  assert_contains "$(<"$TMP_HOME/update-stderr")" '[k8s-profile]' 'debug must remain useful without xtrace'
  assert_contains "$(<"$TMP_HOME/delete-stderr")" '[k8s-profile]' 'delete debug must use controlled nonsecret messages'
  assert_not_contains "$(<"$TMP_HOME/update-stdout")$(<"$TMP_HOME/delete-stdout")" '[k8s-profile]' 'debug and UI must stay on stderr'
  assert_contains "$(tr '\000' ' ' <"$TMP_HOME/audit")" 'token-mode:600' 'replacement Token input must remain private'
  assert_no_artifacts
}

@test "failed builtin replacement Token write rejects every pending update field and cleans the partial secret" {
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  if {
    printf '1\n1\nhttps://not-published.invalid\n2\n2\n'
    builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
    printf '4\n'
  } | run_module_script '
    builtin() {
      if [ "$1" = printf ] && [ "${2:-}" = "%s" ]; then
        command builtin printf "partial-private-token"
        command builtin printf "%s" "$(<"$K8S_TEST_SENTINEL_FILE")" >&2
        return 1
      fi
      command builtin "$@"
    }
    k8s_profile_update
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'failed replacement Token write must fail update'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'unable to write private Token input' 'update must use the guarded Token persistence boundary'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'failed Token input must not publish the pending Server'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed replacement must not claim update success'
  assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'Token write errors must remain private'
  assert_no_artifacts
}
