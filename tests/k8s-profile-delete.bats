#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets the isolated environment for every test.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers/k8s-profile.bash.

load 'helpers/k8s-profile'

@test "delete removes a standalone owned context cluster and inline Token user only after default-no confirmation" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" "Delete 'work'? [y/N]:" 'delete confirmation must be default-no'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Remove eligible owned clusters: 1' 'preview must specify cluster cleanup'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Remove eligible owned users: 1 (inline Tokens included)' 'preview must specify credential cleanup'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Keep shared/unmanaged' 'preview must distinguish retained resources'
  assert_contains "$(<"$TMP_HOME/stdout")" "Deleted profile 'work'." 'success must follow complete publication'
  assert_config_expr "$KUBECONFIG" '
    (.contexts // [] | length) == 0 and (.clusters // [] | length) == 0 and (.users // [] | length) == 0 and
    (.["current-context"] // "") == ""
  '
  assert_mode "$KUBECONFIG" 600 'delete should publish a private kubeconfig, not unlink the external file'
  assert_no_artifacts
}

@test "declined blank invalid incomplete EOF and NUL delete confirmation preserve all bytes and current state" {
  local confirmation
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config use-context work >/dev/null
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for confirmation in $'no\n' $'\n' '' 'yes' $'maybe\n'; do
    if printf '1\n%s' "$confirmation" | run_tool delete >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'unconfirmed deletion must fail'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" "Delete 'work'? [y/N]:" 'every confirmation must remain default-no'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'unconfirmed delete must preserve exact current configuration'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'unconfirmed delete must not claim success'
    assert_no_artifacts
  done
  if printf '1\nyes\000\n' | run_tool delete >/dev/null 2>"$TMP_HOME/stderr"; then fail 'NUL-bearing confirmation must be rejected'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'unsupported NUL character' 'confirmation must not silently discard NUL'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'NUL-bearing confirmation must preserve bytes'
  assert_no_artifacts
}

@test "delete rejects canceled invalid overflowing partial EOF and NUL profile selections before preview or writes" {
  local input
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for input in '' '1' $'\n' $'q\n' $'Q\n' $'0\n' $'2\n' $'-1\n' $'01\n' $'999999999999999999999999999\n'; do
    if printf '%s' "$input" | run_tool delete >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'invalid profile selection must fail'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'Profiles:' 'delete must use the shared authoritative profile menu'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Review Profile Deletion' 'invalid selections must stop before preview/consent'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'invalid selection must preserve bytes'
    assert_no_artifacts
  done
  if printf '1\000\nyes\n' | run_tool delete >/dev/null 2>"$TMP_HOME/stderr"; then fail 'NUL profile selection must be rejected'; fi
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'NUL selection must not choose a context'
  assert_no_artifacts
}

@test "empty authoritative configurations fail update and delete without prompts for fields or creating kubeconfig" {
  local action
  for action in update delete; do
    run run_tool "$action" </dev/null
    [ "$status" -ne 0 ]
    assert_contains "$output" 'No Kubernetes profiles found.' 'empty lifecycle selection must be friendly'
    assert_not_contains "$output" 'Select field:' 'empty update must not offer fields'
    assert_not_contains "$output" 'Delete ' 'empty delete must not request consent'
    assert_file_not_exists "$KUBECONFIG" 'empty lifecycle must not create a file'
    assert_no_artifacts
  done
}

@test "delete external context retains its unmanaged cluster user Token and unrelated configuration" {
  seed_basic "$KUBECONFIG" work real-cluster real-user neighbour
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=real-cluster --user=real-user --namespace=neighbour-kept >/dev/null
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  delete_profile 2 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '
    [.contexts[] | .name] == ["neighbour"] and .clusters == $before[0].clusters and .users == $before[0].users and
    .contexts[0] == ($before[0].contexts[] | select(.name == "neighbour")) and .["current-context"] == "neighbour"
  ' "$TMP_HOME/after.json" >/dev/null
  assert_contains "$(<"$TMP_HOME/stderr")" 'Remove eligible owned clusters: 0' 'unmanaged resource cleanup must be excluded from consent'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Remove eligible owned users: 0' 'unmanaged Token must be retained'
  assert_no_artifacts
}

@test "delete shared explicitly owned resources retains the neighbour and its exact credentials" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=k8s-profile:work:cluster:1 --user=k8s-profile:work:user:1 >/dev/null
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config use-context neighbour >/dev/null
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  delete_profile 2 >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '
    .clusters == $before[0].clusters and .users == $before[0].users and .["current-context"] == "neighbour" and
    .contexts == [$before[0].contexts[] | select(.name == "neighbour")]
  ' "$TMP_HOME/after.json" >/dev/null
  assert_no_artifacts
}

