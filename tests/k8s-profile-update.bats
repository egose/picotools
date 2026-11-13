#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets the isolated environment for every test.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers/k8s-profile.bash.

load 'helpers/k8s-profile'

@test "owned server-only update preserves Token authentication TLS namespace extensions and current state" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  "$K8S_TEST_REAL_JQ" '
    .["current-context"] = "work" |
    .contexts[0].context.namespace = "kept" |
    .contexts[0].context.extensions += [{name:"context-extra",extension:{keep:true}}] |
    .clusters[0].cluster += {"certificate-authority":"../trust/ca.pem","tls-server-name":"sni.invalid",
      "proxy-url":"http://proxy.invalid:8080","disable-compression":true} |
    .clusters[0].cluster.extensions += [{name:"cluster-extra",extension:{keep:true}}] |
    .users[0].user += {as:"kept-impersonation","as-groups":["group-one"]} |
    .users[0].user.extensions += [{name:"user-extra",extension:{keep:true}}]
  ' "$KUBECONFIG" >"$TMP_HOME/enriched.json"
  mv "$TMP_HOME/enriched.json" "$KUBECONFIG"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  update_profile 1 https://replacement.invalid:6443/prefix >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stdout")" "Updated profile 'work'." 'update must report completed publication'
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '
    .contexts == $before[0].contexts and .users == $before[0].users and
    .["current-context"] == "work" and (.clusters | length) == 1 and
    .clusters[0].name == $before[0].clusters[0].name and
    .clusters[0].cluster.server == "https://replacement.invalid:6443/prefix" and
    (.clusters[0].cluster | del(.server)) == ($before[0].clusters[0].cluster | del(.server))
  ' "$TMP_HOME/after.json" >/dev/null
  assert_mode "$KUBECONFIG" 600 'updated config must be private'
  assert_no_artifacts
}

@test "owned token-only update keeps the exact Server cluster and context while replacing only bearer content" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config use-context work >/dev/null
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  update_profile 1 '' "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" --rawfile token "$TMP_HOME/replacement" '
    .contexts == $before[0].contexts and .clusters == $before[0].clusters and .["current-context"] == "work" and
    (.users | length) == 1 and .users[0].name == $before[0].users[0].name and .users[0].user.token == $token and
    (.users[0].user | del(.token)) == ($before[0].users[0].user | del(.token))
  ' "$TMP_HOME/after.json" >/dev/null
  assert_contains "$(<"$TMP_HOME/stderr")" 'Keep Token [configured]' 'Token menu must show only status'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Replace Token' 'configured bearer Token can be replaced'
  assert_not_contains "$(<"$TMP_HOME/stderr")" 'Remove Token' 'Token-based profiles must not offer removal'
  assert_no_artifacts
}

@test "both update fields round trip through independent real kubectl without selecting another context" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  update_profile 1 https://both.invalid:7443 "$TMP_HOME/replacement" >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '
    .contexts[0].name == "work" and .contexts[0].context.cluster == "k8s-profile:work:cluster:1" and
    .contexts[0].context.user == "k8s-profile:work:user:1" and .clusters[0].cluster.server == "https://both.invalid:7443" and
    .users[0].user.token == $token and (.["current-context"] // "") == ""
  ' --rawfile token "$TMP_HOME/replacement"
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'https://both.invalid:7443' 'authoritative list must reflect the updated Server'
  assert_no_artifacts
}

@test "Done unchanged Server defaults same Token and Keep are true no-ops without permission or byte changes" {
  local input
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  chmod 644 "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  install_failure_wrappers
  for input in $'1\n4\n' $'1\n1\n\n4\n' $'1\n1\nhttps://api.invalid:6443\n4\n' $'1\n2\n1\n4\n' $'1\n2\n\n4\n'; do
    printf '%s' "$input" | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_contains "$(<"$TMP_HOME/stdout")" 'No changes to profile' 'unchanged proposals must not enter the writer'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'no-op must preserve exact original bytes'
    assert_mode "$KUBECONFIG" 644 'no-op must not tighten permissions or replace the inode'
    assert_no_artifacts
  done
  update_profile 1 '' "$TMP_HOME/sentinel" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stdout")" 'No changes to profile' 'identical inline Token must also be a no-op'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'identical Token must preserve bytes'
  assert_not_contains "$(tr '\000' ' ' <"$TMP_HOME/audit")" '.k8s-profile.stage.' 'no-op must not even create a candidate'
  assert_no_artifacts
}

