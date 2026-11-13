#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets the isolated environment for every test.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers/k8s-profile.bash.

load 'helpers/k8s-profile'

@test "Token input creation failure returns no successful path and cleans private state" {
  {
    builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
  } | run_module_script '
    k8s_profile_init
    mkdir "$K8S_PROFILE_TMP_DIR/token-input"
    token_path=""
    if k8s_profile_prompt_token_file token_path; then exit 9; fi
    [ -z "$token_path" ]
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" 'unable to prepare private Token input' 'creation failure must be checked'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed creation must not report a successful path'
  if grep -F -q -f "$TMP_HOME/sentinel" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'failed input leaked Token bytes'; fi
  assert_file_not_exists "$KUBECONFIG" 'failed Token input must not create config'
  assert_no_artifacts
}

@test "failed partial builtin Token write returns no path and keeps secret diagnostics private" {
  {
    builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
  } | run_module_script '
    builtin() {
      if [ "$1" = printf ] && [ "${2:-}" = "%s" ]; then
        command builtin printf "partial-private-token"
        command builtin printf "%s" "$(<"$K8S_TEST_SENTINEL_FILE")" >&2
        return 1
      fi
      command builtin "$@"
    }
    k8s_profile_init
    token_path=""
    if k8s_profile_prompt_token_file token_path; then exit 9; fi
    [ -z "$token_path" ]
    [ ! -e "$K8S_PROFILE_TMP_DIR/token-input" ]
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" 'unable to write private Token input' 'write failure must be explicit'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed write must not report a successful path'
  if grep -F -q -f "$TMP_HOME/sentinel" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'Token write diagnostics leaked'; fi
  assert_no_artifacts
}

@test "failed Token input write cannot publish a profile or retain sensitive partial input" {
  {
    printf 'work\nhttps://api.invalid:6443\n'
    builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
  } | run_module_script '
    builtin() {
      if [ "$1" = printf ] && [ "${2:-}" = "%s" ]; then
        command builtin printf "partial-private-token"
        command builtin printf "%s" "$(<"$K8S_TEST_SENTINEL_FILE")" >&2
        return 1
      fi
      command builtin "$@"
    }
    if k8s_profile_create; then exit 9; fi
    [ ! -e "$K8S_PROFILE_TMP_DIR/token-input" ]
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" 'unable to write private Token input' 'create must fail at the Token write boundary'
  assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed create must not report success'
  if grep -F -q -f "$TMP_HOME/sentinel" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'failed create leaked Token diagnostics'; fi
  assert_file_not_exists "$KUBECONFIG" 'partial Token input must never be published'
  assert_no_artifacts
}

@test "unsafe TMPDIR ancestry is rejected before any config or secret input is read" {
  chmod 777 "$TMPDIR"
  run run_tool create </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" 'unsafe private workspace directory' 'private workspace ancestry must be safe too'
  assert_not_contains "$output" 'Name:' 'unsafe private workspace should fail before prompts'
  assert_file_not_exists "$KUBECONFIG" 'unsafe private workspace must not create config'
  assert_no_artifacts
}

@test "mutation rejects regular target symlinks broken symlinks directories and FIFOs" {
  local kind target="$HOME/unsafe/config" original="$HOME/original/config"
  seed_basic "$original"
  mkdir -p "${target%/*}"
  cp "$original" "$TMP_HOME/before"
  KUBECONFIG="$target"
  for kind in symlink broken directory fifo; do
    case "$kind" in
    symlink) ln -s "$original" "$target" ;;
    broken) ln -s "$HOME/not-present" "$target" ;;
    directory) mkdir "$target" ;;
    fifo) mkfifo "$target" ;;
    esac
    run run_tool create </dev/null
    [ "$status" -ne 0 ]
    assert_contains "$output" 'unsafe kubeconfig path' 'unsafe target type should be explicit'
    assert_not_contains "$output" 'Name:' 'unsafe chain paths should fail before prompts'
    assert_same_file "$original" "$TMP_HOME/before" 'unsafe target refusal must preserve source bytes'
    if [ "$kind" = directory ]; then rmdir "$target"; else rm "$target"; fi
    assert_no_artifacts
  done
}

@test "mutation rejects hard-linked files without changing either link" {
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  ln "$KUBECONFIG" "$HOME/hardlink"
  run run_tool create </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" 'hard-linked file' 'hard links must not be rewritten'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'first hard link must be unchanged'
  assert_same_file "$HOME/hardlink" "$TMP_HOME/before" 'other hard link must be unchanged'
  assert_no_artifacts
}