@test "hidden physical context references retain owned resources even when their visible shadow uses different refs" {
  local first="$KUBECONFIG" shadow="$HOME/shadow/config"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=missing-visible --user=missing-visible >/dev/null
  write_fixture "$shadow" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"neighbour","context":{"cluster":"k8s-profile:work:cluster:1","user":"k8s-profile:work:user:1","namespace":"hidden-kept"}}]}
EOF
  cp "$shadow" "$TMP_HOME/before-shadow"
  KUBECONFIG="$first:$shadow"
  delete_profile 2 >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$first" '
    (.contexts | length) == 1 and .contexts[0].name == "neighbour" and
    .clusters[0].name == "k8s-profile:work:cluster:1" and .users[0].name == "k8s-profile:work:user:1" and .users[0].user.token == $token
  ' --rawfile token "$TMP_HOME/sentinel"
  assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'hidden referring context must retain bytes'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Remove eligible owned users: 0' 'all physical references must participate in cleanup approval'
  assert_no_artifacts
}

@test "delete refuses selected context shadows with controlled explicit-file recovery guidance" {
  local first="$HOME/first/config" shadow="$HOME/shadow/config"
  seed_basic "$first" work first-cluster first-user work
  seed_basic "$shadow" work shadow-cluster shadow-user hidden
  cp "$first" "$TMP_HOME/before-first"
  cp "$shadow" "$TMP_HOME/before-shadow"
  KUBECONFIG="$first:$shadow"
  if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'removing a visible context must not resurrect a shadow'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'multiple physical definitions' 'context-shadow conflict must be explicit'
  assert_contains "$(<"$TMP_HOME/stderr")" 'explicit --kubeconfig file' 'conflict must give controlled recovery guidance'
  assert_not_contains "$(<"$TMP_HOME/stderr")" "Delete 'work'?" 'shadow conflict must be rejected before confirmation'
  assert_same_file "$first" "$TMP_HOME/before-first" 'visible context must retain bytes'
  assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'shadow context must retain bytes'
  assert_no_artifacts
}

@test "unambiguous context deletion retains every ambiguous owned resource definition instead of exposing or deleting shadows" {
  local first="$KUBECONFIG" shadow="$HOME/shadow/config"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/before.json" "$first"
  mkdir -p "${shadow%/*}"
  "$K8S_TEST_REAL_JQ" 'del(.contexts) | .["current-context"] = ""' "$first" >"$shadow"
  chmod 600 "$shadow"
  cp "$shadow" "$TMP_HOME/before-shadow"
  KUBECONFIG="$first:$shadow"
  delete_profile >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$first"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '(.contexts // [] | length) == 0 and .clusters == $before[0].clusters and .users == $before[0].users' "$TMP_HOME/after.json" >/dev/null
  assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'ambiguous resource origin must remain untouched'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Remove eligible owned clusters: 0' 'ambiguous owned entries must be excluded from cleanup'
  assert_no_artifacts
}

