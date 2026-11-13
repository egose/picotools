#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets the isolated environment for every test.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers/k8s-profile.bash.

load 'helpers/k8s-profile'

@test "list rejects FIFO inputs promptly but permits regular symlinks hardlinks and aliases" {
  local regular="$HOME/regular/config" fifo="$HOME/pipe" link="$HOME/config-link" hardlink="$HOME/config-hardlink"
  seed_basic "$regular"
  mkfifo "$fifo"
  KUBECONFIG="$regular:$fifo"
  run k8s_test_env timeout 5 "$TOOL" list
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]
  assert_contains "$output" 'unsafe kubeconfig input (nonregular file)' 'FIFO must be rejected before kubectl opens it'
  [ -p "$fifo" ]
  ln -s "$regular" "$link"
  ln "$regular" "$hardlink"
  KUBECONFIG="$link:$hardlink:$HOME/regular/./config:$regular"
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'external' 'read-only list must retain kubectl regular alias/link loading'
  assert_no_artifacts
}

@test "empty named context stays visible and exact but empty or unset current-context is not active" {
  local current
  seed_basic "$KUBECONFIG"
  for current in empty unset; do
    "$K8S_TEST_REAL_JQ" --arg current "$current" '
      .contexts[0].name = "" |
      if $current == "empty" then .["current-context"] = "" else del(.["current-context"]) end
    ' "$KUBECONFIG" >"$TMP_HOME/empty-name.json"
    mv "$TMP_HOME/empty-name.json" "$KUBECONFIG"
    if k8s_test_env "$K8S_TEST_REAL_KUBECTL" config current-context >"$TMP_HOME/current-out" 2>"$TMP_HOME/current-error"; then
      fail 'real kubectl must treat empty/unset current-context as inactive'
    fi
    assert_contains "$(<"$TMP_HOME/current-error")" 'current-context is not set' 'real kubectl establishes the inactive boundary'
    run run_tool list
    [ "$status" -eq 0 ]
    assert_contains "$output" '| no' 'empty named context must not be marked active'
    assert_not_contains "$output" '| yes' 'empty current-context must not match an empty context name'
    run run_module_script '
      k8s_profile_init
      k8s_profile_read_visible
      k8s_profile_profile_name 1 exact_name
      [ -z "$exact_name" ]
      jq -e '\''.profiles | length == 1 and .[0].current == false'\'' "$K8S_PROFILE_TMP_DIR/profiles.json" >/dev/null
    '
    [ "$status" -eq 0 ]
    assert_no_artifacts
  done
}

@test "help version aliases and no command work without operational dependencies" {
  local restricted_path alias
  restricted_path=$(path_with_commands "$TMP_HOME/restricted" bash cat dirname tr)
  for alias in -h --help help ''; do
    if [ -n "$alias" ]; then
      run env PATH="$restricted_path" "$TOOL" "$alias"
    else
      run env PATH="$restricted_path" "$TOOL"
    fi
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Usage: k8s-profile [--debug] <command>' 'help should describe the entrypoint'
    assert_contains "$output" 'create/list/update/delete accept no arguments; use accepts one optional name.' 'help should document strict grammar'
    assert_contains "$output" 'HTTP, URL userinfo' 'help should document HTTPS-only policy'
    assert_contains "$output" 'not crash-atomic' 'help should document transaction limits'
  done
  for alias in -v --version version; do
    run env PATH="$restricted_path" "$TOOL" "$alias"
    [ "$status" -eq 0 ]
    assert_eq "$output" "$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" 'shared version should match VERSION'
  done
  assert_file_not_exists "$KUBECONFIG" 'help/version should not create kubeconfig'
  assert_no_artifacts
}

@test "missing kubectl is reported before prompts or writes" {
  local restricted_path
  restricted_path=$(path_with_commands "$TMP_HOME/restricted" bash dirname)
  run env PATH="$restricted_path" "$TOOL" create
  [ "$status" -ne 0 ]
  assert_contains "$output" 'kubectl is required but not installed' 'create should check kubectl first'
  assert_not_contains "$output" 'Name:' 'dependency failure must precede prompts'
  assert_file_not_exists "$KUBECONFIG" 'dependency failure must not write config'
  assert_no_artifacts
}