@test "mutation rejects symlinked ancestors even when a dot-dot could hide the link" {
  local real_dir="$HOME/real" alias_dir="$HOME/alias"
  seed_basic "$real_dir/config"
  cp "$real_dir/config" "$TMP_HOME/before"
  ln -s "$real_dir" "$alias_dir"
  KUBECONFIG="$alias_dir/config"
  run run_tool create </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" 'unsafe kubeconfig directory' 'symlink directory should fail closed'
  KUBECONFIG="$alias_dir/../real/config"
  run run_tool create </dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" 'unsafe kubeconfig directory' 'lexical normalisation must not hide unsafe traversal'
  assert_same_file "$real_dir/config" "$TMP_HOME/before" 'unsafe ancestry must preserve bytes'
  assert_no_artifacts
}

@test "group or world writable destination and ancestor directories are rejected" {
  local directory="$HOME/unsafe" mode
  seed_basic "$directory/private/config"
  cp "$directory/private/config" "$TMP_HOME/before"
  KUBECONFIG="$directory/private/config"
  for mode in 777 775 757; do
    chmod "$mode" "$directory"
    if printf 'work\n' | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
      fail 'writable unsafe ancestors should reject writes'
    fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'group/world writable' 'unsafe directory permission should be explicit'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Token:' 'unsafe write preflight should precede Token'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'unsafe directory must preserve bytes'
    assert_no_artifacts
  done
  chmod 700 "$directory"
  chmod 777 "$directory/private"
  if printf 'work\n' | run_tool create >/dev/null 2>"$TMP_HOME/stderr"; then fail 'unsafe immediate directory should fail'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'group/world writable' 'immediate destination should also be checked'
}

@test "foreign target ownership fails before later prompts using real kubectl fixtures" {
  local foreign_uid
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  foreign_uid=$((UID + 1))
  # Unprivileged tests cannot chown a fixture. Override only the stat ownership
  # answer, retaining actual stat identities/content and real kubectl reads.
  mkdir "$TMP_HOME/stat-wrapper"
  cat >"$TMP_HOME/stat-wrapper/stat" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = '--printf=%u' ] && [ "${@: -1}" = "$K8S_TEST_TARGET" ]; then
  printf '%s' "$K8S_TEST_OTHER"
else
  exec "$K8S_TEST_REAL_STAT" "$@"
fi
EOF
  K8S_TEST_TARGET="$KUBECONFIG"
  K8S_TEST_OTHER="$foreign_uid"
  chmod +x "$TMP_HOME/stat-wrapper/stat"
  PATH="$TMP_HOME/stat-wrapper:$PATH"
  if printf 'work\n' | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'foreign owner should fail'; fi
  assert_contains "$(<"$TMP_HOME/stderr")" 'foreign owner' 'foreign target ownership should be explicit'
  assert_not_contains "$(<"$TMP_HOME/stderr")" 'Server:' 'foreign ownership should fail before connection prompts'
  assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'foreign-owned target refusal must preserve bytes'
  assert_no_artifacts
}

@test "safe broad config permissions are tightened on publication and temporary secret state stays private" {
  seed_basic "$KUBECONFIG"
  chmod 644 "$KUBECONFIG"
  install_failure_wrappers
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  assert_mode "$KUBECONFIG" 600 'safe existing target should be atomically replaced with mode 600'
  assert_contains "$(tr '\000' ' ' <"$TMP_HOME/audit")" 'token-mode:600' 'Token input file should be private'
  assert_contains "$(tr '\000' ' ' <"$TMP_HOME/audit")" 'workspace-mode:700' 'raw snapshot directory should be private'
  assert_contains "$(tr '\000' ' ' <"$TMP_HOME/audit")" 'stage-mode:600' 'same-directory raw candidates should be private'
  assert_no_artifacts
}

