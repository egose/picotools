#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets the isolated environment for every test.

load 'helpers/k8s-profile'

@test "namespace validator accepts DNS-1123 labels and rejects every other value offline" {
  source_k8s_profile_modules
  local value too_long invalid
  too_long=$(printf 'a%.0s' {1..63})
  invalid="${too_long}a"
  for value in default 0 a "$too_long" "0${too_long:0:62}"; do
    run k8s_profile_validate_namespace "$value"
    [ "$status" -eq 0 ]
    assert_not_contains "$output" 'Error:' 'valid namespace must not produce diagnostics'
  done
  for value in '' 'Default' 'bad_ns' 'with space' '-leading' 'trailing-' 'a.b' 'ns|pipe' "$invalid"; do
    run k8s_profile_validate_namespace "$value"
    [ "$status" -ne 0 ]
    assert_contains "$output" 'DNS-1123 label' 'rejections must state the exact policy'
  done
}

@test "create accepts the shown default namespace on a completed blank line" {
  create_profile work https://api.invalid:6443/prefix >/dev/null 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" 'Namespace [default]: ' 'create should offer default explicitly'
  assert_config_expr "$KUBECONFIG" '
    .contexts[0].name == "work" and .contexts[0].context.namespace == "default" and
    .clusters[0].cluster.server == "https://api.invalid:6443/prefix"
  '
  assert_no_artifacts
}

@test "create stores an explicit custom namespace after the Token prompt" {
  create_profile work https://api.invalid:6443 '' ai-poc >/dev/null 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" 'Token:' 'namespace must be prompted after Token'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Namespace [default]: ' 'the safe default must remain visible for custom entry'
  assert_config_expr "$KUBECONFIG" '.contexts[0].context.namespace == "ai-poc"'
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "invalid namespace labels are refused before staging without publishing configuration" {
  local value
  for value in 'Default' 'bad_ns' 'with space' '-leading' 'trailing-' 'a.b' "$(printf 'a%.0s' {1..64})"; do
    if {
      printf 'work\nhttps://api.invalid:6443\n'
      builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
      builtin printf '%s\n' "$value"
    } | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
      fail "invalid namespace '$value' must fail create"
    fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'DNS-1123 label' 'namespace policy must be explicit'
    assert_file_not_exists "$KUBECONFIG" 'invalid namespace must not publish configuration'
    assert_not_contains "$(<"$TMP_HOME/stdout")" 'Saved profile' 'failed create must not claim success'
    assert_no_artifacts
  done
}

@test "namespace EOF after a completed Token never publishes and never invents a namespace" {
  if {
    printf 'work\nhttps://api.invalid:6443\n'
    builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
  } | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
    fail 'EOF at the namespace prompt must fail create'
  fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'input ended before required value was provided' 'EOF must be explicit'
  assert_file_not_exists "$KUBECONFIG" 'EOF at namespace must not publish a partial profile'
  assert_no_artifacts
}

@test "update menu offers Namespace for an unset namespace and Done at index 4" {
  write_fixture "$KUBECONFIG" <<'EOF'
{"apiVersion":"v1","kind":"Config","clusters":[{"name":"c","cluster":{"server":"https://external.invalid:6443"}}],"users":[],"contexts":[{"name":"work","context":{"cluster":"c","user":"u"}}],"current-context":"work"}
EOF
  if printf '1\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
    fail 'EOF at the field menu must fail'
  fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'Namespace [-]' 'unset namespace must show a dash in the field menu'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Select field [4]: ' 'Done must be the fourth menu default'
  assert_no_artifacts
}

@test "update shows a valid existing namespace as the blank editable default" {
  seed_basic "$KUBECONFIG" work cluster user work
  if printf '1\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
    fail 'EOF at the field menu must fail'
  fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'Namespace [kept]' 'existing valid namespace must be the shown default'
  assert_no_artifacts
}

@test "update sets a namespace while keeping Server Token bytes and current context exactly" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  printf '1\n3\npoc-deploy\n4\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stdout")" "Updated profile 'work'." 'namespace-only change must publish'
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '
    .contexts[0].context.namespace == "poc-deploy" and (.["current-context"] // "") == "" and
    .users == $before[0].users and .clusters == $before[0].clusters
  ' "$TMP_HOME/after.json" >/dev/null
  assert_token_bytes "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "update with the unchanged namespace value is a byte-preserving no-op" {
  create_profile work https://api.invalid:6443 '' ai-poc >/dev/null 2>"$TMP_HOME/stderr"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  printf '1\n3\nai-poc\n4\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stdout")" 'No changes to profile' 'unchanged namespace must be a no-op'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'unchanged namespace must preserve exact original bytes'
  assert_no_artifacts
}

@test "update keeps the namespace unless it is explicitly selected and changed" {
  seed_basic "$KUBECONFIG" work cluster user work
  update_profile 1 https://changed.invalid '' >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '
    .contexts[0].context.namespace == "kept" and
    .contexts[0].context.cluster == "k8s-profile:work:cluster:1" and
    .["current-context"] == "work"
  '
  assert_config_expr "$KUBECONFIG" 'any(.clusters[]; .cluster.server == "https://changed.invalid")'
  assert_no_artifacts
}

@test "an invalid stored namespace offers no default and update never clears it" {
  write_fixture "$KUBECONFIG" <<'EOF'
{"apiVersion":"v1","kind":"Config","clusters":[{"name":"c","cluster":{"server":"https://external.invalid:6443"}}],"users":[],"contexts":[{"name":"work","context":{"cluster":"c","user":"u","namespace":"Invalid"}}],"current-context":"work"}
EOF
  cp "$KUBECONFIG" "$TMP_HOME/before"
  if printf '1\n3\n\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
    fail 'blank namespace without a usable default must fail'
  fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'Value is required.' 'blank must not invent a namespace'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'rejected namespace edit must preserve bytes'
  printf '1\n3\nfixed\n4\n' | run_tool update >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '.contexts[0].context.namespace == "fixed"'
  assert_no_artifacts
}

@test "list shows the Namespace column with values dash for unset and escaping for external data" {
  seed_basic "$KUBECONFIG" external external-cluster external-user external
  # Both external contexts are added with jq before any tool write: kubectl
  # would serialize the file as YAML and DEL/C1 must survive byte-exactly.
  "$K8S_TEST_REAL_JQ" -a '.contexts += [{name:"extra",context:{cluster:"external-cluster",user:"external-user"}},
    {name:"strange",context:{namespace:$ns}}]' --arg ns $'ns|d\177' "$KUBECONFIG" >"$TMP_HOME/extra.json"
  "$K8S_TEST_REAL_MV" "$TMP_HOME/extra.json" "$KUBECONFIG"
  create_profile work https://api.invalid:6443 '' ai-poc >/dev/null 2>"$TMP_HOME/stderr"
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Namespace' 'table header must include the Namespace column'
  local row
  row=$(grep -F ' extra ' <<<"$output" | head -n 1)
  assert_contains "$row" '| -' 'unset external namespace must display a dash'
  row=$(grep -F ' work ' <<<"$output" | head -n 1)
  assert_contains "$row" '| ai-poc' 'created namespace must be listed'
  row=$(grep -F ' external ' <<<"$output" | head -n 1)
  assert_contains "$row" '| kept' 'external namespace must be listed'
  assert_contains "$output" 'ns\u007cd\u007f' 'external namespace must be escaped for safe display'
  assert_no_artifacts
}
