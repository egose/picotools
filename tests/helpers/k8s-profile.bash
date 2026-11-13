#!/usr/bin/env bash
# shellcheck disable=SC2016 # Fixture jq programs intentionally use jq variables.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/k8s-profile"

# Resolve asdf shims BEFORE HOME isolation. No helper may look up an executable
# through the developer's home/config after setup switches to disposable state.
k8s_test_resolve_binary() {
  local name="$1" candidate
  candidate=$(command -v "$name") || {
    printf 'Required test dependency missing: %s\n' "$name" >&2
    return 1
  }
  case "$candidate" in
  */shims/*)
    candidate=$(asdf which "$name") || return 1
    ;;
  esac
  [ -x "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

K8S_TEST_REAL_KUBECTL=$(k8s_test_resolve_binary kubectl) || return 1
K8S_TEST_REAL_JQ=$(k8s_test_resolve_binary jq) || return 1
K8S_TEST_REAL_MV=$(k8s_test_resolve_binary mv) || return 1
K8S_TEST_REAL_LN=$(k8s_test_resolve_binary ln) || return 1
K8S_TEST_REAL_CP=$(k8s_test_resolve_binary cp) || return 1
K8S_TEST_REAL_CHMOD=$(k8s_test_resolve_binary chmod) || return 1
K8S_TEST_REAL_ENV=$(k8s_test_resolve_binary env) || return 1
K8S_TEST_REAL_STAT=$(k8s_test_resolve_binary stat) || return 1
K8S_TEST_REAL_STTY=$(k8s_test_resolve_binary stty) || return 1
# shellcheck disable=SC2034 # Used by the separately loaded PTY helper.
K8S_TEST_REAL_PYTHON=$(k8s_test_resolve_binary python3) || return 1

setup() {
  local fixture_parent="${K8S_PROFILE_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
  K8S_TEST_CLEANUP_PATH="$PATH"
  if [ -z "${K8S_PROFILE_TEST_TMPDIR:-}" ] && [ -d /tmp/opencode ]; then
    fixture_parent=/tmp/opencode
  fi
  TMP_HOME=$(mktemp -d "$fixture_parent/k8s-profile-tests.XXXXXX") || return 1
  export TMP_HOME HOME="$TMP_HOME/home" TMPDIR="$TMP_HOME/tmp"
  export XDG_CONFIG_HOME="$TMP_HOME/xdg/config" XDG_DATA_HOME="$TMP_HOME/xdg/data"
  export XDG_CACHE_HOME="$TMP_HOME/xdg/cache" XDG_STATE_HOME="$TMP_HOME/xdg/state"
  export XDG_RUNTIME_DIR="$TMP_HOME/xdg/run" KUBECTL_KUBERC=false
  export KUBECONFIG="$HOME/.kube/config"
  mkdir -p "$HOME" "$TMPDIR" "$TMP_HOME/bin" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
  chmod 700 "$TMP_HOME" "$HOME" "$TMPDIR" "$XDG_RUNTIME_DIR"
  ln -s "$K8S_TEST_REAL_KUBECTL" "$TMP_HOME/bin/kubectl"
  ln -s "$K8S_TEST_REAL_JQ" "$TMP_HOME/bin/jq"
  export PATH="$TMP_HOME/bin:$PATH"
  # Synthetic credentials enter fixture writers through files, not argv/env.
  printf '%s' 'K8S_SYNTHETIC_CREDENTIAL_SENTINEL' >"$TMP_HOME/sentinel"
  chmod 600 "$TMP_HOME/sentinel"
  K8S_TEST_SCENARIO=''
  K8S_TEST_TARGET=''
  K8S_TEST_OTHER=''
  K8S_TEST_TOOL="$TOOL"
}

teardown() {
  # Auditing rm itself must not leave Bats with a hashed wrapper path after
  # its fixture has been removed; restore the pre-fixture PATH first.
  PATH="$K8S_TEST_CLEANUP_PATH"
  hash -r
  if [ -n "${TMP_HOME:-}" ]; then
    rm -rf -- "$TMP_HOME"
  fi
}

# Empty environment prevents personal credential variables, kuberc, plugins,
# and configuration from influencing operations or credential-audit logs.
k8s_test_env() {
  local -a kubeconfig_env=()
  if [ "${KUBECONFIG+x}" = x ]; then
    kubeconfig_env=("KUBECONFIG=$KUBECONFIG")
  fi
  "$K8S_TEST_REAL_ENV" -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    KUBECTL_KUBERC=false LC_ALL=C TERM=dumb "${kubeconfig_env[@]}" \
    K8S_TEST_REAL_KUBECTL="$K8S_TEST_REAL_KUBECTL" K8S_TEST_REAL_JQ="$K8S_TEST_REAL_JQ" \
    K8S_TEST_REAL_MV="$K8S_TEST_REAL_MV" K8S_TEST_REAL_LN="$K8S_TEST_REAL_LN" \
    K8S_TEST_REAL_CP="$K8S_TEST_REAL_CP" K8S_TEST_REAL_CHMOD="$K8S_TEST_REAL_CHMOD" \
    K8S_TEST_REAL_STAT="$K8S_TEST_REAL_STAT" \
    K8S_TEST_REAL_STTY="$K8S_TEST_REAL_STTY" \
    K8S_TEST_REAL_ENV="$K8S_TEST_REAL_ENV" \
    K8S_TEST_COMMAND_BINARIES="$TMP_HOME/audit-binaries" \
    K8S_TEST_SCENARIO="$K8S_TEST_SCENARIO" K8S_TEST_TARGET="$K8S_TEST_TARGET" K8S_TEST_OTHER="$K8S_TEST_OTHER" \
    K8S_TEST_SENTINEL_FILE="$TMP_HOME/sentinel" K8S_TEST_AUDIT_LOG="$TMP_HOME/audit" \
    K8S_TEST_COUNTER="$TMP_HOME/counter" K8S_TEST_MARKER="$TMP_HOME/marker" \
    K8S_TEST_PUBLICATION_LOG="$TMP_HOME/publications" "$@"
}

# Unlike the failure wrappers, this audits EVERY external runtime command,
# including those executed while a newly captured Token is still in scope.
install_environment_audit_wrappers() {
  local name executable
  mkdir -p "$TMP_HOME/environment-audit" "$TMP_HOME/audit-binaries"
  for name in dirname cat tr awk mktemp chmod cp rm mkdir rmdir stat sha256sum cmp stty mv ln kubectl jq; do
    case "$name" in
    kubectl) executable="$K8S_TEST_REAL_KUBECTL" ;;
    jq) executable="$K8S_TEST_REAL_JQ" ;;
    *) executable=$(command -v "$name") || return 1 ;;
    esac
    printf '%s\n' "$executable" >"$TMP_HOME/audit-binaries/$name"
    ln -s command-wrapper "$TMP_HOME/environment-audit/$name"
  done
  cat >"$TMP_HOME/environment-audit/command-wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set +x
set +a
tool=${0##*/}
if [ -n "${K8S_TEST_AUDIT_LOG:-}" ]; then
  printf '%s\0' "$tool" "$@" >>"$K8S_TEST_AUDIT_LOG"
  "$K8S_TEST_REAL_ENV" -0 >>"$K8S_TEST_AUDIT_LOG"
