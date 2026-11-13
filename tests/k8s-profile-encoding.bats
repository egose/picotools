#!/usr/bin/env bats
# shellcheck disable=SC2016 # jq variables belong to private fixture programs.
# shellcheck disable=SC2030,SC2031 # Bats setup resets every isolated fixture.
# shellcheck disable=SC2034 # Test-control globals are consumed by helpers.

load 'helpers/k8s-profile'

seed_separator_extensions() {
  local keys="${1:-true}"
  printf '%s' 'K8S_SEPARATOR_TOKEN_é_🔑_é_�_"_\_END' >"$TMP_HOME/sentinel"
  "$K8S_TEST_REAL_JQ" -n --argjson keys "$keys" '
    "nonBMP-🔑-combining-e\u0301-replacement-\ufffd" as $text |
    {scalar_line:("before\u2028after-" + $text), scalar_paragraph:("before\u2029after-" + $text),
     nested:[{value:$text}], del:"\u007f", c1:"\u009b"} |
    if $keys then . + {
      ("line\u2028key-" + $text):{("paragraph\u2029key-" + $text):["\u2028", "\u2029", $text]},
      ("paragraph\u2029key-" + $text):$text
    } else . end
  ' >"$TMP_HOME/expected-extension.json"
  mkdir -p "${KUBECONFIG%/*}"
  # Fixtures independently escape parser-sensitive BMP characters, never
  # non-BMP surrogate pairs. Do not use the production serializer to seed them.
  "$K8S_TEST_REAL_JQ" -j -n --rawfile token "$TMP_HOME/sentinel" --slurpfile extension "$TMP_HOME/expected-extension.json" '
    [{name:"unicode-preserved",extension:$extension[0]}] as $extensions |
    {apiVersion:"v1",kind:"Config",extensions:$extensions,preferences:{extensions:$extensions},
     contexts:[{name:"work",context:{cluster:"shared-cluster",user:"shared-user",namespace:"kept",extensions:$extensions}},
               {name:"neighbour",context:{cluster:"shared-cluster",user:"shared-user",namespace:"neighbour-kept",extensions:$extensions}}],
     clusters:[{name:"shared-cluster",cluster:{server:"https://old.invalid:6443",extensions:$extensions}}],
     users:[{name:"shared-user",user:{token:$token,extensions:$extensions}}],"current-context":"neighbour"} |
    tojson | split("\u2028") | join("\\u2028") | split("\u2029") | join("\\u2029") |
    split("\u007f") | join("\\u007f") | split("\u009b") | join("\\u009b")
  ' >"$KUBECONFIG"
  chmod 600 "$KUBECONFIG"
  read_config_json "$TMP_HOME/before-unicode.json" "$KUBECONFIG"
}

assert_separator_extensions() {
  local config="${1:-$KUBECONFIG}"
  read_config_json "$TMP_HOME/after-unicode.json" "$config"
  "$K8S_TEST_REAL_JQ" -e --slurpfile expected "$TMP_HOME/expected-extension.json" '
    [.extensions[]?, .preferences.extensions[]?, .contexts[]?.context.extensions[]?,
     .clusters[]?.cluster.extensions[]?, .users[]?.user.extensions[]?] |
    map(select(.name == "unicode-preserved")) |
    length >= 5 and all(.extension == $expected[0])
  ' "$TMP_HOME/after-unicode.json" >/dev/null 2>"$TMP_HOME/fixture-diagnostics" || fail 'separator keys or Unicode values were lost or changed'
}