@test "eligible older owned orphans are cleaned but name-prefix collisions and another profiles orphans are retained" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  "$K8S_TEST_REAL_JQ" '
    .clusters += [{name:"k8s-profile:work:cluster:2",cluster:{server:"https://unmanaged.invalid"}},
      {name:"k8s-profile:work:cluster:3",cluster:{server:"https://orphan.invalid",extensions:[{name:"picotools.k8s-profile",extension:{version:1,profile:"work",role:"cluster"}}]}},
      {name:"k8s-profile:another:cluster:1",cluster:{server:"https://another.invalid",extensions:[{name:"picotools.k8s-profile",extension:{version:1,profile:"another",role:"cluster"}}]}}] |
    .users += [{name:"k8s-profile:work:user:2",user:{}},
      {name:"k8s-profile:work:user:3",user:{extensions:[{name:"picotools.k8s-profile",extension:{version:1,profile:"work",role:"user"}}]}},
      {name:"k8s-profile:another:user:1",user:{extensions:[{name:"picotools.k8s-profile",extension:{version:1,profile:"another",role:"user"}}]}}]
  ' "$KUBECONFIG" >"$TMP_HOME/orphans.json"
  mv "$TMP_HOME/orphans.json" "$KUBECONFIG"
  delete_profile >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '
    (.contexts // [] | length) == 0 and
    [.clusters[].name] == ["k8s-profile:another:cluster:1","k8s-profile:work:cluster:2"] and
    [.users[].name] == ["k8s-profile:another:user:1","k8s-profile:work:user:2"]
  '
  assert_contains "$(<"$TMP_HOME/stderr")" 'Remove eligible owned clusters: 2' 'cleanup includes all eligible older owned orphans'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Remove eligible owned users: 2' 'unmanaged prefixes must not count as owned cleanup'
  assert_no_artifacts
}

@test "delete fails closed on unsupported or name-inconsistent reserved ownership metadata" {
  local mutation
  for mutation in version name role; do
    create_profile work >/dev/null 2>"$TMP_HOME/stderr"
    "$K8S_TEST_REAL_JQ" --arg mutation "$mutation" '
      if $mutation == "version" then .users[0].user.extensions[0].extension.version = 2
      elif $mutation == "name" then .users[0].name = "not-an-owned-name"
      else .users[0].user.extensions[0].extension.role = "cluster" end
    ' "$KUBECONFIG" >"$TMP_HOME/bad-marker.json"
    mv "$TMP_HOME/bad-marker.json" "$KUBECONFIG"
    cp "$KUBECONFIG" "$TMP_HOME/before"
    run run_tool delete </dev/null
    [ "$status" -ne 0 ]
    assert_contains "$output" 'unsupported or inconsistent' 'reserved metadata must never imply unsafe cleanup'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'unsupported ownership must preserve bytes'
    rm "$KUBECONFIG"
    assert_no_artifacts
  done
}

@test "delete never opens or deletes relative external tokenFile CA certificates keys or their symlink targets" {
  local ca="$HOME/trust/ca.pem" cert="$HOME/.kube/relative/client.crt" key="$HOME/.kube/relative/client.key" tokenfile="$HOME/.kube/relative/external.token"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  mkdir -p "${ca%/*}" "${cert%/*}"
  printf 'synthetic external CA\n' >"$ca"
  printf 'synthetic external certificate\n' >"$cert"
  ln -s "$TMP_HOME/sentinel" "$key"
  mkfifo "$tokenfile"
  cp "$ca" "$TMP_HOME/before-ca"
  cp "$cert" "$TMP_HOME/before-cert"
  "$K8S_TEST_REAL_JQ" '
    .clusters[0].cluster["certificate-authority"] = "../trust/ca.pem" |
    .users[0].user += {tokenFile:"relative/external.token","client-certificate":"relative/client.crt","client-key":"relative/client.key"}
  ' "$KUBECONFIG" >"$TMP_HOME/references.json"
  mv "$TMP_HOME/references.json" "$KUBECONFIG"
  printf '1\nyes\n' | k8s_test_env timeout 5 "$TOOL" delete >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '(.contexts // [] | length) == 0 and (.users // [] | length) == 0 and (.clusters // [] | length) == 0'
  assert_same_file "$ca" "$TMP_HOME/before-ca" 'owned cluster cleanup must not delete its external CA'
  assert_same_file "$cert" "$TMP_HOME/before-cert" 'owned user cleanup must not delete external certificates'
  [ -L "$key" ]
  assert_eq "$(readlink "$key")" "$TMP_HOME/sentinel" 'external key symlink and target must remain unchanged'
  [ -p "$tokenfile" ]
  assert_file_exists "$TMP_HOME/sentinel" 'external key/token material must never be unlinked'
  assert_contains "$(<"$TMP_HOME/stderr")" 'ALL external Token/CA/certificate/key files' 'preview must explicitly retain every external material type'
  assert_no_artifacts
}