fi
IFS= read -r executable <"${K8S_TEST_COMMAND_BINARIES:-$TMP_HOME/audit-binaries}/$tool"
exec "$executable" "$@"
EOF
  chmod +x "$TMP_HOME/environment-audit/command-wrapper"
  PATH="$TMP_HOME/environment-audit:$PATH"
}

assert_token_bytes() {
  local token_file="$1" profile="${2:-work}" config="${3-$KUBECONFIG}"
  read_config_json "$TMP_HOME/token-round-trip.json" "$config" || return 1
  "$K8S_TEST_REAL_JQ" -j --arg profile "$profile" '
    . as $config | [.contexts[] | select(.name == $profile)][0].context.user as $user |
    [$config.users[] | select(.name == $user)][0].user.token
  ' "$TMP_HOME/token-round-trip.json" >"$TMP_HOME/token-round-trip" 2>"$TMP_HOME/fixture-diagnostics" || return 1
  assert_same_file "$token_file" "$TMP_HOME/token-round-trip" 'accepted Token bytes must survive independent kubectl JSON decoding exactly'
}

run_tool() {
  k8s_test_env "$K8S_TEST_TOOL" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"
}

assert_contains() {
  case "$1" in
  *"$2"*) ;;
  *) fail "$3 (missing '$2')" ;;
  esac
}