seed_native_origin() {
  local origin="$1" shared="${2:-true}" base="${3:-$HOME}"
  K8S_ENCODING_CONTEXT="$base/contexts/config"
  K8S_ENCODING_CLUSTER="$origin/config"
  K8S_ENCODING_USER="$base/users/config"
  K8S_ENCODING_CA="$origin/trust/ca.pem"
  K8S_ENCODING_CERT="$base/users/material/cert.pem"
  K8S_ENCODING_KEY="$base/users/material/key.pem"
  K8S_ENCODING_TOKENFILE="$base/users/material/external.token"
  mkdir -p "${K8S_ENCODING_CONTEXT%/*}" "$origin/trust" "$base/users/material"
  "$K8S_TEST_REAL_JQ" -n --argjson shared "$shared" '
    {apiVersion:"v1",kind:"Config",contexts:
      ([{name:"work",context:{cluster:"external-cluster",user:"external-user",namespace:"kept"}}] +
       if $shared then [{name:"neighbour",context:{cluster:"external-cluster",user:"external-user",namespace:"neighbour-kept"}}] else [] end),
     "current-context":"work"}
  ' >"$K8S_ENCODING_CONTEXT"
  cat >"$K8S_ENCODING_CLUSTER" <<'EOF'
{"apiVersion":"v1","kind":"Config","clusters":[{"name":"external-cluster","cluster":{"server":"https://old.invalid:6443","certificate-authority":"trust/ca.pem"}}]}
EOF
  "$K8S_TEST_REAL_JQ" -n --rawfile token "$TMP_HOME/sentinel" '
    {apiVersion:"v1",kind:"Config",users:[{name:"external-user",user:{token:$token,tokenFile:"material/external.token",
      "client-certificate":"material/cert.pem","client-key":"material/key.pem"}}]}
  ' >"$K8S_ENCODING_USER"
  printf 'synthetic CA material, never validated or opened by the tool\n' >"$K8S_ENCODING_CA"
  printf 'synthetic certificate material\n' >"$K8S_ENCODING_CERT"
  printf 'synthetic key material\n' >"$K8S_ENCODING_KEY"
  builtin printf '%s' "$(<"$TMP_HOME/sentinel")" >"$K8S_ENCODING_TOKENFILE"
  chmod 600 "$K8S_ENCODING_CONTEXT" "$K8S_ENCODING_CLUSTER" "$K8S_ENCODING_USER" "$K8S_ENCODING_CA" "$K8S_ENCODING_CERT" "$K8S_ENCODING_KEY" "$K8S_ENCODING_TOKENFILE"
  KUBECONFIG="$K8S_ENCODING_CONTEXT:$K8S_ENCODING_CLUSTER:$K8S_ENCODING_USER"
  snapshot_native_origin
}

snapshot_native_origin() {
  local file index=0
  : >"$TMP_HOME/material-metadata-before"
  for file in "$K8S_ENCODING_CONTEXT" "$K8S_ENCODING_CLUSTER" "$K8S_ENCODING_USER" "$K8S_ENCODING_CA" "$K8S_ENCODING_CERT" "$K8S_ENCODING_KEY" "$K8S_ENCODING_TOKENFILE"; do
    cp -- "$file" "$TMP_HOME/material-before-$index"
    stat --printf='%d:%i:%h:%u:%f:%s:%y:%z\n' -- "$file" >>"$TMP_HOME/material-metadata-before"
    index=$((index + 1))
  done
  find "$HOME" -type d -print0 | sort -z >"$TMP_HOME/directories-before"
}

assert_native_origin_unchanged() {
  local file index=0
  : >"$TMP_HOME/material-metadata-after"
  for file in "$K8S_ENCODING_CONTEXT" "$K8S_ENCODING_CLUSTER" "$K8S_ENCODING_USER" "$K8S_ENCODING_CA" "$K8S_ENCODING_CERT" "$K8S_ENCODING_KEY" "$K8S_ENCODING_TOKENFILE"; do
    assert_same_file "$file" "$TMP_HOME/material-before-$index" 'refused mutation must preserve configuration and external material bytes'
    stat --printf='%d:%i:%h:%u:%f:%s:%y:%z\n' -- "$file" >>"$TMP_HOME/material-metadata-after"
    index=$((index + 1))
  done
  assert_same_file "$TMP_HOME/material-metadata-after" "$TMP_HOME/material-metadata-before" 'refused mutation must preserve material identity permissions and timestamps'
  find "$HOME" -type d -print0 | sort -z >"$TMP_HOME/directories-after"
  assert_same_file "$TMP_HOME/directories-after" "$TMP_HOME/directories-before" 'refusal must not create partial destination directories'
  assert_no_artifacts
}

