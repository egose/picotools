#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/oc-route"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"
  export OC_LOG="$TMP_DIR/oc.log"
  export OC_APPLY_CAPTURE="$TMP_DIR/applied-route.yaml"

  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$OC_LOG"

case "$*" in
  '-n demo get route my-route -o yaml')
    cat <<'YAML'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-route
YAML
    ;;
  '-n demo apply -f '*)
    manifest_file="${@: -1}"
    cp "$manifest_file" "$OC_APPLY_CAPTURE"
    printf 'route.route.openshift.io/%s configured\n' 'my-route'
    ;;
  *)
    echo "unexpected oc args: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$TMP_DIR/bin/oc"
}

teardown() {
  rm -rf "$TMP_DIR"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*) ;;
  *)
    fail "$message (missing '$needle')"
    ;;
  esac
}

@test "reads a route from the requested namespace" {
  local log_contents

  run "$TOOL" --debug --namespace demo read my-route

  [ "$status" -eq 0 ] || fail 'oc-route read should succeed for an existing route'
  assert_contains "$output" "[oc-route] Reading route 'my-route'" 'debug mode should describe the route being read'
  assert_contains "$output" 'name: my-route' 'should print the route yaml'

  log_contents="$(<"$OC_LOG")"
  assert_contains "$log_contents" '-n demo get route my-route -o yaml' 'should pass the namespace through to oc'
}

@test "builds and applies a route manifest from flags" {
  local cert_file key_file ca_file manifest

  cert_file="$TMP_DIR/tls.crt"
  key_file="$TMP_DIR/tls.key"
  ca_file="$TMP_DIR/ca.crt"

  printf '%s\n' 'CERTDATA' >"$cert_file"
  printf '%s\n' 'KEYDATA' >"$key_file"
  printf '%s\n' 'CADATA' >"$ca_file"

  run "$TOOL" --namespace demo update \
    --name my-route \
    --host app.example.com \
    --path /api \
    --target-port http \
    --service api-service \
    --balance roundrobin \
    --disable-cookies true \
    --timeout 600s \
    --secure \
    --certificate-file "$cert_file" \
    --key-file "$key_file" \
    --ca-certificate-file "$ca_file"

  [ "$status" -eq 0 ] || fail 'oc-route update should succeed for valid flag inputs'
  assert_contains "$output" 'route.route.openshift.io/my-route configured' 'should report the applied route'

  manifest="$(<"$OC_APPLY_CAPTURE")"
  assert_contains "$manifest" "name: 'my-route'" 'should render the route name into the manifest'
  assert_contains "$manifest" "host: 'app.example.com'" 'should render the route host'
  assert_contains "$manifest" "path: '/api'" 'should render the optional route path'
  assert_contains "$manifest" "targetPort: 'http'" 'should render the route target port'
  assert_contains "$manifest" "name: 'api-service'" 'should render the target service name'
  assert_contains "$manifest" 'certificate: |' 'should include the certificate block for secure routes'
  assert_contains "$manifest" '  CERTDATA' 'should include certificate file content in the manifest'
  assert_contains "$manifest" '  KEYDATA' 'should include key file content in the manifest'
  assert_contains "$manifest" '  CADATA' 'should include CA file content in the manifest'
}

@test "help documents debug mode" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'oc-route --help should succeed'
  assert_contains "$output" '--debug' 'help should list debug mode'
}