assert_not_contains() {
  case "$1" in
  *"$2"*) fail "$3 (unexpected matching text)" ;;
  esac
}

assert_file_exists() {
  [ -f "$1" ] || fail "$2"
}

assert_file_not_exists() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail "$2"
  fi
}

assert_mode() {
  assert_eq "$(stat -c %a -- "$1")" "$2" "$3"
}

assert_same_file() {
  cmp -s -- "$1" "$2" || fail "$3"
}

path_with_commands() {
  local dir="$1" name executable
  shift
  mkdir -p "$dir"
  for name in "$@"; do
    case "$name" in
    kubectl) executable="$K8S_TEST_REAL_KUBECTL" ;;
    jq) executable="$K8S_TEST_REAL_JQ" ;;
    *) executable=$(command -v "$name") || return 1 ;;
    esac
    ln -s "$executable" "$dir/$name"
  done
  printf '%s\n' "$dir"
}

write_fixture() {
  local path="$1"
  mkdir -p "${path%/*}"
  cat >"$path"
  "$K8S_TEST_REAL_CHMOD" 600 "$path"
}

seed_basic() {
  local path="$1" context="${2:-external}" cluster="${3:-external-cluster}" user="${4:-external-user}" current="${5:-}"
  mkdir -p "${path%/*}"
  "$K8S_TEST_REAL_JQ" -n --arg context "$context" --arg cluster "$cluster" --arg user "$user" --arg current "$current" \
    --rawfile token "$TMP_HOME/sentinel" '
      {apiVersion:"v1",kind:"Config",preferences:{},clusters:[{name:$cluster,cluster:{server:"https://external.invalid:6443"}}],
       users:[{name:$user,user:{token:$token}}],contexts:[{name:$context,context:{cluster:$cluster,user:$user,namespace:"kept"}}],
       "current-context":$current}
    ' >"$path"
  "$K8S_TEST_REAL_CHMOD" 600 "$path"
}

seed_empty() {
  write_fixture "$1" <<'EOF'
{"apiVersion":"v1","kind":"Config","preferences":{},"clusters":[],"users":[],"contexts":[],"current-context":""}
EOF
}

read_config_json() {
  local output_file="$1" path="${2:-}"
  local -a explicit=()
  if [ -n "$path" ]; then
    explicit=("--kubeconfig=$path")
  fi
  if ! k8s_test_env "$K8S_TEST_REAL_KUBECTL" "${explicit[@]}" config view --raw --merge="$(if [ -n "$path" ]; then printf false; else printf true; fi)" -o json \
    >"$output_file" 2>"$TMP_HOME/fixture-diagnostics"; then
    fail 'real kubectl could not load the disposable fixture'
  fi
}

assert_config_expr() {
  local path="$1" expression="$2"
  shift 2
  read_config_json "$TMP_HOME/assert-config.json" "$path" || return 1
  "$K8S_TEST_REAL_JQ" -e "$@" "$expression" "$TMP_HOME/assert-config.json" >/dev/null 2>"$TMP_HOME/fixture-diagnostics" || fail 'real kubectl configuration assertion failed'
}