@test "changing Server then restoring its original value before Done publishes nothing" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  printf '1\n1\nhttps://temporary.invalid\n1\nhttps://api.invalid:6443\n4\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stdout")" 'No changes to profile' 'final proposal, not intermediate edits, determines mutation'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'reverted Server must not replace any state'
  assert_no_artifacts
}

@test "Token can be added to an external auth-free user while preserving impersonation and the Server" {
  seed_basic "$KUBECONFIG" work cluster user work
  "$K8S_TEST_REAL_JQ" '.users[0].user = {as:"kept","as-groups":["group"],extensions:[{name:"extra",extension:{keep:true}}]}' "$KUBECONFIG" >"$TMP_HOME/auth-free.json"
  mv "$TMP_HOME/auth-free.json" "$KUBECONFIG"
  update_profile 1 '' "$TMP_HOME/sentinel" >/dev/null 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" 'Add Token' 'auth-free user must offer add, not remove'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Keep Token [not configured]' 'absence is status, never a real Token default'
  assert_config_expr "$KUBECONFIG" '
    .contexts[0].context.cluster == "cluster" and .clusters[0].cluster.server == "https://external.invalid:6443" and
    .contexts[0].context.user == "k8s-profile:work:user:1" and
    any(.users[]; .name == "k8s-profile:work:user:1" and .user.token == $token and .user.as == "kept" and
      .user["as-groups"] == ["group"] and any(.user.extensions[]; .name == "extra")) and
    any(.users[]; .name == "user" and .user.token == null) and .["current-context"] == "work"
  ' --rawfile token "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "relative tokenFile is compatible kept unchanged on Server-only update and replaced without reading or deleting it" {
  local external="$HOME/.kube/relative/never-opened.token"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  mkdir -p "${external%/*}"
  mkfifo "$external"
  "$K8S_TEST_REAL_JQ" '.users[0].user |= (del(.token) | .tokenFile = "relative/never-opened.token")' "$KUBECONFIG" >"$TMP_HOME/tokenfile.json"
  mv "$TMP_HOME/tokenfile.json" "$KUBECONFIG"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  printf '1\n1\nhttps://server-only.invalid\n4\n' | k8s_test_env timeout 5 "$TOOL" update >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '.users == $before[0].users' "$TMP_HOME/after.json" >/dev/null
  {
    printf '1\n2\n2\n'
    builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
    printf '4\n'
  } | k8s_test_env timeout 5 "$TOOL" update >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '
    (.users | length) == 1 and .users[0].user.token == $token and .users[0].user.tokenFile == null and
    .clusters[0].cluster.server == "https://server-only.invalid"
  ' --rawfile token "$TMP_HOME/sentinel"
  [ -p "$external" ]
  assert_contains "$(<"$TMP_HOME/stderr")" 'Replace Token' 'a tokenFile reference is configured bearer authentication'
  assert_no_artifacts
}

@test "credential-bearing existing Server is never a prompt or argv default and token-only update keeps its exact private value" {
  seed_basic "$KUBECONFIG" work cluster user work
  "$K8S_TEST_REAL_JQ" --rawfile token "$TMP_HOME/sentinel" '
    .clusters[0].cluster.server = ("https://user:" + $token + "@api.invalid/prefix?token=" + $token + "#" + $token)
  ' "$KUBECONFIG" >"$TMP_HOME/secret-url.json"
  mv "$TMP_HOME/secret-url.json" "$KUBECONFIG"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  install_failure_wrappers
  update_profile 1 '' "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '.clusters == $before[0].clusters and .["current-context"] == "work"' "$TMP_HOME/after.json" >/dev/null
  if grep -F -q -f "$TMP_HOME/sentinel" -f "$TMP_HOME/replacement" "$TMP_HOME/audit" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'existing URL or new Token leaked'; fi
  assert_contains "$(tr '\000' ' ' <"$TMP_HOME/audit")" '--arg server  --argjson server_change false' 'unchanged Server must be passed as empty to the planner'
  assert_contains "$(<"$TMP_HOME/stderr")" '[redacted]@api.invalid/prefix' 'menu may display only the escaped redacted location'
  assert_no_artifacts
}