@test "Token never enters subprocess argv environment stdout stderr or inherited xtrace" {
  install_failure_wrappers
  {
    printf 'work\nhttps://api.invalid:6443\n'
    printf '%s\n' "$(<"$TMP_HOME/sentinel")"
  } | k8s_test_env env k8s_profile_token_value=public-inherited bash -x "$TOOL" --debug create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  if grep -F -q -f "$TMP_HOME/sentinel" "$TMP_HOME/audit" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then
    fail 'synthetic Token leaked across a public/process boundary'
  fi
  assert_contains "$(<"$TMP_HOME/stderr")" '[k8s-profile]' 'debug should remain usable with xtrace disabled'
  assert_config_expr "$KUBECONFIG" '.users[0].user.token == $token' --rawfile token "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "kuberc and credential plugins are inert and their nonraw secret fields are never displayed" {
  seed_basic "$KUBECONFIG" plugin-context plugin-cluster plugin-user plugin-context
  write_fixture "$HOME/.kube/kuberc" <<'EOF'
not: [valid: yaml
EOF
  write_fixture "$HOME/plugin" <<'EOF'
#!/usr/bin/env bash
printf called >"$HOME/plugin-called"
exit 98
EOF
  chmod +x "$HOME/plugin"
  "$K8S_TEST_REAL_JQ" --arg plugin "$HOME/plugin" --rawfile token "$TMP_HOME/sentinel" '
    .users[0].user.exec = {apiVersion:"client.authentication.k8s.io/v1",command:$plugin,interactiveMode:"Never",env:[{name:"SECRET",value:$token}]} |
    .users[0].user["auth-provider"] = {name:"oidc",config:{"client-secret":$token}} |
    .users[0].user.password = $token
  ' "$KUBECONFIG" >"$TMP_HOME/plugin.json"
  mv "$TMP_HOME/plugin.json" "$KUBECONFIG"
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  run run_tool --debug list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'plugin-context' 'external plugin-backed context should remain visible'
  assert_not_contains "$output" "$(<"$TMP_HOME/sentinel")" 'exec/provider/basic secrets must never be projected'
  assert_not_contains "$output" 'client-secret' 'list should not display provider details'
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" '
    [.users[] | select(.name == "plugin-user")] == $before[0].users
  ' "$TMP_HOME/after.json" >/dev/null
  assert_file_not_exists "$HOME/plugin-called" 'local view/create must not execute a credential plugin'
  assert_no_artifacts
}

@test "external Server URL userinfo query and fragment do not expose credentials in list" {
  seed_basic "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" --rawfile token "$TMP_HOME/sentinel" '
    .clusters[0].cluster.server = ("https://user:" + $token + "@api.invalid/prefix?token=" + $token + "#" + $token)
  ' "$KUBECONFIG" >"$TMP_HOME/url.json"
  mv "$TMP_HOME/url.json" "$KUBECONFIG"
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'api.invalid/prefix' 'nonsecret Server location should remain visible'
  assert_contains "$output" '[redacted]' 'URL userinfo should be omitted'
  assert_not_contains "$output" "$(<"$TMP_HOME/sentinel")" 'URL credentials must not be displayed'
  assert_no_artifacts
}

@test "preexisting regular symlink directory and FIFO locks are never replaced or removed" {
  local kind lock
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  lock="$KUBECONFIG.lock"
  for kind in regular symlink directory fifo; do
    case "$kind" in
    regular) printf foreign-lock >"$lock" ;;
    symlink) ln -s "$TMP_HOME/sentinel" "$lock" ;;
    directory) mkdir "$lock" ;;
    fifo) mkfifo "$lock" ;;
    esac
    if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'existing lock must prevent publication'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'lock is unavailable' 'existing lock should be reported without opening it'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'blocked lock must preserve configuration'
    [ -e "$lock" ] || [ -L "$lock" ]
    assert_no_artifacts true
    if [ "$kind" = directory ]; then rmdir "$lock"; else rm "$lock"; fi
  done
}

@test "shared explicitly owned resources are cloned and neighbour remains unchanged" {
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=k8s-profile:work:cluster:1 --user=k8s-profile:work:user:1 >/dev/null
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config use-context neighbour >/dev/null
  read_config_json "$TMP_HOME/before.json" "$KUBECONFIG"
  printf '%s' 'K8S_SYNTHETIC_REPLACEMENT_SENTINEL' >"$TMP_HOME/sentinel"
  create_profile work https://replacement.invalid:6443 yes >/dev/null 2>"$TMP_HOME/stderr"
  read_config_json "$TMP_HOME/after.json" "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" -e --slurpfile before "$TMP_HOME/before.json" --rawfile token "$TMP_HOME/sentinel" '
    .["current-context"] == "neighbour" and
    [.contexts[] | select(.name == "neighbour")] == [$before[0].contexts[] | select(.name == "neighbour")] and
    [.clusters[] | select(.name == "k8s-profile:work:cluster:1")] == $before[0].clusters and
    [.users[] | select(.name == "k8s-profile:work:user:1")] == $before[0].users and
    any(.contexts[]; .name == "work" and .context.cluster == "k8s-profile:work:cluster:2") and
    any(.users[]; .name == "k8s-profile:work:user:2" and .user.token == $token)
  ' "$TMP_HOME/after.json" >/dev/null
  assert_no_artifacts
}

@test "hidden physical context references prevent owned resource reuse or orphan cleanup" {
  local first="$KUBECONFIG" shadow="$HOME/shadow/config"
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context neighbour --cluster=missing-visible --user=missing-visible >/dev/null
  write_fixture "$shadow" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"neighbour","context":{"cluster":"k8s-profile:work:cluster:1","user":"k8s-profile:work:user:1"}}]}
EOF
  cp "$shadow" "$TMP_HOME/before-shadow"
  KUBECONFIG="$first:$shadow"
  create_profile work https://replacement.invalid:6443 yes >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$first" '
    any(.contexts[]; .name == "work" and .context.cluster == "k8s-profile:work:cluster:2") and
    any(.clusters[]; .name == "k8s-profile:work:cluster:1") and any(.users[]; .name == "k8s-profile:work:user:1")
  '
  assert_same_file "$shadow" "$TMP_HOME/before-shadow" 'hidden reference file must retain bytes'
  assert_no_artifacts
}