assert_encoding_refusal() {
  [ "$status" -ne 0 ] || fail 'unrepresentable mutation paths must fail rather than publish lossy metadata'
  assert_contains "$output" 'must be valid UTF-8' 'path encoding refusal must give a controlled useful error'
  assert_not_contains "$output" 'Name:' 'encoding refusal must precede prompts'
  assert_not_contains "$output" 'Select profile' 'encoding refusal must precede selection'
  assert_not_contains "$output" 'Saved profile' 'encoding refusal must not report publication'
  assert_not_contains "$output" 'Updated profile' 'encoding refusal must not report update'
  assert_not_contains "$output" 'Deleted profile' 'encoding refusal must not report deletion'
  printf '%s' "$output" >"$TMP_HOME/refusal-output"
  "$K8S_TEST_REAL_PYTHON" - "$TMP_HOME/refusal-output" "$TMP_HOME/sentinel" <<'PY'
import sys
from pathlib import Path
output = Path(sys.argv[1]).read_bytes()
assert b"\xff" not in output
assert Path(sys.argv[2]).read_bytes() not in output
PY
}

@test "create preserves U2028 U2029 extension object keys together with scalar nonBMP combining replacement Unicode and exact Token" {
  seed_separator_extensions
  create_profile new >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_separator_extensions
  assert_token_bytes "$TMP_HOME/sentinel" new
  assert_token_bytes "$TMP_HOME/sentinel" neighbour
  assert_config_expr "$KUBECONFIG" '.["current-context"] == "neighbour" and (.contexts | length) == 3'
  assert_no_artifacts
}

@test "update copies shared separator-key extensions exactly without changing neighbouring Unicode or Token bytes" {
  seed_separator_extensions
  printf '%s' 'K8S_SEPARATOR_REPLACEMENT_漢_🔒_ä_�_"_\_END' >"$TMP_HOME/replacement"
  update_profile 2 https://updated.invalid:7443 "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_separator_extensions
  assert_token_bytes "$TMP_HOME/replacement" work
  assert_token_bytes "$TMP_HOME/sentinel" neighbour
  assert_config_expr "$KUBECONFIG" '
    .["current-context"] == "neighbour" and
    any(.contexts[]; .name == "neighbour" and .context.cluster == "shared-cluster" and .context.user == "shared-user") and
    any(.contexts[]; .name == "work" and .context.cluster == "k8s-profile:work:cluster:1" and .context.user == "k8s-profile:work:user:1")
  '
  assert_no_artifacts
}

@test "delete preserves separator keys and scalar Unicode in every remaining extension while keeping shared exact Token" {
  seed_separator_extensions
  delete_profile 2 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_separator_extensions
  assert_token_bytes "$TMP_HOME/sentinel" neighbour
  assert_config_expr "$KUBECONFIG" '.["current-context"] == "neighbour" and [.contexts[].name] == ["neighbour"]'
  assert_no_artifacts
}

@test "scalar U2028 U2029 values remain supported through create update delete and are not misclassified as invalid input" {
  seed_separator_extensions false
  create_profile new >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_separator_extensions
  printf '%s' 'K8S_SCALAR_REPLACEMENT_é_🔑_é_�_END' >"$TMP_HOME/replacement"
  update_profile 2 https://updated.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_separator_extensions
  assert_token_bytes "$TMP_HOME/replacement" new
  delete_profile 2 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
  assert_separator_extensions
  assert_token_bytes "$TMP_HOME/sentinel" neighbour
  assert_no_artifacts
}

@test "config serializer escapes both separators without emitting nonBMP surrogate pairs or changing decoded objects" {
  seed_separator_extensions
  K8S_TEST_TARGET="$TMP_HOME/serialized.json"
  run run_module_script '
    k8s_profile_init
    k8s_profile_write_config "$K8S_TEST_TARGET" "unable to serialize private fixture" . "$KUBECONFIG"
  '
  [ "$status" -eq 0 ]
  assert_separator_extensions "$TMP_HOME/serialized.json"
  assert_token_bytes "$TMP_HOME/sentinel" work "$TMP_HOME/serialized.json"
  k8s_test_env "$K8S_TEST_REAL_PYTHON" - "$TMP_HOME/serialized.json" <<'PY'
import sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
assert b"\\u2028" in data and b"\\u2029" in data
assert "\u2028".encode() not in data and "\u2029".encode() not in data
assert "🔑".encode() in data and "�".encode() in data
assert b"\\ud83d" not in data.lower()
PY
  assert_no_artifacts
}