@test "redacted malformed and HTTP Servers have no usable default and cannot be saved by a blank input or EOF" {
  local server
  for server in 'https://user:secret@api.invalid?secret=value#secret' 'https://bad_host' 'http://localhost:8080'; do
    seed_basic "$KUBECONFIG" work cluster user
    "$K8S_TEST_REAL_JQ" --arg server "$server" '.clusters[0].cluster.server = $server' "$KUBECONFIG" >"$TMP_HOME/server.json"
    mv "$TMP_HOME/server.json" "$KUBECONFIG"
    cp "$KUBECONFIG" "$TMP_HOME/before"
    if printf '1\n1\n\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'unsafe default must not be silently reapplied'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'Server: Value is required.' 'unsafe/malformed original must not become an editable default'
    assert_contains "$(<"$TMP_HOME/stderr")" 'input ended before required value' 'EOF must not apply a projected default'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'missing valid replacement must preserve bytes'
    assert_no_artifacts
  done
}

@test "token-only updates preserve nonempty externally configured malformed or HTTP Servers instead of validating a projection" {
  local server
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  for server in 'https://bad_host' 'http://localhost:8080'; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_JQ" --arg server "$server" '.clusters[0].cluster.server = $server' "$KUBECONFIG" >"$TMP_HOME/server.json"
    mv "$TMP_HOME/server.json" "$KUBECONFIG"
    update_profile 1 '' "$TMP_HOME/replacement" >/dev/null 2>"$TMP_HOME/stderr"
    assert_config_expr "$KUBECONFIG" '.clusters[0].cluster.server == $server and .["current-context"] == "work"' --arg server "$server"
    assert_no_artifacts
  done
}

@test "existing NUL-bearing Server cannot be truncated into a seemingly valid prompt default" {
  seed_basic "$KUBECONFIG" work cluster user work
  "$K8S_TEST_REAL_JQ" '.clusters[0].cluster.server = "https://api.invalid\u0000?secret=value"' "$KUBECONFIG" >"$TMP_HOME/nul-server.json"
  mv "$TMP_HOME/nul-server.json" "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  if printf '1\n1\n\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'NUL-truncated Server must not become a valid default'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'Server: Value is required.' 'validation must concern the complete original Server, not its NUL prefix'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'NUL-bearing original must not be silently replaced'
  assert_no_artifacts
}

@test "Token replacement rejects exec provider username password certificate and key auth before secret input or partial Server changes" {
  local auth
  for auth in exec provider username password certificate certificate-data key key-data; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_JQ" --arg auth "$auth" --rawfile secret "$TMP_HOME/sentinel" '
      .users[0].user |= (if $auth == "exec" then .exec = {apiVersion:"client.authentication.k8s.io/v1",command:"never-run",interactiveMode:"Never",env:[{name:"SECRET",value:$secret}]}
        elif $auth == "provider" then .["auth-provider"] = {name:"oidc",config:{"client-secret":$secret}}
        elif $auth == "username" then .username = "kept"
        elif $auth == "password" then .password = $secret
        elif $auth == "certificate" then .["client-certificate"] = "relative/client.crt"
        elif $auth == "certificate-data" then .["client-certificate-data"] = "c3ludGhldGljLWNlcnQ="
        elif $auth == "key" then .["client-key"] = "relative/client.key"
        else .["client-key-data"] = "c3ludGhldGljLWtleQ==" end)
    ' "$KUBECONFIG" >"$TMP_HOME/auth.json"
    mv "$TMP_HOME/auth.json" "$KUBECONFIG"
    cp "$KUBECONFIG" "$TMP_HOME/before"
    if printf '1\n1\nhttps://not-published.invalid\n2\n2\n' | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'incompatible Token replacement must fail'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'keep Token for a Server-only update' 'auth rejection must give controlled recovery guidance'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Token: ' 'auth conflict must be detected before the actual secret prompt'
    assert_not_contains "$(<"$TMP_HOME/stdout")$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'auth diagnostics must not disclose secrets'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'auth conflict must not publish the earlier Server proposal'
    assert_no_artifacts
  done
}

