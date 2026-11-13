#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets the isolated environment for every test.

load 'helpers/k8s-profile'

@test "real create registers name server inline token and ownership without activation" {
  create_profile work https://api.invalid:6443/prefix >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stdout")" "Saved profile 'work'." 'create should report completed registration'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Name:' 'ordinary prompts should go to stderr'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Server:' 'Server prompt should be present'
  assert_contains "$(<"$TMP_HOME/stderr")" 'Token:' 'required secret should use Token terminology'
  assert_not_contains "$(<"$TMP_HOME/stdout")$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'create must not print Token content'
  assert_config_expr "$KUBECONFIG" '
    .contexts[0].name == "work" and .contexts[0].context.cluster == "k8s-profile:work:cluster:1" and
    .contexts[0].context.user == "k8s-profile:work:user:1" and
    .clusters[0].cluster.server == "https://api.invalid:6443/prefix" and
    .users[0].user.token == $token and (.["current-context"] // "") == "" and
    ([.contexts[0].context.extensions[], .clusters[0].cluster.extensions[], .users[0].user.extensions[]] |
      all(.name == "picotools.k8s-profile" and .extension.version == 1 and .extension.profile == "work")) and
    (.clusters[0].cluster["insecure-skip-tls-verify"] // false) == false
  ' --rawfile token "$TMP_HOME/sentinel"
  assert_mode "$KUBECONFIG" 600 'published kubeconfig should be private'
  assert_mode "$HOME/.kube" 700 'new kubeconfig directory should be private'
  assert_no_artifacts
}

@test "create preserves current context and unrelated loaded configuration" {
  seed_basic "$KUBECONFIG" external actual-cluster actual-user external
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '
    .["current-context"] == "external" and
    ([.contexts[] | select(.name == "external")] == $before[0].contexts) and
    ([.clusters[] | select(.name == "actual-cluster")] == $before[0].clusters) and
    ([.users[] | select(.name == "actual-user")] == $before[0].users)
  ' "$TMP_HOME/after.json" >/dev/null
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'external' 'unmanaged context should remain visible'
  assert_contains "$output" 'work' 'new context should be independently visible'
  assert_no_artifacts
}

@test "ordinary required prompts retry blank completed lines but reject EOF including partial input" {
  local input
  for input in '' $'\n' $'work' $'work\n' $'work\nhttps://api.invalid'; do
    if printf '%s' "$input" | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
      fail 'EOF before completed required input must fail'
    fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'input ended before required value was provided' 'EOF should be explicit'
    assert_file_not_exists "$KUBECONFIG" 'EOF must not publish a partial profile'
    assert_no_artifacts
  done
  {
    printf '\n  \nwork\n\n \nhttps://api.invalid:6443\n'
    printf '%s\n' "$(<"$TMP_HOME/sentinel")"
  } | run_tool create >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '.contexts[0].name == "work"'
}

@test "ordinary required Server prompt never applies a default at EOF" {
  source_k8s_profile_modules
  run k8s_profile_prompt_required Server https://default.invalid </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" 'input ended before required value was provided' 'EOF must not select a default'
  run bash -c '. "$1"; printf "\n" | k8s_profile_prompt_required Server https://default.invalid' _ "$REPO_ROOT/tools/lib/picotools/k8s-profile/common.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'https://default.invalid' 'a completed blank line may apply the public default'
}

@test "Token EOF whitespace and control failures never publish a profile" {
  local suffix
  for suffix in '' $'partial-at-eof' $'\n' $'  \n' $' leading\n' $'trailing \n' $'inside space\n' $'inside\tcontrol\n' $'inside\rcontrol\n'; do
    if {
      printf 'work\nhttps://api.invalid:6443\n'
      printf '%s' "$suffix"
    } | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
      fail 'invalid or missing Token must fail'
    fi
    assert_file_not_exists "$KUBECONFIG" 'Token failure must not publish configuration'
    assert_not_contains "$(<"$TMP_HOME/stdout")" 'Saved profile' 'Token failure must not claim success'
    assert_no_artifacts
  done
}

@test "NUL in Name Server or Token input is rejected instead of silently discarded" {
  local input
  for input in 'work\000suffix\n' 'work\nhttps://api\000.invalid\n' 'work\nhttps://api.invalid\nsecret\000suffix\n'; do
    if printf '%b' "$input" | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'NUL-bearing input must fail'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'unsupported NUL character' 'NUL must not change an input identity or credential'
    assert_file_not_exists "$KUBECONFIG" 'NUL-bearing input must not publish config'
    assert_no_artifacts
  done
}

@test "invalid new names fail before Server or Token prompts" {
  local name
  for name in 'space name' 'slash/name' 'colon:name' 'bad?' $'control\tname'; do
    if printf '%s\n' "$name" | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
      fail 'new name outside git-profile character policy must fail'
    fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'profile name must match [A-Za-z0-9._-]+' 'name policy should be explicit'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Server:' 'invalid name should stop subsequent prompts'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Token:' 'invalid name should stop secret input'
    assert_no_artifacts
  done
}

@test "git-profile compatible option-like names are safely registered" {
  create_profile --option-like >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '.contexts[0].name == "--option-like" and .contexts[0].context.cluster == "k8s-profile:--option-like:cluster:1"'
  assert_no_artifacts
}

@test "meaningful HTTPS URLs accept private addresses ports IPv6 and paths offline" {
  local server index=0
  for server in https://localhost https://10.1.2.3:6443 https://api.internal.example:443/prefix/v1 https://api.internal./ 'https://[::1]:6443/prefix' 'https://[2001:db8::1]:443' 'https://[::ffff:192.0.2.1]/api%2Fv1'; do
    index=$((index + 1))
    create_profile "valid-$index" "$server" >/dev/null 2>"$TMP_HOME/stderr"
    assert_config_expr "$KUBECONFIG" 'any(.clusters[]; .cluster.server == $server)' --arg server "$server"
  done
  assert_no_artifacts
}

@test "HTTP and malformed or credential-bearing Server URLs fail before Token input" {
  local server
  for server in http://localhost:8080 https:// https:///path https://. https://host.. https://bad..host https://bad_host https://-host \
    https://host:0 https://host:65536 https://host:abc https://256.1.2.3 https://1.2.3 'https://[:::]' 'https://[1::2:]' \
    'https://[1:2:3]' 'https://[1.2.3.4::]' 'https://[1.2.3.4::1.2.3.4]' https://user:pass@host 'https://host/query?token=value' https://host/#fragment https://host/%00 https://host/%1b https://host/%xx \
    'https://host/bad space' 'https://host/\bad' $'https://host/\tbad' $'https://host/\rbad'; do
    if printf 'work\n%s\n' "$server" | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
      fail 'invalid Server URL must fail'
    fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'valid HTTPS API URL' 'Server URL policy should be actionable'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Token:' 'invalid Server must not prompt for Token'
    assert_file_not_exists "$KUBECONFIG" 'invalid Server must not publish configuration'
    assert_no_artifacts
  done
}

@test "empty existing config and quoted space-bearing file paths are safe write targets" {
  local first="$HOME/space directory/\"quoted\"/--config" second="$HOME/second/config"
  mkdir -p "${first%/*}"
  : >"$first"
  seed_basic "$second" second second-cluster second-user second
  cp "$second" "$TMP_HOME/before-second"
  KUBECONFIG="$first:$second"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$first" '.contexts[0].name == "work"'
  assert_same_file "$second" "$TMP_HOME/before-second" 'quoted target must not flatten the other file'
  assert_mode "$first" 600 'quoted target should still publish privately'
  assert_no_artifacts
}

@test "unrelated relative CA certificate key and tokenFile references retain exact meaning" {
  seed_basic "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" '
    .clusters[0].cluster["certificate-authority"] = "../trust/ca.pem" |
    .clusters[0].cluster["certificate-authority-data"] = "c3ludGhldGljLWNh" |
    .users[0].user["client-certificate"] = "relative/client.crt" |
    .users[0].user["client-key"] = "relative/client.key" |
    .users[0].user.tokenFile = "relative/never-opened.token"
  ' "$KUBECONFIG" >"$TMP_HOME/relative.json"
  mv "$TMP_HOME/relative.json" "$KUBECONFIG"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '
    [.clusters[] | select(.name == "external-cluster")] == $before[0].clusters and
    [.users[] | select(.name == "external-user")] == $before[0].users
  ' "$TMP_HOME/after.json" >/dev/null
  assert_file_not_exists "$HOME/.kube/relative/never-opened.token" 'external credential material must not be opened or created'
  assert_no_artifacts
}

@test "overwrite requires explicit default-no confirmation and decline or EOF preserves bytes" {
  local confirmation
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for confirmation in no '' eof; do
    if [ "$confirmation" = eof ]; then
      if printf 'work\n' | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'overwrite EOF must cancel'; fi
    else
      if printf 'work\n%s\n' "$confirmation" | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'declined overwrite must cancel'; fi
    fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'Overwrite? [y/N]' 'overwrite should be default-no'
    assert_contains "$(<"$TMP_HOME/stderr")" 'Cancelled.' 'decline should be explicit'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Token:' 'decline must precede secret prompt'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'declined overwrite must preserve original bytes'
    assert_no_artifacts
  done
}

@test "overwrite of exclusively owned resources reuses explicit ownership and preserves context fields" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context work --namespace=kept >/dev/null
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config use-context work >/dev/null
  create_profile work https://replacement.invalid:6443 yes >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '
    (.clusters | length) == 1 and (.users | length) == 1 and
    .contexts[0].context.namespace == "kept" and .["current-context"] == "work" and
    .contexts[0].context.cluster == "k8s-profile:work:cluster:1" and
    .contexts[0].context.user == "k8s-profile:work:user:1" and
    .clusters[0].cluster.server == "https://replacement.invalid:6443"
  '
  assert_no_artifacts
}

@test "new entries target first existing member and preserve all hidden current values" {
  local first="$HOME/first/config" second="$HOME/second/config" third="$HOME/third/config"
  seed_empty "$second"
  seed_basic "$third" hidden hidden-cluster hidden-user hidden
  cp "$third" "$TMP_HOME/before-third"
  KUBECONFIG="$first:$second:$third"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  assert_file_not_exists "$first" 'an earlier missing member should not receive new entries'
  assert_config_expr "$second" '.contexts[0].name == "work" and (.["current-context"] // "") == ""'
  assert_same_file "$third" "$TMP_HOME/before-third" 'later current-context and objects must retain physical bytes'
  assert_config_expr '' '.["current-context"] == "hidden" and (.contexts | length) == 2'
  assert_no_artifacts
}

@test "all absent members target the last path without creating earlier paths" {
  local first="$HOME/first/config" last="$HOME/last/nested/config"
  KUBECONFIG="$first::$last"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  assert_file_not_exists "$first" 'all-absent chain must not create its first member'
  [ ! -d "$HOME/first" ]
  assert_config_expr "$last" '.contexts[0].name == "work"'
  assert_mode "$last" 600 'last target should be private'
  assert_mode "$HOME/last/nested" 700 'new nested directories should be private'
  assert_no_artifacts
}

@test "relative repeated and empty chain members retain precedence without flattening" {
  local first="$HOME/one/config" second="$HOME/two/config"
  seed_basic "$first" one one-cluster one-user
  seed_basic "$second" two two-cluster two-user
  cp "$second" "$TMP_HOME/before-second"
  KUBECONFIG='one/config::two/config:one/config'
  (
    cd "$HOME"
    create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  )
  assert_config_expr "$first" '(.contexts | length) == 2 and any(.contexts[]; .name == "work")'
  assert_same_file "$second" "$TMP_HOME/before-second" 'repeated/relative chain must not rewrite another file'
  assert_no_artifacts
}

@test "distinct lexical path aliases are rejected for mutation but still readable by list" {
  seed_basic "$KUBECONFIG"
  KUBECONFIG="$HOME/.kube/config:$HOME/.kube/./config"
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'external' 'read-only kubectl loading may deduplicate aliases'
  run run_tool create
  [ "$status" -ne 0 ]
  assert_contains "$output" 'distinct kubeconfig paths alias the same file' 'mutation must reject ambiguous origins'
  assert_not_contains "$output" 'Name:' 'aliases should fail before prompts'
  assert_no_artifacts
}

@test "overwrite changes only visible context origin and leaves shadow definitions intact" {
  local first="$HOME/one/config" shadow="$HOME/two/config"
  seed_basic "$first" work shared-cluster shared-user work
  seed_basic "$shadow" work shared-cluster shared-user hidden
  cp "$shadow" "$TMP_HOME/before-shadow"
  KUBECONFIG="$first:$shadow"
  create_profile work https://replacement.invalid:6443 yes >/dev/null 2>"$TMP_HOME/stderr"
  assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'hidden context/resource definitions must retain bytes'
  assert_config_expr "$first" '.contexts[0].context.cluster == "k8s-profile:work:cluster:1" and .["current-context"] == "work"'
  assert_config_expr '' '(.contexts | length) == 1 and any(.clusters[]; .cluster.server == "https://replacement.invalid:6443")'
  assert_no_artifacts
}

@test "resource generations skip unmanaged collisions including shadowed physical entries" {
  local first="$HOME/one/config" shadow="$HOME/two/config"
  seed_basic "$first" existing k8s-profile:work:cluster:1 k8s-profile:work:user:1
  seed_basic "$shadow" hidden k8s-profile:work:cluster:2 k8s-profile:work:user:2
  cp "$shadow" "$TMP_HOME/before-shadow"
  KUBECONFIG="$first:$shadow"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$first" '
    any(.contexts[]; .name == "work" and .context.cluster == "k8s-profile:work:cluster:3" and .context.user == "k8s-profile:work:user:3") and
    any(.clusters[]; .name == "k8s-profile:work:cluster:1" and .cluster.server == "https://external.invalid:6443")
  '
  assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'collision-only file should not be rewritten'
  assert_no_artifacts
}

@test "shared unmanaged split resources are cloned with relative CA meaning and other fields preserved" {
  local context_file="$HOME/context/config" cluster_file="$HOME/cluster/config" user_file="$HOME/user/config" current_file="$HOME/current/config"
  write_fixture "$context_file" <<'EOF'
{"apiVersion":"v1","kind":"Config","preferences":{"colors":true,"extensions":[{"name":"preference-extension","extension":{"keep":true}}]},"extensions":[{"name":"root-extension","extension":{"keep":true}}],"contexts":[{"name":"work","context":{"cluster":"shared-cluster","user":"shared-user","namespace":"kept","extensions":[{"name":"context-extension","extension":{"keep":true}}]}},{"name":"neighbour","context":{"cluster":"shared-cluster","user":"shared-user","namespace":"neighbour-kept"}}]}
EOF
  write_fixture "$cluster_file" <<'EOF'
{"apiVersion":"v1","kind":"Config","clusters":[{"name":"shared-cluster","cluster":{"server":"https://old.invalid:6443","certificate-authority":"../trust/ca.pem","tls-server-name":"sni.invalid","proxy-url":"http://proxy.invalid:8080","disable-compression":true,"insecure-skip-tls-verify":false,"extensions":[{"name":"cluster-extension","extension":{"keep":true}}]}}]}
EOF
  mkdir -p "${user_file%/*}"
  "$K8S_TEST_REAL_JQ" -n --rawfile token "$TMP_HOME/sentinel" '
    {apiVersion:"v1",kind:"Config",users:[{name:"shared-user",user:{token:$token,tokenFile:"relative/never-opened.token",as:"kept-impersonation",
      "as-groups":["group-one"],extensions:[{name:"user-extension",extension:{keep:true}}]}}]}
  ' >"$user_file"
  write_fixture "$current_file" <<'EOF'
{"apiVersion":"v1","kind":"Config","current-context":"neighbour"}
EOF
  cp "$cluster_file" "$TMP_HOME/before-cluster"
  cp "$user_file" "$TMP_HOME/before-user"
  cp "$current_file" "$TMP_HOME/before-current"
  KUBECONFIG="$context_file:$cluster_file:$user_file:$current_file"
  create_profile work https://replacement.invalid:6443 yes >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$context_file" '
    (.contexts | length) == 2 and any(.contexts[]; .name == "work" and .context.namespace == "kept") and
    any(.contexts[]; .name == "neighbour" and .context.cluster == "shared-cluster" and .context.user == "shared-user") and
    .clusters[0].cluster["certificate-authority"] == $ca and .clusters[0].cluster["tls-server-name"] == "sni.invalid" and
    .clusters[0].cluster["proxy-url"] == "http://proxy.invalid:8080" and .clusters[0].cluster["disable-compression"] == true and
    .users[0].user.as == "kept-impersonation" and .users[0].user["as-groups"] == ["group-one"] and
    .users[0].user.tokenFile == null and .users[0].user.token == $token and
    .extensions[0].name == "root-extension" and .preferences.extensions[0].name == "preference-extension" and
    any(.clusters[0].cluster.extensions[]; .name == "cluster-extension") and any(.users[0].user.extensions[]; .name == "user-extension")
  ' --arg ca "${cluster_file%/*}/../trust/ca.pem" --rawfile token "$TMP_HOME/sentinel"
  assert_same_file "$cluster_file" "$TMP_HOME/before-cluster" 'shared source cluster must retain bytes'
  assert_same_file "$user_file" "$TMP_HOME/before-user" 'shared source authentication and tokenFile must retain bytes'
  assert_same_file "$current_file" "$TMP_HOME/before-current" 'separate current-context must retain bytes'
  assert_file_not_exists "$HOME/user/relative/never-opened.token" 'external token files must not be opened or created'
  assert_config_expr '' '.["current-context"] == "neighbour"'
  assert_no_artifacts
}

@test "exclusively owned split resources are cloned into context origin and safely cleaned across files" {
  seed_split_owned
  create_profile work https://replacement.invalid:6443 yes >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$HOME/context/config" '
    .contexts[0].context.cluster == "k8s-profile:work:cluster:2" and .contexts[0].context.user == "k8s-profile:work:user:2" and
    .clusters[0].cluster["certificate-authority"] == $ca and .["current-context"] == "work"
  ' --arg ca "$HOME/cluster/../trust/ca.pem"
  assert_config_expr "$HOME/cluster/config" '(.clusters // [] | length) == 0 and .["current-context"] == "hidden-other"'
  assert_config_expr "$HOME/user/config" '(.users // [] | length) == 0'
  assert_mode "$HOME/context/config" 600 'context origin should be private'
  assert_mode "$HOME/cluster/config" 600 'cleanup origin should be private'
  assert_config_expr '' '.["current-context"] == "work"'
  assert_no_artifacts
}

@test "incompatible external auth methods are rejected rather than merged with a new Token" {
  local auth
  for auth in exec provider basic certificate key; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_JQ" --arg auth "$auth" '
      .users[0].user |= (if $auth == "exec" then .exec = {apiVersion:"client.authentication.k8s.io/v1",command:"never-run",interactiveMode:"Never"}
        elif $auth == "provider" then .["auth-provider"] = {name:"oidc",config:{}}
        elif $auth == "basic" then .username = "kept"
        elif $auth == "certificate" then .["client-certificate"] = "relative/client.crt"
        else .["client-key-data"] = "c3ludGhldGljLWtleQ==" end)
    ' "$KUBECONFIG" >"$TMP_HOME/auth.json"
    mv "$TMP_HOME/auth.json" "$KUBECONFIG"
    cp "$KUBECONFIG" "$TMP_HOME/before"
    if create_profile work https://replacement.invalid:6443 yes >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
      fail 'Token overwrite must not silently change the authentication mechanism'
    fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'compatible bearer authentication' 'incompatible authentication should be actionable'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'incompatible auth must retain config bytes'
    assert_no_artifacts
  done
}

@test "missing cluster and user references can be completed by overwrite" {
  write_fixture "$KUBECONFIG" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"work","context":{"cluster":"missing-cluster","user":"missing-user","namespace":"kept"}}],"current-context":"work"}