@test "split owned deletion joins cluster user and current cleanup in one checked transaction" {
  seed_split_owned
  delete_profile >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$HOME/context/config" '(.contexts // [] | length) == 0 and (.["current-context"] // "") == ""'
  assert_config_expr "$HOME/cluster/config" '(.clusters // [] | length) == 0 and (.["current-context"] // "") == ""'
  assert_config_expr "$HOME/user/config" '(.users // [] | length) == 0'
  assert_config_expr '' '(.["current-context"] // "") == ""'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Kubeconfig files changed: 3' 'preview must include cross-file eligible cleanup'
  assert_contains "$(<"$TMP_HOME/stderr")" 'ALL nonempty current-context values' 'current deletion must warn about hidden fallbacks'
  assert_no_artifacts
}

@test "current profile deletion clears ALL hidden different fallback values and publishes low precedence first" {
  local fallback="$HOME/fallback/config" expected
  seed_split_owned
  "$K8S_TEST_REAL_JQ" '.["current-context"] = "hidden-third"' "$HOME/user/config" >"$TMP_HOME/user-current.json"
  mv "$TMP_HOME/user-current.json" "$HOME/user/config"
  seed_basic "$fallback" fallback fallback-cluster fallback-user fallback
  KUBECONFIG="$KUBECONFIG:$fallback"
  K8S_TEST_SCENARIO=observe-publications
  install_failure_wrappers
  if ! delete_profile 2 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
    fail "current cleanup failed: $(<"$TMP_HOME/stderr")"
  fi
  expected=$(printf 'publish:%s\ncurrent:work\npublish:%s\ncurrent:work\npublish:%s\ncurrent:work\npublish:%s\ncurrent:\n' \
    "$fallback" "$HOME/user/config" "$HOME/cluster/config" "$HOME/context/config")
  assert_eq "$(<"$TMP_HOME/publications")" "$expected" 'every observed effective current must stay work until final clearing; no hidden fallback may activate'
  assert_config_expr "$fallback" '(.["current-context"] // "") == "" and .contexts[0].name == "fallback" and .users[0].user.token == $token' --rawfile token "$TMP_HOME/sentinel"
  assert_config_expr '' '(.["current-context"] // "") == "" and [.contexts[].name] == ["fallback"]'
  assert_contains "$(<"$TMP_HOME/stderr")" 'including hidden different fallbacks' 'warning must cover different hidden names, not merely the selected name'
  assert_no_artifacts
}

