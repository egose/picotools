#!/usr/bin/env bash
set -euo pipefail
set +x

if [ "$#" -ne 1 ]; then
  printf 'Usage: functional-test-k8s-profile-install.bash <installed-prefix>\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_ROOT="$(cd "$1" && pwd)"
installed_tool="$INSTALL_ROOT/bin/k8s-profile"

resolve_binary() {
  local name="$1" candidate
  candidate=$(command -v "$name")
  case "$candidate" in
  */shims/*) candidate=$(asdf which "$name") ;;
  esac
  [ -x "$candidate" ]
  printf '%s\n' "$candidate"
}

# Resolve shims before isolating HOME; never consult personal config afterward.
real_env=$(resolve_binary env)
real_kubectl=$(resolve_binary kubectl)
real_jq=$(resolve_binary jq)
umask 077
SMOKE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/k8s-profile-install.XXXXXX")
cleanup() {
  rm -rf -- "$SMOKE_ROOT"
}
trap cleanup EXIT
mkdir -p "$SMOKE_ROOT/home/.kube" "$SMOKE_ROOT/tmp" "$SMOKE_ROOT/bin" "$SMOKE_ROOT/help-bin" "$SMOKE_ROOT/xdg/run"

smoke_env() {
  "$real_env" -i PATH="$SMOKE_ROOT/bin:/usr/bin:/bin" HOME="$SMOKE_ROOT/home" \
    TMPDIR="$SMOKE_ROOT/tmp" KUBECONFIG="$SMOKE_ROOT/home/.kube/config" KUBECTL_KUBERC=false \
    XDG_CONFIG_HOME="$SMOKE_ROOT/xdg/config" XDG_DATA_HOME="$SMOKE_ROOT/xdg/data" \
    XDG_CACHE_HOME="$SMOKE_ROOT/xdg/cache" XDG_STATE_HOME="$SMOKE_ROOT/xdg/state" XDG_RUNTIME_DIR="$SMOKE_ROOT/xdg/run" \
    K8S_INSTALL_REAL_KUBECTL="$real_kubectl" K8S_INSTALL_REAL_JQ="$real_jq" K8S_INSTALL_AUDIT="$SMOKE_ROOT/audit" \
    LC_ALL=C TERM=dumb "$@"
}

for module in common config transaction model actions lifecycle; do
  test -f "$INSTALL_ROOT/lib/picotools/k8s-profile/$module.sh"
done
test "$(<"$INSTALL_ROOT/VERSION")" = "$(<"$REPO_ROOT/VERSION")"

# Only loader/version dependencies are on this PATH: no kubectl, jq, or awk.
for name in bash cat dirname tr; do
  ln -s "$(resolve_binary "$name")" "$SMOKE_ROOT/help-bin/$name"
done
smoke_env "$real_env" PATH="$SMOKE_ROOT/help-bin" "$installed_tool" --help >"$SMOKE_ROOT/help.out" 2>"$SMOKE_ROOT/help.err"
smoke_env "$real_env" PATH="$SMOKE_ROOT/help-bin" "$installed_tool" --version >"$SMOKE_ROOT/version.out" 2>"$SMOKE_ROOT/version.err"
test "$(<"$SMOKE_ROOT/version.out")" = "$(<"$REPO_ROOT/VERSION")"
test ! -e "$SMOKE_ROOT/home/.kube/config"

# Audit argv/env privately and refuse any non-config kubectl command. The real
# binaries still load and validate every fixture; no request/plugin is needed.
cat >"$SMOKE_ROOT/bin/command-wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tool=${0##*/}
printf '%s\0' "$tool" "$@" >>"$K8S_INSTALL_AUDIT"
env -0 >>"$K8S_INSTALL_AUDIT"
case "$tool" in
kubectl)
  args=("$@")
  if [[ "${args[0]:-}" == --kubeconfig=* ]]; then
    args=("${args[@]:1}")
  fi
  [ "${args[0]:-}" = config ] || exit 99
  case "${args[1]:-}" in view) ;; *) exit 99 ;; esac
  exec "$K8S_INSTALL_REAL_KUBECTL" "$@"
  ;;
jq) exec "$K8S_INSTALL_REAL_JQ" "$@" ;;
*) exit 99 ;;
esac
EOF
chmod +x "$SMOKE_ROOT/bin/command-wrapper"
ln -s command-wrapper "$SMOKE_ROOT/bin/kubectl"
ln -s command-wrapper "$SMOKE_ROOT/bin/jq"
builtin printf 'not: [valid: yaml\n' >"$SMOKE_ROOT/home/.kube/kuberc"
builtin printf '%s' 'K8S_INSTALLED_CREATE_SENTINEL' >"$SMOKE_ROOT/create-token"
builtin printf '%s' 'K8S_INSTALLED_REPLACE_SENTINEL' >"$SMOKE_ROOT/replace-token"