create_profile() {
  local name="${1:-work}" server="${2:-https://api.invalid:6443}" confirmation="${3:-}"
  {
    printf '%s\n' "$name"
    if [ -n "$confirmation" ]; then
      printf '%s\n' "$confirmation"
    fi
    printf '%s\n' "$server"
    builtin printf '%s\n' "$(<"$TMP_HOME/sentinel")"
  } | run_tool create
}

update_profile() {
  local index="${1:-1}" server="${2:-}" token_file="${3:-}"
  {
    printf '%s\n' "$index"
    if [ -n "$server" ]; then
      printf '1\n%s\n' "$server"
    fi
    if [ -n "$token_file" ]; then
      printf '2\n2\n'
      builtin printf '%s\n' "$(<"$token_file")"
    fi
    printf '3\n'
  } | run_tool update
}

delete_profile() {
  local index="${1:-1}" confirmation="${2-yes}"
  printf '%s\n%s\n' "$index" "$confirmation" | run_tool delete
}

assert_no_workspace() {
  local leftovers
  leftovers=$(find "$TMPDIR" -mindepth 1 -print)
  [ -z "$leftovers" ] || fail 'tool left a private workspace after a completed/fully recovered operation'
}

assert_no_artifacts() {
  local allow_locks="${1:-false}" leftovers
  if [ "$allow_locks" = true ]; then
    leftovers=$(find "$HOME" -name '.k8s-profile.*' -print)
  else
    leftovers=$(find "$HOME" \( -name '.k8s-profile.*' -o -name '*.lock' \) -print)
  fi
  [ -z "$leftovers" ] || fail 'tool left a stage, restore, or owned lock behind'
  assert_no_workspace
}

install_test_layout() {
  local prefix="$TMP_HOME/install" download="$TMP_HOME/download"
  mkdir -p "$download"
  tar -czf "$download/picotools-test.tar.gz" -C "$REPO_ROOT" VERSION lib -C "$REPO_ROOT/tools" bin lib
  if ! k8s_test_env env ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=test \
    ASDF_INSTALL_PATH="$prefix" ASDF_DOWNLOAD_PATH="$download" \
    "$REPO_ROOT/bin/install" >"$TMP_HOME/install-output" 2>"$TMP_HOME/install-diagnostics"; then
    fail 'release archive installation failed'
    return 1
  fi
  K8S_TEST_TOOL="$prefix/bin/k8s-profile"
}

source_k8s_profile_modules() {
  # shellcheck source=../../lib/picotools/load.sh
  # shellcheck disable=SC1091
  . "$REPO_ROOT/lib/picotools/load.sh"
  picotools_source_modules "$REPO_ROOT/tools/bin" box commands prompt table ui version
  local module
  for module in common config transaction model actions lifecycle; do
    # shellcheck disable=SC1090
    . "$REPO_ROOT/tools/lib/picotools/k8s-profile/$module.sh"
  done
  # shellcheck disable=SC2329 # Called by the sourced modules.
  debug_log() { :; }
}

run_module_script() {
  local script_file="$TMP_HOME/module-test.bash"
  cat >"$script_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$1/lib/picotools/load.sh"
picotools_source_modules "$1/tools/bin" box commands prompt table ui version
for module in common config transaction model actions lifecycle; do
  . "$1/tools/lib/picotools/k8s-profile/$module.sh"
done
debug_log() { :; }
EOF
  builtin printf '%s\n' "$1" >>"$script_file"
  k8s_test_env bash "$script_file" "$REPO_ROOT"
}