@test "Server-only update leaves all external authentication mechanisms and credential plugins untouched" {
  local auth plugin="$HOME/never-run-plugin"
  write_fixture "$plugin" <<'EOF'
#!/usr/bin/env bash
printf called >"$HOME/plugin-called"
exit 98
EOF
  chmod +x "$plugin"
  for auth in exec provider basic certificate key; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_JQ" --arg auth "$auth" --arg plugin "$plugin" --rawfile secret "$TMP_HOME/sentinel" '
      .users[0].user |= (if $auth == "exec" then .exec = {apiVersion:"client.authentication.k8s.io/v1",command:$plugin,interactiveMode:"Never",env:[{name:"SECRET",value:$secret}]}
        elif $auth == "provider" then .["auth-provider"] = {name:"oidc",config:{"client-secret":$secret}}
        elif $auth == "basic" then .username = "kept" | .password = $secret
        elif $auth == "certificate" then .["client-certificate"] = "relative/client.crt"
        else .["client-key-data"] = "c3ludGhldGljLWtleQ==" end)
    ' "$KUBECONFIG" >"$TMP_HOME/auth.json"
    mv "$TMP_HOME/auth.json" "$KUBECONFIG"
    read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
    update_profile 1 https://server-only.invalid >/dev/null 2>"$TMP_HOME/stderr"
    read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
    "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '.users == $before[0].users and .contexts[0].context.user == "user" and .["current-context"] == "work"' "$TMP_HOME/after.json" >/dev/null
    assert_file_not_exists "$HOME/plugin-called" 'Server-only update must never execute credential plugins'
    assert_no_artifacts
  done
}

@test "shared owned Server update clones only the cluster and preserves the neighbour and shared Token" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=k8s-profile:work:cluster:1 --user=k8s-profile:work:user:1 >/dev/null
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config use-context neighbour >/dev/null
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  update_profile 2 https://selected.invalid >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '
    .users == $before[0].users and .["current-context"] == "neighbour" and
    [.contexts[] | select(.name == "neighbour")] == [$before[0].contexts[] | select(.name == "neighbour")] and
    [.clusters[] | select(.name == "k8s-profile:work:cluster:1")] == $before[0].clusters and
    any(.contexts[]; .name == "work" and .context.cluster == "k8s-profile:work:cluster:2" and .context.user == "k8s-profile:work:user:1")
  ' "$TMP_HOME/after.json" >/dev/null
  assert_no_artifacts
}

@test "shared unmanaged Token update clones only the user and preserves all other credentials and Servers" {
  seed_basic "$KUBECONFIG" work shared-cluster shared-user neighbour
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=shared-cluster --user=shared-user >/dev/null
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  update_profile 2 '' "$TMP_HOME/replacement" >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" --rawfile token "$TMP_HOME/replacement" '
    .clusters == $before[0].clusters and .["current-context"] == "neighbour" and
    [.contexts[] | select(.name == "neighbour")] == [$before[0].contexts[] | select(.name == "neighbour")] and
    [.users[] | select(.name == "shared-user")] == $before[0].users and
    any(.contexts[]; .name == "work" and .context.cluster == "shared-cluster" and .context.user == "k8s-profile:work:user:1") and
    any(.users[]; .name == "k8s-profile:work:user:1" and .user.token == $token)
  ' "$TMP_HOME/after.json" >/dev/null
  assert_no_artifacts
}