@test "missing jq is reported before prompts or writes" {
  local restricted_path
  restricted_path=$(path_with_commands "$TMP_HOME/restricted" bash dirname kubectl)
  run env PATH="$restricted_path" "$TOOL" create
  [ "$status" -ne 0 ]
  assert_contains "$output" 'jq is required but not installed' 'create should check jq before prompting'
  assert_not_contains "$output" 'Name:' 'dependency failure must precede prompts'
  assert_file_not_exists "$KUBECONFIG" 'dependency failure must not write config'
}

@test "four action commands reject every extra operand before dependencies or prompts" {
  local command restricted_path
  restricted_path=$(path_with_commands "$TMP_HOME/restricted" bash dirname cat)
  for command in create list update delete; do
    run env PATH="$restricted_path" "$TOOL" "$command" unexpected
    [ "$status" -ne 0 ]
    assert_contains "$output" "$command does not accept arguments" 'action should reject extra operands'
    assert_not_contains "$output" 'required but not installed' 'grammar should be checked before dependencies'
    assert_not_contains "$output" 'Name:' 'invalid grammar must not prompt'
    run env PATH="$restricted_path" "$TOOL" "$command" --debug
    [ "$status" -ne 0 ]
    assert_contains "$output" '--debug is a global option' 'debug is global only'
  done
  assert_no_artifacts
}

@test "help version aliases also reject operands and unsupported commands are unavailable" {
  local command
  for command in help --help -h version --version -v; do
    run run_tool "$command" extra
    [ "$status" -ne 0 ]
    assert_contains "$output" 'does not accept arguments' 'aliases must obey strict grammar'
  done
  for command in read set token rename --unknown --; do
    run run_tool "$command"
    [ "$status" -ne 0 ]
    assert_contains "$output" 'unknown command' 'unsupported actions must remain unavailable'
  done
}

@test "global debug goes to stderr while list results stay on stdout" {
  seed_basic "$KUBECONFIG" external actual-cluster actual-user external
  run_tool --debug --debug list >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_contains "$(<"$TMP_HOME/stderr")" '[k8s-profile] Listing 1 profile(s)' 'debug should report counts only'
  assert_not_contains "$(<"$TMP_HOME/stdout")" '[k8s-profile]' 'debug must not contaminate table output'
  assert_contains "$(<"$TMP_HOME/stdout")" 'actual-cluster' 'table should use actual cluster reference'
  assert_contains "$(<"$TMP_HOME/stdout")" 'actual-user' 'table should use actual user reference'
  assert_contains "$(<"$TMP_HOME/stdout")" '| Current' 'table should show current state'
  assert_no_artifacts
}

@test "empty list is friendly read only and uses kubectl without raw or minify" {
  install_failure_wrappers
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'No Kubernetes profiles found.' 'list should distinguish an empty configuration'
  assert_file_not_exists "$KUBECONFIG" 'list must not create a kubeconfig'
  assert_not_contains "$(tr '\000' ' ' <"$TMP_HOME/audit")" '--raw' 'list must not request raw data'
  assert_not_contains "$(tr '\000' ' ' <"$TMP_HOME/audit")" '--minify' 'list must not hide external contexts'
  assert_no_artifacts
}

@test "unset and empty KUBECONFIG use the isolated default" {
  seed_basic "$KUBECONFIG"
  unset KUBECONFIG
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'external' 'unset KUBECONFIG should load HOME default'
  KUBECONFIG=''
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'external' 'empty KUBECONFIG should load HOME default'
}

@test "separator only KUBECONFIG is empty for list and rejected for creation" {
  seed_basic "$KUBECONFIG"
  KUBECONFIG='::'
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'No Kubernetes profiles found.' 'separator-only chain must not fall back to HOME'
  run run_tool create
  [ "$status" -ne 0 ]
  assert_contains "$output" 'KUBECONFIG has no file paths' 'create needs a target path'
  assert_not_contains "$output" 'Name:' 'empty chain must fail before prompts'
}

@test "list reflects outside kubectl edits on the next invocation" {
  seed_basic "$KUBECONFIG" first first-cluster first-user first
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'first' 'external initial context should be visible'
  k8s_test_env "$K8S_TEST_REAL_KUBECTL" config set-context second --cluster=first-cluster --user=first-user >/dev/null
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'second' 'list should have no saved registry cache'
  assert_contains "$output" '| 2 ' 'list should use stable sorted indexes'
  assert_not_contains "$output" 'Select profile:' 'list must never prompt'
}