read_config() {
  smoke_env kubectl config view --raw -o json >"$SMOKE_ROOT/config.json" 2>"$SMOKE_ROOT/config.err"
}

smoke_env "$installed_tool" list >"$SMOKE_ROOT/empty.out" 2>"$SMOKE_ROOT/empty.err"
grep -F 'No Kubernetes profiles found.' "$SMOKE_ROOT/empty.out" >/dev/null
test ! -e "$SMOKE_ROOT/home/.kube/config"
{
  builtin printf 'installed\nhttps://127.0.0.1:1\n'
  builtin printf '%s\n' "$(<"$SMOKE_ROOT/create-token")"
} | smoke_env "$installed_tool" --debug create >"$SMOKE_ROOT/create.out" 2>"$SMOKE_ROOT/create.err"
read_config
# shellcheck disable=SC2016 # jq owns these variables.
smoke_env jq -e --rawfile token "$SMOKE_ROOT/create-token" '
  .contexts[0].name == "installed" and .clusters[0].cluster.server == "https://127.0.0.1:1" and
  .users[0].user.token == $token and (.clusters[0].cluster["insecure-skip-tls-verify"] // false) == false and
  (.["current-context"] // "") == ""
' "$SMOKE_ROOT/config.json" >/dev/null 2>"$SMOKE_ROOT/assert-create.err"
smoke_env "$installed_tool" list >"$SMOKE_ROOT/list.out" 2>"$SMOKE_ROOT/list.err"
grep -F 'installed' "$SMOKE_ROOT/list.out" >/dev/null
grep -F 'https://127.0.0.1:1' "$SMOKE_ROOT/list.out" >/dev/null

{
  builtin printf '1\n1\nhttps://[::1]:1/prefix\n2\n2\n'
  builtin printf '%s\n' "$(<"$SMOKE_ROOT/replace-token")"
  builtin printf '3\n'
} | smoke_env "$installed_tool" --debug update >"$SMOKE_ROOT/update.out" 2>"$SMOKE_ROOT/update.err"
read_config
# shellcheck disable=SC2016 # jq owns these variables.
smoke_env jq -e --rawfile token "$SMOKE_ROOT/replace-token" '
  .contexts[0].name == "installed" and .clusters[0].cluster.server == "https://[::1]:1/prefix" and
  .users[0].user.token == $token and (.["current-context"] // "") == ""
' "$SMOKE_ROOT/config.json" >/dev/null 2>"$SMOKE_ROOT/assert-update.err"

smoke_env "$installed_tool" --debug use installed >"$SMOKE_ROOT/current.out" 2>"$SMOKE_ROOT/current.err"
read_config
smoke_env jq -e '.["current-context"] == "installed"' "$SMOKE_ROOT/config.json" >/dev/null 2>"$SMOKE_ROOT/assert-use.err"
# Exercise the installed optional-name menu too; current selection is a no-op.
builtin printf '1\n' | smoke_env "$installed_tool" use >"$SMOKE_ROOT/menu.out" 2>"$SMOKE_ROOT/menu.err"
grep -F "Profile 'installed' is already current." "$SMOKE_ROOT/menu.out" >/dev/null
builtin printf '1\nyes\n' | smoke_env "$installed_tool" --debug delete >"$SMOKE_ROOT/delete.out" 2>"$SMOKE_ROOT/delete.err"
grep -F 'ALL nonempty current-context values' "$SMOKE_ROOT/delete.err" >/dev/null
read_config
smoke_env jq -e '
  (.contexts // [] | length) == 0 and (.clusters // [] | length) == 0 and
  (.users // [] | length) == 0 and (.["current-context"] // "") == ""
' "$SMOKE_ROOT/config.json" >/dev/null 2>"$SMOKE_ROOT/assert-delete.err"
test "$(stat -c %a -- "$SMOKE_ROOT/home/.kube/config")" = 600
test -z "$(find "$SMOKE_ROOT/tmp" -mindepth 1 -print)"
test -z "$(find "$SMOKE_ROOT/home" \( -name '.k8s-profile.*' -o -name '*.lock' \) -print)"
if grep -F -q -f "$SMOKE_ROOT/create-token" -f "$SMOKE_ROOT/replace-token" "$SMOKE_ROOT/audit" "$SMOKE_ROOT"/*.out "$SMOKE_ROOT"/*.err; then
  printf 'Installed smoke failed: credential bytes crossed an argv/env/output boundary.\n' >&2
  exit 1
fi
printf 'Installed k8s-profile create/list/use/update/delete smoke passed.\n'