# Every wrapper delegates to the real binary unless a particular boundary is
# being failed. This keeps failure injection on the production kubectl engine.
install_failure_wrappers() {
  local name
  mkdir -p "$TMP_HOME/wrappers"
  cat >"$TMP_HOME/wrappers/command-wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tool=${0##*/}
printf '%s\0' "$tool" "$@" >>"$K8S_TEST_AUDIT_LOG"
env -0 >>"$K8S_TEST_AUDIT_LOG"
for argument in "$@"; do
  case "$argument" in
  */token-input)
    printf 'token-mode:%s\n' "$(stat -c %a -- "$argument")" >>"$K8S_TEST_AUDIT_LOG"
    printf 'workspace-mode:%s\n' "$(stat -c %a -- "${argument%/*}")" >>"$K8S_TEST_AUDIT_LOG"
    ;;
  --kubeconfig=*/.k8s-profile.stage.*)
    printf 'stage-mode:%s\n' "$(stat -c %a -- "${argument#--kubeconfig=}")" >>"$K8S_TEST_AUDIT_LOG"
    ;;
  esac
done

diagnostic_failure() {
  cat "$K8S_TEST_SENTINEL_FILE"
  cat "$K8S_TEST_SENTINEL_FILE" >&2
  exit 42
}

external_edit() {
  "$K8S_TEST_REAL_JQ" '
    if ((.contexts // []) | length) > 0 then .contexts[0].context.namespace = "newer-external"
    else .preferences.extensions = [{name:"newer-external",extension:{keep:true}}] end |
    .["current-context"] = "newer-external"
  ' "$1" >"$1.external"
  "$K8S_TEST_REAL_CHMOD" 600 "$1.external"
  "$K8S_TEST_REAL_MV" -fT -- "$1.external" "$1"
}

case "$tool" in
kubectl)
  case "$K8S_TEST_SCENARIO" in
  kubectl-fail) diagnostic_failure ;;
  malformed-json)
    printf '{"apiVersion":"v1","kind":"Config","contexts":"'
    cat "$K8S_TEST_SENTINEL_FILE"
    printf '"}\n'
    exit 0
    ;;
  validation-fail | stale-validation | changed-candidate | candidate-permission | candidate-after-chain)
    for argument in "$@"; do
      case "$argument" in
      --kubeconfig=*/.k8s-profile.stage.*)
        if [ "$K8S_TEST_SCENARIO" = validation-fail ]; then diagnostic_failure; fi
        if [ "$K8S_TEST_SCENARIO" = candidate-after-chain ]; then
          case " $* " in *' --raw '*) exec "$K8S_TEST_REAL_KUBECTL" "$@" ;; esac
        fi
        "$K8S_TEST_REAL_KUBECTL" "$@"
        if [ "$K8S_TEST_SCENARIO" = stale-validation ]; then
          external_edit "$K8S_TEST_TARGET"
        elif [ "$K8S_TEST_SCENARIO" = candidate-permission ]; then
          "$K8S_TEST_REAL_CHMOD" 644 "${argument#--kubeconfig=}"
        else
          external_edit "${argument#--kubeconfig=}"
        fi
        exit 0
        ;;
      esac
    done
    ;;
  verify-fail)
    if [ "$*" = 'config view -o json' ]; then
      count=0
      if [ -f "$K8S_TEST_COUNTER" ]; then count=$(<"$K8S_TEST_COUNTER"); fi
      count=$((count + 1))
      printf '%s' "$count" >"$K8S_TEST_COUNTER"
      if [ "$count" -eq 2 ]; then diagnostic_failure; fi
    fi
    ;;
  esac
  exec "$K8S_TEST_REAL_KUBECTL" "$@"
  ;;
