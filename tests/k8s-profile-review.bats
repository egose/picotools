#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets each isolated fixture.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers.

load 'helpers/k8s-profile'

@test "inherited allexport create keeps Token out of EVERY external command environment and argv" {
  local launch command
  install_environment_audit_wrappers
  for launch in option inherited; do
    rm -f "$KUBECONFIG" "$TMP_HOME/audit"
    {
      printf 'work\nhttps://api.invalid\n'
      builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
      # Namespace prompt: blank accepts the shown default explicitly.
      printf '\n'
    } | if [ "$launch" = option ]; then
      k8s_test_env env k8s_profile_token_value=public-inherited bash -ax "$TOOL" --debug create
    else
      k8s_test_env env SHELLOPTS=allexport k8s_profile_token_value=public-inherited "$TOOL" --debug create
    fi >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    if grep -F -q -f "$TMP_HOME/sentinel" "$TMP_HOME/audit" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'allexport create leaked Token at a process/output boundary'; fi
    for command in chmod cmp jq kubectl mktemp stat rm; do
      assert_contains "$(tr '\000' '\n' <"$TMP_HOME/audit")" "$command" 'all runtime commands must be audited, not just kubectl/jq'
    done
    assert_token_bytes "$TMP_HOME/sentinel"
    assert_no_artifacts
  done
}

@test "inherited allexport update protects entered Token and privately validated existing Server across every child" {
  local launch
  printf '%s' 'K8S_REVIEW_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  install_environment_audit_wrappers
  for launch in option inherited; do
    seed_basic "$KUBECONFIG" work cluster user work
    "$K8S_TEST_REAL_JQ" --rawfile secret "$TMP_HOME/sentinel" '.clusters[0].cluster.server = ("https://user:" + $secret + "@api.invalid?token=" + $secret)' \
      "$KUBECONFIG" >"$TMP_HOME/private-server.json"
    "$K8S_TEST_REAL_MV" "$TMP_HOME/private-server.json" "$KUBECONFIG"
    rm -f "$TMP_HOME/audit"
    {
      printf '1\n2\n2\n'
      builtin printf '%s\n' "$(<"$TMP_HOME/replacement")"
      printf '4\n'
    } | if [ "$launch" = option ]; then
      k8s_test_env env k8s_profile_token_value=public-inherited k8s_profile_private_server=public-inherited bash -ax "$TOOL" --debug update
    else
      k8s_test_env env SHELLOPTS=allexport k8s_profile_token_value=public-inherited k8s_profile_private_server=public-inherited "$TOOL" --debug update
    fi >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    if grep -F -q -f "$TMP_HOME/sentinel" -f "$TMP_HOME/replacement" "$TMP_HOME/audit" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'allexport update leaked existing or replacement credentials'; fi
    assert_token_bytes "$TMP_HOME/replacement"
    assert_config_expr "$KUBECONFIG" '.["current-context"] == "work"'
    assert_no_artifacts
  done
}

@test "Token helper neutralizes allexport re-enabled by a sourced caller before capture" {
  install_environment_audit_wrappers
  {
    builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
  } | run_module_script '
    k8s_profile_init
    set -a
    k8s_profile_prompt_token_file token_path
    [ -f "$token_path" ]
  ' >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  if grep -F -q -f "$TMP_HOME/sentinel" "$TMP_HOME/audit" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'sourced helper re-exported Token under allexport'; fi
  assert_no_artifacts
}

@test "NUL-bearing or incomplete piped overwrite consent never authorizes replacement" {
  local consent
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for consent in 'yes\000\n' 'y\000es\n' 'yes'; do
    if {
      printf 'work\n%b' "$consent"
      if [[ "$consent" == *'\n' ]]; then
        printf 'https://changed.invalid\n'
        builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
      fi
    } | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'unchecked overwrite consent authorized publication'; fi
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Token:' 'invalid consent must stop before Token capture'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'invalid overwrite consent must preserve prior bytes'
    assert_no_artifacts
  done
}

@test "absolute and relative unsafe TMPDIR validate the SAME actual ancestry before sensitive I/O" {
  local spelling
  chmod 777 "$TMPDIR"
  for spelling in "$TMPDIR" tmp; do
    if (
      cd "$TMP_HOME"
      TMPDIR="$spelling"
      create_profile work
    ) >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'unsafe relative or absolute workspace was accepted'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'unsafe private workspace directory' 'both spellings must reject the actual writable ancestor'
    assert_not_contains "$(<"$TMP_HOME/stderr")" 'Name:' 'workspace rejection must precede config/Token reads'
    assert_file_not_exists "$KUBECONFIG" 'unsafe workspace must not publish config'
    assert_no_artifacts
  done
}