EOF
  create_profile work https://replacement.invalid:6443 yes >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" '
    .contexts[0].context.namespace == "kept" and .clusters[0].cluster.server == "https://replacement.invalid:6443" and
    .users[0].user.token == $token and .["current-context"] == "work"
  ' --rawfile token "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "reserved ownership metadata with unsupported versions or inconsistent naming fails closed" {
  local mutation
  for mutation in '.extension.version = 2' '.extension.role = "cluster"' '.extension.profile = "another"'; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_JQ" --arg mutation "$mutation" '
      .contexts[0].context.extensions = [{name:"picotools.k8s-profile",extension:{version:1,profile:"work",role:"context"}}] |
      .contexts[0].context.extensions[0] |=
        (if $mutation == ".extension.version = 2" then .extension.version = 2
         elif $mutation == ".extension.role = \"cluster\"" then .extension.role = "cluster" else .extension.profile = "another" end)
    ' "$KUBECONFIG" >"$TMP_HOME/ownership.json"
    mv "$TMP_HOME/ownership.json" "$KUBECONFIG"
    cp "$KUBECONFIG" "$TMP_HOME/before"
    run run_tool create
    [ "$status" -ne 0 ]
    assert_contains "$output" 'unsupported or inconsistent' 'unsupported reserved ownership must be explicit'
    assert_not_contains "$output" 'Name:' 'unsupported ownership should fail before prompts'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'unsupported ownership must retain bytes'
    assert_no_artifacts
  done
}