jq)
  case "$K8S_TEST_SCENARIO" in
  jq-fail)
    case " $* " in *' --rawfile token '*) diagnostic_failure ;; esac
    ;;
  newer-recovery-manifest-fail)
    case " $* " in *'No automatic overwrite of newer state.'*) diagnostic_failure ;; esac
    ;;
  delete-stage-fail)
    case " $* " in *'delete_from_file($plan[0]; $index)'*) diagnostic_failure ;; esac
    ;;
  use-stage-fail)
    case " $* " in *'.["current-context"] = $plan[0].profile'*) diagnostic_failure ;; esac
    ;;
  stale-selection | disappeared-selection)
    case " $* " in
    *'.profiles[].name | display_text'*)
      if [ ! -f "$K8S_TEST_MARKER" ]; then
        : >"$K8S_TEST_MARKER"
        if [ "$K8S_TEST_SCENARIO" = stale-selection ]; then
          external_edit "$K8S_TEST_TARGET"
        else
          "$K8S_TEST_REAL_JQ" '.contexts = []' "$K8S_TEST_TARGET" >"$K8S_TEST_TARGET.external"
          "$K8S_TEST_REAL_MV" -fT -- "$K8S_TEST_TARGET.external" "$K8S_TEST_TARGET"
        fi
      fi
      ;;
    esac
    ;;
  stale-delete-plan | stale-use-plan)
    case " $* " in
    *' --slurpfile visible '*)
      if [ ! -f "$K8S_TEST_MARKER" ]; then
        : >"$K8S_TEST_MARKER"
        external_edit "$K8S_TEST_TARGET"
      fi
      ;;
    esac
    ;;
  stale-plan | stale-unaffected)
    case " $* " in
    *' --argjson server_change '*)
      if [ ! -f "$K8S_TEST_MARKER" ]; then
        : >"$K8S_TEST_MARKER"
        external_edit "$K8S_TEST_TARGET"
      fi
      ;;
    esac
    ;;
  esac
  exec "$K8S_TEST_REAL_JQ" "$@"
  ;;
mv)
  source_path="${@: -2:1}"
  destination="${@: -1}"
  case "$source_path" in
  */.k8s-profile.stage.*)
    case "$K8S_TEST_SCENARIO" in
    publish-fail) diagnostic_failure ;;
    second-publish-fail | newer-recovery | newer-recovery-manifest-fail)
      count=0
      if [ -f "$K8S_TEST_COUNTER" ]; then count=$(<"$K8S_TEST_COUNTER"); fi
      count=$((count + 1))
      printf '%s' "$count" >"$K8S_TEST_COUNTER"
      if [ "$count" -eq 2 ]; then
        if [[ "$K8S_TEST_SCENARIO" == newer-recovery* ]]; then external_edit "$K8S_TEST_TARGET"; fi
        diagnostic_failure
      fi
      ;;
    signal-publish)
      "$K8S_TEST_REAL_MV" "$@"
      kill -TERM "$PPID"
      exit 0
      ;;
    signal-second-publish)
      count=0
      if [ -f "$K8S_TEST_COUNTER" ]; then count=$(<"$K8S_TEST_COUNTER"); fi
      count=$((count + 1))
      printf '%s' "$count" >"$K8S_TEST_COUNTER"
      "$K8S_TEST_REAL_MV" "$@"
      if [ "$count" -eq 2 ]; then kill -TERM "$PPID"; fi
      exit 0
      ;;
    observe-publications)
      "$K8S_TEST_REAL_MV" "$@"
      printf 'publish:%s\n' "$destination" >>"$K8S_TEST_PUBLICATION_LOG"
      if "$K8S_TEST_REAL_KUBECTL" config current-context >"$K8S_TEST_PUBLICATION_LOG.current" 2>"$K8S_TEST_PUBLICATION_LOG.diagnostics"; then
        IFS= read -r current <"$K8S_TEST_PUBLICATION_LOG.current"
        printf 'current:%s\n' "$current" >>"$K8S_TEST_PUBLICATION_LOG"
      else
        printf 'current:\n' >>"$K8S_TEST_PUBLICATION_LOG"
      fi
      exit 0
      ;;
    replace-lock)
      "$K8S_TEST_REAL_MV" "$@"
      printf 'newer-lock-owner' >"$destination.lock.new"
      "$K8S_TEST_REAL_MV" -fT -- "$destination.lock.new" "$destination.lock"
      exit 0
      ;;
    esac
    ;;
  esac
  exec "$K8S_TEST_REAL_MV" "$@"
  ;;