@test "invalid native split or shared cluster origin is still listable but all mutations refuse before rebasing or writing material" {
  local shared index
  for shared in false true; do
    seed_native_origin "$HOME/origin-$shared-"$'\xff' "$shared"
    read_config_json "$TMP_HOME/native-before.json"
    run run_tool list
    [ "$status" -eq 0 ]
    assert_contains "$output" 'work' 'native-byte origins must retain read-only kubectl discovery'
    index=1
    if [ "$shared" = true ]; then index=2; fi
    run create_profile another
    assert_encoding_refusal
    assert_native_origin_unchanged
    run update_profile "$index" https://must-not-publish.invalid
    assert_encoding_refusal
    assert_native_origin_unchanged
    run delete_profile "$index"
    assert_encoding_refusal
    assert_native_origin_unchanged
  done
}

@test "ASCII relative chain spelling beneath invalid-byte cwd cannot hide unrepresentable absolute origins" {
  local cwd="$HOME/cwd-"$'\xff'
  mkdir "$cwd"
  seed_native_origin "$cwd/cluster" true "$cwd"
  KUBECONFIG='contexts/config:cluster/config:users/config'
  (
    cd "$cwd"
    run run_tool list
    [ "$status" -eq 0 ]
    assert_contains "$output" 'work' 'read-only relative loading under a native-byte cwd remains supported'
    run update_profile 2 https://must-not-publish.invalid
    assert_encoding_refusal
    assert_native_origin_unchanged
  )
}

@test "invalid native missing target or cwd spelling creates no hidden config or partial directories" {
  local cwd="$HOME/cwd-"$'\xff' target="$HOME/target-"$'\xff'
  mkdir "$cwd"
  KUBECONFIG="$target/new/nested/config"
  run create_profile work
  assert_encoding_refusal
  assert_file_not_exists "$KUBECONFIG" 'invalid target must not be published'
  [ ! -d "$target" ]
  assert_no_artifacts
  (
    cd "$cwd"
    KUBECONFIG='new/nested/config'
    run create_profile work
    assert_encoding_refusal
    [ ! -d "$cwd/new" ]
    assert_no_artifacts
  )
}

@test "invalid native HOME default remains readable while mutation refuses its actual origin encoding" {
  HOME="$TMP_HOME/home-"$'\xff'
  mkdir "$HOME"
  seed_basic "$HOME/.kube/config" work cluster user work
  cp "$HOME/.kube/config" "$TMP_HOME/default-before"
  unset KUBECONFIG
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'work' 'literal native HOME default must remain readable'
  run update_profile 1 https://must-not-publish.invalid
  assert_encoding_refusal
  assert_same_file "$HOME/.kube/config" "$TMP_HOME/default-before" 'invalid HOME origin refusal must preserve original config'
  assert_no_artifacts
}

@test "invalid native recovery workspace encoding refuses mutation but does not narrow read-only listing" {
  seed_native_origin "$HOME/valid-origin"
  TMPDIR="$HOME/workspace-"$'\xff'
  mkdir "$TMPDIR"
  snapshot_native_origin
  run run_tool list
  [ "$status" -eq 0 ]
  assert_contains "$output" 'work' 'read-only list may use a safe native-byte workspace'
  run update_profile 2 https://must-not-publish.invalid
  assert_encoding_refusal
  assert_native_origin_unchanged
  run create_profile another
  assert_encoding_refusal
  assert_native_origin_unchanged
  run delete_profile 2
  assert_encoding_refusal
  assert_native_origin_unchanged
}