@test "safe relative TMPDIR works while relative symlink and symlink-dotdot ancestry fail" {
  local spelling
  (
    cd "$TMP_HOME"
    TMPDIR=tmp
    create_profile work
  ) >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_token_bytes "$TMP_HOME/sentinel"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  ln -s "$TMP_HOME" "$TMP_HOME/alias"
  for spelling in alias/tmp alias/../tmp; do
    if (
      cd "$TMP_HOME"
      TMPDIR="$spelling"
      create_profile another
    ) >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'relative symlink workspace ancestry must fail'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'unsafe private workspace directory' 'relative symlinks cannot be hidden by dotdot'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'unsafe workspace must preserve config'
    assert_no_artifacts
  done
}

@test "missing traversal ancestors are rejected before mutation rather than disappearing during EXIT cleanup" {
  local spelling existing
  for existing in false true; do
    if [ "$existing" = true ]; then
      seed_basic "$HOME/config"
      cp "$HOME/config" "$TMP_HOME/before"
    fi
    for spelling in bridge/../config bridge/./config bridge/nested/../../config; do
      KUBECONFIG="$HOME/$spelling"
      if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'missing traversal ancestor must not be created'; fi
      assert_contains "$(<"$TMP_HOME/stderr")" 'missing traversal ancestor' 'native traversal must be checked before mutation'
      assert_not_contains "$(<"$TMP_HOME/stderr")" 'Name:' 'missing traversal must fail before prompting'
      [ ! -d "$HOME/bridge" ]
      if [ "$existing" = true ]; then
        assert_same_file "$HOME/config" "$TMP_HOME/before" 'creating traversal must never expose/clobber a hidden existing target'
      else
        assert_file_not_exists "$HOME/config" 'rejected create must not leave an inaccessible physical config'
      fi
      assert_no_artifacts
    done
  done
}

@test "existing lexical dot and dotdot preserve native loading through independent POST-EXIT kubectl reads" {
  local spelling
  mkdir "$HOME/bridge"
  for spelling in bridge/../config bridge/./config; do
    KUBECONFIG="$HOME/$spelling"
    create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr '' 'any(.contexts[]; .name == "work") and .users[0].user.token == $token' --rawfile token "$TMP_HOME/sentinel"
    [ -d "$HOME/bridge" ]
    assert_file_exists "$KUBECONFIG" 'configured lexical target must still load after EXIT cleanup'
    assert_no_artifacts
  done
}

@test "colon HOME default is ONE literal regular file for unset and empty KUBECONFIG despite irrelevant prefix paths" {
  local mode
  HOME="$TMP_HOME/prefix:home"
  mkdir "$HOME" "$TMP_HOME/prefix"
  seed_basic "$HOME/.kube/config"
  for mode in unset empty; do
    if [ "$mode" = unset ]; then unset KUBECONFIG; else KUBECONFIG=''; fi
    run run_tool list
    [ "$status" -eq 0 ]
    assert_contains "$output" 'external' 'irrelevant colon-prefix directories must not reject the literal HOME default'
    assert_no_artifacts
  done
  create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_token_bytes "$TMP_HOME/sentinel" work "$HOME/.kube/config"
  assert_no_artifacts
}

@test "colon HOME default FIFO and symlink-to-FIFO are rejected promptly for unset and empty KUBECONFIG" {
  local mode kind default
  HOME="$TMP_HOME/prefix:home"
  default="$HOME/.kube/config"
  mkdir -p "${default%/*}" "$TMP_HOME/prefix"
  mkfifo "$HOME/pipe"
  for kind in fifo symlink; do
    if [ "$kind" = fifo ]; then mkfifo "$default"; else ln -s "$HOME/pipe" "$default"; fi
    for mode in unset empty; do
      if [ "$mode" = unset ]; then unset KUBECONFIG; else KUBECONFIG=''; fi
      run k8s_test_env timeout 5 "$TOOL" list
      [ "$status" -ne 0 ]
      [ "$status" -ne 124 ]
      assert_contains "$output" 'unsafe kubeconfig input (nonregular file)' 'literal FIFO must be checked before kubectl opens it'
      assert_no_artifacts
    done
    rm "$default"
  done
  [ -p "$HOME/pipe" ]
}

@test "colon HOME default regular links remain readable while mutation still rejects them" {
  local mode kind default
  HOME="$TMP_HOME/prefix:home"
  default="$HOME/.kube/config"
  mkdir -p "${default%/*}" "$TMP_HOME/prefix"
  seed_basic "$HOME/regular"
  for kind in symlink hardlink; do
    if [ "$kind" = symlink ]; then ln -s "$HOME/regular" "$default"; else ln "$HOME/regular" "$default"; fi
    for mode in unset empty; do
      if [ "$mode" = unset ]; then unset KUBECONFIG; else KUBECONFIG=''; fi
      run run_tool list
      [ "$status" -eq 0 ]
      assert_contains "$output" 'external' 'literal regular default links must retain read-only kubectl semantics'
      run run_tool create </dev/null
      [ "$status" -ne 0 ]
      assert_contains "$output" 'unsafe kubeconfig path' 'mutation still refuses linked defaults'
      assert_no_artifacts
    done
    rm "$default"
  done
}