@test "split owned server-only update rebases CA into context origin and cleans only the orphan cluster file" {
  seed_split_owned
  update_profile 1 https://split-server.invalid >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$HOME/context/config" '
    .contexts[0].context.cluster == "k8s-profile:work:cluster:2" and .contexts[0].context.user == "k8s-profile:work:user:1" and
    .clusters[0].cluster["certificate-authority"] == $ca and .contexts[0].context.namespace == "kept" and .["current-context"] == "work"
  ' --arg ca "$HOME/cluster/../trust/ca.pem"
  assert_config_expr "$HOME/cluster/config" '(.clusters // [] | length) == 0 and .["current-context"] == "hidden-other"'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'unchanged split authentication file must keep exact bytes'
  assert_no_artifacts
}

@test "split owned token-only update cleans only the orphan user and preserves cluster and hidden current values" {
  seed_split_owned
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  update_profile 1 '' "$TMP_HOME/replacement" >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$HOME/context/config" '
    .contexts[0].context.cluster == "k8s-profile:work:cluster:1" and .contexts[0].context.user == "k8s-profile:work:user:2" and
    .users[0].user.token == $token and .["current-context"] == "work"
  ' --rawfile token "$TMP_HOME/replacement"
  assert_config_expr "$HOME/user/config" '(.users // [] | length) == 0'
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'unchanged cluster and its hidden current-context must keep bytes'
  assert_config_expr '' '.["current-context"] == "work"'
  assert_no_artifacts
}

@test "both fields on split shared unmanaged resources preserve sources CA meaning namespace and extensions" {
  local context_file="$HOME/context/config" cluster_file="$HOME/cluster/config" user_file="$HOME/user/config"
  write_fixture "$context_file" <<'EOF'
{"apiVersion":"v1","kind":"Config","extensions":[{"name":"root-extra","extension":{"keep":true}}],"contexts":[{"name":"work","context":{"cluster":"shared-cluster","user":"shared-user","namespace":"kept","extensions":[{"name":"context-extra","extension":{"keep":true}}]}},{"name":"neighbour","context":{"cluster":"shared-cluster","user":"shared-user","namespace":"neighbour-kept"}}],"current-context":"neighbour"}
EOF
  write_fixture "$cluster_file" <<'EOF'
{"apiVersion":"v1","kind":"Config","clusters":[{"name":"shared-cluster","cluster":{"server":"https://old.invalid","certificate-authority":"../trust/ca.pem","tls-server-name":"sni.invalid","extensions":[{"name":"cluster-extra","extension":{"keep":true}}]}}],"current-context":"hidden-other"}
EOF
  mkdir -p "${user_file%/*}"
  "$K8S_TEST_REAL_JQ" -n --rawfile token "$TMP_HOME/sentinel" '
    {apiVersion:"v1",kind:"Config",users:[{name:"shared-user",user:{token:$token,tokenFile:"relative/not-opened.token",as:"kept",
      extensions:[{name:"user-extra",extension:{keep:true}}]}}]}
  ' >"$user_file"
  chmod 600 "$user_file"
  cp "$cluster_file" "$TMP_HOME/before-cluster"
  cp "$user_file" "$TMP_HOME/before-user"
  KUBECONFIG="$context_file:$cluster_file:$user_file"
  update_profile 2 https://replacement.invalid "$TMP_HOME/sentinel" >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$context_file" '
    any(.contexts[]; .name == "work" and .context.namespace == "kept" and any(.context.extensions[]; .name == "context-extra")) and
    any(.contexts[]; .name == "neighbour" and .context.cluster == "shared-cluster" and .context.user == "shared-user") and
    .clusters[0].cluster["certificate-authority"] == $ca and .clusters[0].cluster["tls-server-name"] == "sni.invalid" and
    any(.clusters[0].cluster.extensions[]; .name == "cluster-extra") and .users[0].user.token == $token and
    .users[0].user.tokenFile == null and .users[0].user.as == "kept" and any(.users[0].user.extensions[]; .name == "user-extra") and
    .extensions[0].name == "root-extra" and .["current-context"] == "neighbour"
  ' --arg ca "$HOME/cluster/../trust/ca.pem" --rawfile token "$TMP_HOME/sentinel"
  assert_same_file "$cluster_file" "$TMP_HOME/before-cluster" 'shared CA source must retain bytes'
  assert_same_file "$user_file" "$TMP_HOME/before-user" 'shared Token and tokenFile source must retain bytes'
  assert_no_artifacts
}