@test "legitimate replacement-character nonBMP combining space and separator directories preserve exact CA origin through lifecycle" {
  local name origin
  for name in 'origin-�' 'origin-🔑-é-é' $'origin-line\u2028paragraph\u2029- space'; do
    origin="$HOME/$name"
    seed_native_origin "$origin"
    create_profile another >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_token_bytes "$TMP_HOME/sentinel" another "$K8S_ENCODING_CONTEXT"
    update_profile 3 https://updated.invalid:7443 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr "$K8S_ENCODING_CONTEXT" '
      (.contexts[] | select(.name == "work")).context.cluster == "k8s-profile:work:cluster:1" and
      (.clusters[] | select(.name == "k8s-profile:work:cluster:1")).cluster["certificate-authority"] == $ca and
      .["current-context"] == "work"
    ' --arg ca "$K8S_ENCODING_CA"
    read_config_json "$TMP_HOME/rebased.json" "$K8S_ENCODING_CONTEXT"
    "$K8S_TEST_REAL_JQ" -j '.clusters[] | select(.name == "k8s-profile:work:cluster:1") | .cluster["certificate-authority"]' \
      "$TMP_HOME/rebased.json" >"$TMP_HOME/rebased-path"
    printf '%s' "$K8S_ENCODING_CA" >"$TMP_HOME/expected-path"
    assert_same_file "$TMP_HOME/rebased-path" "$TMP_HOME/expected-path" 'valid Unicode CA origins must round-trip byte-for-byte, including actual replacement characters'
    assert_same_file "$K8S_ENCODING_CLUSTER" "$TMP_HOME/material-before-1" 'shared source config must retain its bytes'
    assert_same_file "$K8S_ENCODING_USER" "$TMP_HOME/material-before-2" 'server-only update must not copy or modify authentication'
    assert_same_file "$K8S_ENCODING_CA" "$TMP_HOME/material-before-3" 'rebasing must not open or change CA material'
    assert_same_file "$K8S_ENCODING_KEY" "$TMP_HOME/material-before-5" 'rebasing must retain external key material'
    assert_same_file "$K8S_ENCODING_TOKENFILE" "$TMP_HOME/material-before-6" 'rebasing must retain external Token material'
    delete_profile 3 >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"
    assert_config_expr '' '.["current-context"] == "" and [.contexts[].name] == ["another","neighbour"]'
    assert_token_bytes "$TMP_HOME/sentinel" neighbour ''
    assert_no_artifacts
  done
}

@test "valid Unicode target and recovery workspace paths are represented exactly in retained JSON recovery metadata" {
  HOME="$TMP_HOME/home-�-é-🔑-é"
  TMPDIR="$HOME/workspace-�-🔒"
  mkdir -p "$TMPDIR"
  seed_split_owned
  printf '%s' 'K8S_UNICODE_RECOVERY_REPLACEMENT_é_🔑' >"$TMP_HOME/replacement"
  K8S_TEST_SCENARIO=newer-recovery
  install_failure_wrappers
  if update_profile 1 https://updated.invalid "$TMP_HOME/replacement" >"$TMP_HOME/stdout" 2>"$TMP_HOME/stderr"; then fail 'injected newer-edit recovery must fail'; fi
  local recovery
  recovery=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d -name 'k8s-profile.*')
  assert_file_exists "$recovery/recovery.json" 'valid Unicode recovery paths must remain representable'
  "$K8S_TEST_REAL_JQ" -j '.files[0].path' "$recovery/recovery.json" >"$TMP_HOME/recovery-path"
  printf '%s' "$HOME/context/config" >"$TMP_HOME/expected-path"
  assert_same_file "$TMP_HOME/recovery-path" "$TMP_HOME/expected-path" 'reported target path must retain exact Unicode bytes'
  "$K8S_TEST_REAL_JQ" -j '.files[0].backup' "$recovery/recovery.json" >"$TMP_HOME/recovery-backup"
  printf '%s' "$recovery/backup-0" >"$TMP_HOME/expected-backup"
  assert_same_file "$TMP_HOME/recovery-backup" "$TMP_HOME/expected-backup" 'reported backup path must retain exact Unicode workspace bytes'
  assert_mode "$recovery" 700 'retained recovery directory must remain private'
  if grep -F -q -f "$TMP_HOME/sentinel" -f "$TMP_HOME/replacement" "$TMP_HOME/stdout" "$TMP_HOME/stderr" "$recovery/recovery.json"; then fail 'path recovery metadata must not disclose credentials'; fi
  [ -z "$(find "$HOME" \( -name '.k8s-profile.*' -o -name '*.lock' \) -print)" ]
}