@test "list retains missing references instead of dropping incomplete contexts" {
  write_fixture "$KUBECONFIG" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"missing","context":{"cluster":"not-defined","user":"also-not-defined"}},{"name":"blank-refs","context":{}}],"current-context":"missing"}
EOF
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'missing' 'missing resource context must remain listed'
  assert_contains "$output" 'blank-refs' 'empty references must remain listed'
  assert_contains "$output" 'yes' 'current context must still be identified'
  assert_not_contains "$output" 'not-defined' 'unresolved resource columns should show a dash'
  assert_no_artifacts
}

@test "external names are escaped for display but index lookup keeps exact identity" {
  local strange=$'space "quote":/|punctuation\n\177\302\233' actual
  mkdir -p "${KUBECONFIG%/*}"
  "$K8S_TEST_REAL_JQ" -a -n --arg strange "$strange" '
    {apiVersion:"v1",kind:"Config",contexts:[{name:"--option-like",context:{}},{name:$strange,context:{}}]}
  ' >"$KUBECONFIG"
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" '--option-like' 'option-like names must remain visible'
  assert_contains "$output" '\"quote\"' 'quotes should be escaped for display'
  assert_contains "$output" '\u007c' 'table delimiters should be escaped for display'
  assert_contains "$output" '\n' 'newlines should not create fake rows'
  assert_contains "$output" '\u007f' 'DEL should be escaped'
  assert_contains "$output" '\u009b' 'C1 terminal controls should be escaped'
  source_k8s_profile_modules
  (
    k8s_profile_init
    k8s_profile_read_visible
    k8s_profile_profile_name 2 actual
    assert_eq "$actual" "$strange" 'index identity must not use the escaped label'
  )
  create_profile work >/dev/null 2>"$TMP_HOME/stderr"
  assert_config_expr "$KUBECONFIG" 'any(.contexts[]; .name == $strange)' --arg strange "$strange"
  assert_no_artifacts
}

@test "failed kubectl list and malformed JSON are errors not empty configuration" {
  local scenario
  install_failure_wrappers
  for scenario in kubectl-fail malformed-json; do
    K8S_TEST_SCENARIO="$scenario"
    if run_tool list >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then
      fail 'failed or malformed kubectl output must fail list'
    fi
    assert_eq "$(<"$TMP_HOME/stdout")" '' 'failed list should not emit partial results'
    assert_contains "$(<"$TMP_HOME/stderr")" 'Error:' 'list should report a controlled error'
    assert_not_contains "$(<"$TMP_HOME/stderr")" "$(<"$TMP_HOME/sentinel")" 'diagnostics must not disclose credentials'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'No Kubernetes profiles found.' 'failure must not be treated as empty'
    assert_no_artifacts
  done
}

@test "real malformed duplicate user diagnostics remain private" {
  seed_basic "$KUBECONFIG"
  "$K8S_TEST_REAL_JQ" '.users += [.users[0]]' "$KUBECONFIG" >"$TMP_HOME/duplicate.json"
  mv "$TMP_HOME/duplicate.json" "$KUBECONFIG"
  run run_tool list
  [ "$status" -ne 0 ]
  assert_contains "$output" 'unable to read kubectl configuration' 'actual kubectl parse failure must be controlled'
  assert_not_contains "$output" "$(<"$TMP_HOME/sentinel")" 'nonraw duplicate-user error must not disclose its token'
  assert_no_artifacts
}

@test "release archive installs all modules for help version real create list and the CI lifecycle smoke" {
  local module
  install_test_layout
  for module in common config transaction model actions lifecycle; do
    assert_file_exists "$TMP_HOME/install/lib/picotools/k8s-profile/$module.sh" 'installed module must be present'
  done
  run run_tool --help
  [ "$status" -eq 0 ]
  run run_tool --version
  [ "$status" -eq 0 ]
  assert_eq "$output" "$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" 'installed VERSION should resolve'
  create_profile installed >/dev/null 2>"$TMP_HOME/stderr"
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'installed' 'installed create should be visible to installed list'
  assert_config_expr "$KUBECONFIG" '.contexts[0].name == "installed" and .users[0].user.token == $token' --rawfile token "$TMP_HOME/sentinel"
  run k8s_test_env bash "$REPO_ROOT/scripts/functional-test-k8s-profile-install.bash" "$TMP_HOME/install"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Installed k8s-profile create/list/use/update/delete smoke passed.' 'CI must validate the real installed artifact privately'
  assert_no_artifacts
}