@test "relative multi-file create beneath colon cwd stays representable and never flattens split resources" {
  HOME="$TMP_HOME/literal:home"
  mkdir "$HOME"
  seed_split_owned
  KUBECONFIG='context/config:cluster/config:user/config'
  (
    cd "$HOME"
    create_profile new-profile >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr '' '.["current-context"] == "work" and [.contexts[].name] == ["new-profile","work"]'
    assert_token_bytes "$TMP_HOME/sentinel" new-profile ''
  )
  assert_same_file "$HOME/cluster/config" "$TMP_HOME/before-cluster" 'untouched split cluster/current state must retain physical bytes'
  assert_same_file "$HOME/user/config" "$TMP_HOME/before-user" 'untouched split credentials must not be flattened'
  assert_no_artifacts
}

@test "relative multi-file update beneath colon cwd validates ALL candidates and preserves split current state" {
  HOME="$TMP_HOME/literal:home"
  mkdir "$HOME"
  seed_split_owned
  KUBECONFIG='context/config:cluster/config:user/config'
  printf '%s' 'K8S_COLON_CWD_REPLACEMENT_SENTINEL' >"$TMP_HOME/replacement"
  (
    cd "$HOME"
    update_profile 1 https://replacement.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr '' '.["current-context"] == "work" and .contexts[0].context.cluster == "k8s-profile:work:cluster:2"'
    assert_token_bytes "$TMP_HOME/replacement" work ''
  )
  assert_config_expr "$HOME/cluster/config" '(.clusters // [] | length) == 0 and .["current-context"] == "hidden-other"'
  assert_config_expr "$HOME/user/config" '(.users // [] | length) == 0'
  assert_no_artifacts
}

@test "relative multi-file delete beneath colon cwd clears hidden current fallbacks without flattening neighbours" {
  HOME="$TMP_HOME/literal:home"
  mkdir "$HOME"
  seed_split_owned
  seed_basic "$HOME/neighbour/config" neighbour neighbour-cluster neighbour-user neighbour
  KUBECONFIG='context/config:cluster/config:user/config:neighbour/config'
  (
    cd "$HOME"
    delete_profile 2 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr '' '(.contexts | length) == 1 and .contexts[0].name == "neighbour" and (.["current-context"] // "") == ""'
  )
  assert_config_expr "$HOME/context/config" '(.contexts // [] | length) == 0 and (.users // [] | length) == 0 and (.clusters // [] | length) == 0'
  assert_config_expr "$HOME/neighbour/config" '.contexts[0].name == "neighbour" and .users[0].user.token == $token and (.["current-context"] // "") == ""' --rawfile token "$TMP_HOME/sentinel"
  assert_no_artifacts
}

@test "invalid UTF-8 Token bytes reject create and pending update rather than publishing replacement characters" {
  local encoded action
  seed_basic "$KUBECONFIG" work cluster user work
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for encoded in 'invalid\377token' 'invalid\300\257token' 'invalid\355\240\200token' 'invalid\342\202' 'invalid\364\220\200\200token'; do
    printf '%b' "$encoded" >"$TMP_HOME/invalid-token"
    for action in create update; do
      if [ "$action" = create ]; then
        if {
          printf 'another\nhttps://api.invalid\n'
          builtin printf '%s\n' "$(<"$TMP_HOME/invalid-token")"
        } | run_tool create >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'invalid UTF-8 create must fail'; fi
      else
        if update_profile 1 https://not-published.invalid "$TMP_HOME/invalid-token" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'invalid UTF-8 update must fail'; fi
      fi
      assert_contains "$(<"$TMP_HOME/stderr")" 'Token must be valid UTF-8' 'invalid bytes must be rejected before serialization changes them'
      assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'invalid encoding must preserve all prior configuration bytes'
      if grep -F -q -f "$TMP_HOME/invalid-token" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'invalid Token bytes leaked in diagnostics'; fi
      assert_no_artifacts
    done
  done
}