@test "noncurrent deletion clears only obsolete same-name references and preserves every different current fallback" {
  local first="$HOME/first/config" obsolete="$HOME/obsolete/config" different="$HOME/different/config"
  seed_basic "$first" work cluster user neighbour
  KUBECONFIG="$first"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=cluster --user=user >/dev/null
  seed_basic "$obsolete" later later-cluster later-user work
  seed_basic "$different" hidden hidden-cluster hidden-user hidden
  cp "$different" "$TMP_HOME/before-different"
  read_config_json "$TMP_HOME/before-obsolete.json" "$obsolete"
  KUBECONFIG="$first:$obsolete:$different"
  delete_profile 4 >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$first" '.["current-context"] == "neighbour" and [.contexts[].name] == ["neighbour"]'
  read_config_json "$TMP_HOME/after-obsolete.json" "$obsolete"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before-obsolete.json" '
    (.["current-context"] // "") == "" and (del(.["current-context"])) == ($before[0] | del(.["current-context"]))
  ' "$TMP_HOME/after-obsolete.json" >/dev/null
  assert_same_file "$different" "$TMP_HOME/before-different" 'noncurrent deletion must not clear different fallback values'
  assert_config_expr '' '.["current-context"] == "neighbour"'
  assert_not_contains "$(<"$TMP_HOME/stderr")" 'WARNING: This is the current profile.' 'noncurrent deletion must not claim to clear every current value'
  assert_no_artifacts
}

@test "exact unusual external context identities are deleted using escaped labels not renamed projections" {
  local name
  for name in '--option-like' $'space "quote":/|punctuation\n\177\302\233' ''; do
    seed_basic "$KUBECONFIG"
    "$K8S_TEST_REAL_JQ" -a --arg name "$name" '.contexts[0].name = $name | .["current-context"] = ""' "$KUBECONFIG" >"$TMP_HOME/named.json"
    mv "$TMP_HOME/named.json" "$KUBECONFIG"
    delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr "$KUBECONFIG" '(.contexts // [] | length) == 0 and (.clusters | length) == 1 and (.users | length) == 1 and (.["current-context"] // "") == ""'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'WARNING: This is the current profile.' 'an empty current value never activates even an empty context identity'
    if [[ "$name" == *punctuation* ]]; then
      assert_contains "$(<"$TMP_HOME/stdout")" '\u007c' 'success identity must be escaped'
      assert_contains "$(<"$TMP_HOME/stderr")" '\u009b' 'confirmation identity must escape terminal controls'
      assert_not_contains "$(<"$TMP_HOME/stdout")$(<"$TMP_HOME/stderr")" $'\302\233' 'raw controls must not reach the terminal'
    fi
    assert_no_artifacts
  done
}

@test "empty named context is selectable for deletion without clearing a different effective current profile" {
  local first="$HOME/first/config" other="$HOME/other/config"
  seed_basic "$first"
  "$K8S_TEST_REAL_JQ" '.contexts[0].name = "" | .["current-context"] = ""' "$first" >"$TMP_HOME/empty-name.json"
  mv "$TMP_HOME/empty-name.json" "$first"
  seed_basic "$other" other other-cluster other-user other
  cp "$other" "$TMP_HOME/before-other"
  KUBECONFIG="$first:$other"
  delete_profile 1 >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$first" '(.contexts // [] | length) == 0'
  assert_config_expr '' '.["current-context"] == "other" and [.contexts[].name] == ["other"]'
  assert_same_file "$other" "$TMP_HOME/before-other" 'empty identity is not an active current-context or an instruction to clear all values'
  assert_no_artifacts
}

@test "all unsafe split cleanup targets are preflighted before consent or publication" {
  seed_split_owned
  chmod 777 "$HOME/cluster"
  if delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'unsafe cleanup directory must reject deletion'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'group/world writable' 'unsafe cleanup origin must be reported'
  assert_not_contains "$(<"$TMP_HOME/stderr")" "Delete 'work'?" 'whole cleanup write-set must be checked before consent'
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'unsafe cleanup must prevent context publication'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'unsafe cleanup source must retain bytes'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'other cleanup target must retain bytes'
  assert_no_artifacts
}

@test "unsafe fallback-only current cleanup origin also prevents all current profile deletion" {
  local fallback="$HOME/fallback/config"
  seed_split_owned
  seed_basic "$fallback" fallback fallback-cluster fallback-user fallback
  cp "$fallback" "$TMP_HOME/before-fallback"
  KUBECONFIG="$KUBECONFIG:$fallback"
  chmod 777 "$HOME/fallback"
  if delete_profile 2 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'unsafe hidden current-value origin must block deletion'; fi
  assert_same_file "$HOME/context/config" "$TMP_HOME/before-context" 'unsafe fallback cleanup must block context removal'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'unsafe fallback cleanup must block owned cleanup'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'unsafe fallback cleanup must block credential cleanup'
  assert_same_file "$fallback" "$TMP_HOME/before-fallback" 'unsafe fallback file must not be rewritten'
  assert_no_artifacts
}

@test "installed layout loads lifecycle module and completes real create update delete" {
  install_test_layout
  assert_file_exists "$TMP_HOME/install/lib/picotools/k8s-profile/lifecycle.sh" 'installed loader must include the cohesive lifecycle module'
  create_profile installed >/dev/null 2>"$TMP_HOME/stderr"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  update_profile 1 https://installed.invalid "$TMP_HOME/replacement" >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '.contexts[0].name == "installed" and .clusters[0].cluster.server == "https://installed.invalid" and .users[0].user.token == $token' --rawfile token "$TMP_HOME/replacement"
  delete_profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stdout")" "Deleted profile 'installed'." 'installed dispatch must perform lifecycle operations'
  assert_config_expr "$KUBECONFIG" '(.contexts // [] | length) == 0 and (.users // [] | length) == 0'
  assert_no_artifacts
}