ln)
  source_path="${@: -2:1}"
  destination="${@: -1}"
  case "$K8S_TEST_SCENARIO:$destination" in
  signal-lock:*.lock)
    "$K8S_TEST_REAL_LN" "$@"
    kill -TERM "$PPID"
    exit 0
    ;;
  esac
  case "$source_path" in
  */.k8s-profile.stage.*)
    case "$K8S_TEST_SCENARIO" in
    publish-fail) diagnostic_failure ;;
    missing-race)
      printf '{"apiVersion":"v1","kind":"Config","contexts":[{"name":"newer-external","context":{}}]}' >"$destination"
      ;;
    signal-publish)
      "$K8S_TEST_REAL_LN" "$@"
      kill -TERM "$PPID"
      exit 0
      ;;
    esac
    ;;
  esac
  exec "$K8S_TEST_REAL_LN" "$@"
  ;;
cp)
  case "$K8S_TEST_SCENARIO:${@: -1}" in copy-fail:*/.k8s-profile.stage.*) diagnostic_failure ;; esac
  exec "$K8S_TEST_REAL_CP" "$@"
  ;;
chmod)
  case "$K8S_TEST_SCENARIO:${@: -1}" in chmod-fail:*/.k8s-profile.stage.*) diagnostic_failure ;; esac
  exec "$K8S_TEST_REAL_CHMOD" "$@"
  ;;
esac
EOF
  chmod +x "$TMP_HOME/wrappers/command-wrapper"
  for name in kubectl jq mv ln cp chmod; do
    ln -s command-wrapper "$TMP_HOME/wrappers/$name"
  done
  PATH="$TMP_HOME/wrappers:$PATH"
}

seed_split_owned() {
  local context_file="$HOME/context/config" cluster_file="$HOME/cluster/config" user_file="$HOME/user/config"
  write_fixture "$context_file" <<'EOF'
{"apiVersion":"v1","kind":"Config","contexts":[{"name":"work","context":{"cluster":"k8s-profile:work:cluster:1","user":"k8s-profile:work:user:1","namespace":"kept","extensions":[{"name":"picotools.k8s-profile","extension":{"version":1,"profile":"work","role":"context"}}]}}],"current-context":"work"}
EOF
  write_fixture "$cluster_file" <<'EOF'
{"apiVersion":"v1","kind":"Config","clusters":[{"name":"k8s-profile:work:cluster:1","cluster":{"server":"https://old.invalid:6443","certificate-authority":"../trust/ca.pem","extensions":[{"name":"picotools.k8s-profile","extension":{"version":1,"profile":"work","role":"cluster"}}]}}],"current-context":"hidden-other"}
EOF
  mkdir -p "${user_file%/*}"
  "$K8S_TEST_REAL_JQ" -n --rawfile token "$TMP_HOME/sentinel" '
    {apiVersion:"v1",kind:"Config",users:[{name:"k8s-profile:work:user:1",user:{token:$token,
      extensions:[{name:"picotools.k8s-profile",extension:{version:1,profile:"work",role:"user"}}]}}]}
  ' >"$user_file"
  "$K8S_TEST_REAL_CHMOD" 600 "$user_file"
  KUBECONFIG="$context_file:$cluster_file:$user_file"
  K8S_TEST_TARGET="$context_file"
  K8S_TEST_OTHER="$cluster_file"
  "$K8S_TEST_REAL_CP" "$context_file" "$TMP_HOME/before-context"
  "$K8S_TEST_REAL_CP" "$cluster_file" "$TMP_HOME/before-cluster"
  "$K8S_TEST_REAL_CP" "$user_file" "$TMP_HOME/before-user"
}