@test "update of a context with physical shadows allocates fresh generations and preserves every hidden definition" {
  local first="$HOME/first/config" shadow="$HOME/shadow/config"
  KUBECONFIG="$first"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config use-context work >/dev/null
  read_config_json "$TMP_HOME/before.json" "$first"
  mkdir -p "${shadow%/*}"
  "$K8S_TEST_REAL_JQ" '.["current-context"] = "hidden-other"' "$TMP_HOME/before.json" >"$shadow"
  chmod 600 "$shadow"
  cp "$shadow" "$TMP_HOME/before-shadow"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  KUBECONFIG="$first:$shadow"
  update_profile 1 https://replacement.invalid "$TMP_HOME/replacement" >/dev/null 2>"$TMP_HOME/stderr"
  assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'update may change only the visible context origin, never its shadows'
  read_config_json "$TMP_HOME/after.json" "$first"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" --rawfile token "$TMP_HOME/replacement" '
    .contexts[0].context.cluster == "k8s-profile:work:cluster:2" and .contexts[0].context.user == "k8s-profile:work:user:2" and
    [.clusters[] | select(.name == "k8s-profile:work:cluster:1")] == $before[0].clusters and
    [.users[] | select(.name == "k8s-profile:work:user:1")] == $before[0].users and
    any(.users[]; .name == "k8s-profile:work:user:2" and .user.token == $token) and .["current-context"] == "work"
  ' "$TMP_HOME/after.json" >/dev/null
  assert_no_artifacts
}

@test "missing cluster information rejects token-only proposals without partial credentials" {
  write_fixture "$KUBECONFIG" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"work","context":{"cluster":"missing-cluster","user":"missing-user","namespace":"kept"}}],"current-context":"work"}
EOF
  cp "$KUBECONFIG" "$TMP_HOME/before"
  if update_profile 1 '' "$TMP_HOME/sentinel" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'missing required Server must reject the full proposal'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'required cluster information' 'missing Server must give a controlled reason'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'missing Server must not publish the Token proposal'
  assert_no_artifacts
}

@test "missing cluster and user references are repaired when both corresponding fields are supplied" {
  write_fixture "$KUBECONFIG" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"work","context":{"cluster":"missing-cluster","user":"missing-user","namespace":"kept"}}],"current-context":"work"}
EOF
  update_profile 1 https://repaired.invalid "$TMP_HOME/sentinel" >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '
    .contexts[0].context.namespace == "kept" and .clusters[0].cluster.server == "https://repaired.invalid" and
    .users[0].user.token == $token and .["current-context"] == "work"
  ' --rawfile token "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "missing user is repaired by Add Token without replacing its existing cluster" {
  seed_basic "$KUBECONFIG" work cluster user work
  "$K8S_TEST_REAL_JQ" '.users = []' "$KUBECONFIG" >"$TMP_HOME/missing-user.json"
  mv "$TMP_HOME/missing-user.json" "$KUBECONFIG"
  update_profile 1 '' "$TMP_HOME/sentinel" >/dev/null 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" 'Add Token' 'unresolved user must allow Token repair'
  assert_config_expr "$KUBECONFIG" '.contexts[0].context.cluster == "cluster" and .clusters[0].cluster.server == "https://external.invalid:6443" and .users[0].user.token == $token' --rawfile token "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "missing cluster is repaired by Server without touching external authentication" {
  seed_basic "$KUBECONFIG" work cluster user work
  "$K8S_TEST_REAL_JQ" '.clusters = [] | .users[0].user.exec = {apiVersion:"client.authentication.k8s.io/v1",command:"never-run",interactiveMode:"Never"}' "$KUBECONFIG" >"$TMP_HOME/missing-cluster.json"
  mv "$TMP_HOME/missing-cluster.json" "$KUBECONFIG"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  update_profile 1 https://repaired.invalid >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '.users == $before[0].users and .contexts[0].context.user == "user" and .clusters[0].cluster.server == "https://repaired.invalid"' "$TMP_HOME/after.json" >/dev/null
  assert_no_artifacts
}