@test "accepted UTF-8 Token bytes including quotes backslashes combining text and replacement codepoints round trip EXACTLY" {
  printf '%s' 'K8S_EXACT_é_漢_🔑_é_�_"_\_END' >"$TMP_HOME/sentinel"
  create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_token_bytes "$TMP_HOME/sentinel"
  printf '%s' 'K8S_UPDATED_ß_字_🔒_ä_�_"_\_END' >"$TMP_HOME/replacement"
  update_profile 1 '' "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_token_bytes "$TMP_HOME/replacement"
  if grep -F -q -f "$TMP_HOME/sentinel" -f "$TMP_HOME/replacement" "$TMP_HOME/stdout" "$TMP_HOME/stderr"; then fail 'accepted Unicode Token leaked'; fi
  assert_no_artifacts
}

@test "Unicode whitespace and C1 control Token input is rejected without narrowing valid Unicode to ASCII" {
  local encoded
  seed_basic "$KUBECONFIG"
  cp "$KUBECONFIG" "$TMP_HOME/before"
  for encoded in 'K8S_BAD_\302\240_END' 'K8S_BAD_\342\200\203_END' 'K8S_BAD_\342\200\250_END' 'K8S_BAD_\302\205_END' 'K8S_BAD_\302\233_END'; do
    printf '%b' "$encoded" >"$TMP_HOME/sentinel"
    if create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'Unicode whitespace/control Token must fail'; fi
    assert_contains "$(<"$TMP_HOME/stderr")" 'no whitespace or controls' 'UTF-8 credential policy must cover Unicode whitespace and C1 controls'
    assert_same_file "$KUBECONFIG" "$TMP_HOME/before" 'Unicode policy failure must preserve existing config'
    assert_no_artifacts
  done
}

@test "operational dependency input and minimum-version policies agree in help and README" {
  run run_tool --help
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Bash 4.4+' 'help must advertise the verified mutation minimum'
  assert_not_contains "$output" 'Bash 4.3' 'unsupported empty-array behavior must not be advertised'
  assert_contains "$output" 'Token must be valid UTF-8' 'help must document the byte-preserving encoding policy'
  assert_contains "$output" 'cmp' 'exact-byte comparison dependency must be documented'
  assert_contains "$output" 'stty' 'terminal-mode dependency must be documented'
  assert_contains "$(<"$REPO_ROOT/README.md")" 'Bash **4.4+**' 'README minimum must match the guard/help'
  assert_contains "$(<"$REPO_ROOT/README.md")" 'mandatory **valid UTF-8**' 'README input policy must match the implementation'
}

@test "missing cmp or stty fails the operational dependency check before prompts or writes" {
  local missing name restricted
  local -a commands=()
  for missing in cmp stty; do
    commands=()
    for name in bash dirname kubectl jq awk mktemp chmod cp rm mkdir rmdir stat sha256sum cmp stty mv ln; do
      [ "$name" = "$missing" ] || commands+=("$name")
    done
    restricted=$(path_with_commands "$TMP_HOME/without-$missing" "${commands[@]}")
    run k8s_test_env env PATH="$restricted" "$TOOL" create </dev/null
    [ "$status" -ne 0 ]
    assert_contains "$output" "missing required tools: $missing" 'new input/encoding dependencies must be checked explicitly'
    assert_not_contains "$output" 'Name:' 'dependency errors must precede prompts'
    assert_file_not_exists "$KUBECONFIG" 'dependency errors must not write config'
    assert_no_artifacts
  done
}

@test "invalid direct staged Token encoding fails before any candidate lock or directory is created" {
  printf 'K8S_DIRECT_INVALID_\377_END' >"$TMP_HOME/invalid-token"
  K8S_TEST_TARGET="$TMP_HOME/invalid-token"
  run run_module_script '
    k8s_profile_init
    k8s_profile_snapshot_chain
    k8s_profile_plan_change work https://api.invalid true true
    if k8s_profile_stage_change "$K8S_TEST_TARGET"; then exit 9; fi
    [ "${#K8S_PROFILE_TX_WRITE_SET[@]}" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Token must be valid UTF-8' 'the mutation boundary must enforce encoding, not only the interactive prompt'
  assert_file_not_exists "$KUBECONFIG" 'invalid staged Token must not create config'
  [ ! -d "$HOME/.kube" ]
  assert_no_artifacts
}

@test "relative bare filenames beneath colon cwd retain a relative same-directory candidate spelling" {
  HOME="$TMP_HOME/literal:home"
  mkdir "$HOME"
  seed_basic "$HOME/one" one one-cluster one-user
  seed_basic "$HOME/two/config" two two-cluster two-user two
  cp "$HOME/two/config" "$TMP_HOME/before-two"
  KUBECONFIG='one:two/config'
  (
    cd "$HOME"
    create_profile work >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr '' '.["current-context"] == "two" and (.contexts | length) == 3'
  )
  assert_same_file "$HOME/two/config" "$TMP_HOME/before-two" 'bare relative candidates must not flatten untouched files'
  assert_no_artifacts
}