@test "interactive update preserves exact unusual external names including empty names and escaped terminal controls" {
  local name
  for name in '--option-like' $'space "quote":/|punctuation\n\177\302\233' ''; do
    seed_basic "$KUBECONFIG"
    "$K8S_TEST_REAL_JQ" -a --arg name "$name" '.contexts[0].name = $name | .["current-context"] = $name' "$KUBECONFIG" >"$TMP_HOME/named.json"
    mv "$TMP_HOME/named.json" "$KUBECONFIG"
    update_profile 1 https://replacement.invalid "$TMP_HOME/sentinel" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr "$KUBECONFIG" '.contexts[0].name == $name and .contexts[0].context.namespace == "kept" and .["current-context"] == $name' --arg name "$name"
    if [[ "$name" == *punctuation* ]]; then
      assert_contains "$(<"$TMP_HOME/stdout")" '\u007c' 'success must escape displayed external identities'
      assert_contains "$(<"$TMP_HOME/stderr")" '\u009b' 'menu must escape terminal controls'
      assert_not_contains "$(<"$TMP_HOME/stdout")$(<"$TMP_HOME/stderr")" $'\302\233' 'external C1 must never reach the terminal literally'
    fi
    assert_no_artifacts
  done
}

@test "update selection cancellation invalid indexes NUL and EOF never change any state" {
  local input
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for input in '' '1' $'\n' $'q\n' $'0\n' $'2\n' $'01\n' $'999999999999999999999999999\n' \
    $'1\n' $'1\nq\n' $'1\n5\n' $'1\n1\nhttps://not-published.invalid\nq\n' \
    $'1\n2\n' $'1\n2\n3\n' $'1\n2\nq\n' $'1\n2\n2\n' $'1\n1\nhttps://not-published.invalid\n2\n2\n'; do
    if printf '%s' "$input" | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'canceled/invalid/EOF update input must fail'; fi
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'invalid selection must not publish pending fields'
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'invalid input must not claim a completed update'
    assert_no_artifacts
  done
  if printf '1\000\n' | run_tool update >/dev/null 2>"$TMP_HOME/stderr"; then fail 'NUL selection must not be normalized'; fi
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'NUL selection must preserve bytes'
}

@test "update Server Token validation and incomplete default input reject all pending changes" {
  local input
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for input in $'1\n1\n' $'1\n1\nhttp://localhost\n' $'1\n1\nhttps://user:secret@host\n' $'1\n1\nhttps://host?token=secret\n' \
    $'1\n1\nhttps://host#secret\n' $'1\n1\nhttps://host/with space\n' \
    $'1\n1\nhttps://not-published.invalid\n2\n2\npartial-at-eof' \
    $'1\n1\nhttps://not-published.invalid\n2\n2\ninside space\n' $'1\n2\n2\ninside\rcontrol\n'; do
    if printf '%s' "$input" | run_tool update >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'invalid field proposal must fail'; fi
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'validation or EOF must reject the complete pending proposal'
    assert_no_artifacts
  done
  if printf '1\n1\nhttps://host\000suffix\n' | run_tool update >/dev/null 2>"$TMP_HOME/stderr"; then fail 'NUL Server input must fail'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'unsupported NUL character' 'Server input must not silently discard NUL'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'NUL Server must preserve bytes'
  if printf '1\n2\n2\nsecret\000suffix\n' | run_tool update >/dev/null 2>"$TMP_HOME/stderr"; then fail 'NUL Token input must fail'; fi
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'NUL Token must not be silently rewritten'
  assert_no_artifacts
}
