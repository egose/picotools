#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/oc-quota-requests"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"

  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"

case "$args" in
  'project -q')
    echo 'b0c13b-dev'
    exit 0
    ;;
  'adm top pods --no-headers')
    cat <<'OUT'
demo-api-123 1m 189Mi
demo-worker-456 2m 200Mi
OUT
    exit 0
    ;;
esac

case "$args" in
  *'get quota compute-long-running-quota -o jsonpath='*'.status.hard.requests'*'.status.used.requests'*)
    cat <<'OUT'
2000m	8192Mi	1424m	3872Mi
OUT
    ;;
  *'get quota compute-long-running-quota -o jsonpath='*'.spec.scopes'*)
    ;;
  *'get quota compute-long-running-quota -o jsonpath='*'.spec.scopeSelector.matchExpressions'*)
    ;;
  *'get pods -o jsonpath='*'.metadata.name'*)
    cat <<'OUT'
demo-api-123
demo-worker-456
OUT
    ;;
  *'get pod demo-api-123 -o jsonpath='*'.resources.requests.cpu'*'.resources.requests.memory'*)
    cat <<'OUT'
300m	576Mi
OUT
    ;;
  *'get pod demo-worker-456 -o jsonpath='*'.resources.requests.cpu'*'.resources.requests.memory'*)
    cat <<'OUT'
1124m	3296Mi
OUT
    ;;
  *'get pod demo-api-123 -o jsonpath='*'.spec.initContainers'*)
    ;;
  *'get pod demo-worker-456 -o jsonpath='*'.spec.initContainers'*)
    ;;
  *'get pod demo-api-123 -o jsonpath='*'.spec.overhead.cpu'*)
    printf '\t'
    ;;
  *'get pod demo-worker-456 -o jsonpath='*'.spec.overhead.cpu'*)
    printf '\t'
    ;;
  *'get pod demo-api-123 -o jsonpath='*'.status.qosClass'*)
    echo 'Burstable|||ReplicaSet,'
    ;;
  *'get pod demo-worker-456 -o jsonpath='*'.status.qosClass'*)
    echo 'Burstable|||ReplicaSet,'
    ;;
  *)
    echo "unexpected oc args: $args" >&2
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
  echo "FAIL: $1" >&2
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*)
    fail "$message (unexpected '$needle')"
    ;;
  *) ;;
  esac
}

@test "renders quota report tables with split columns" {
  local output

  output=$("$TOOL")

  assert_contains "$output" '| Namespace | b0c13b-dev' 'overview table should split the namespace field and value into separate columns'
  assert_contains "$output" '| Quota     | compute-long-running-quota |' 'overview table should render the quota name in the value column'
  assert_contains "$output" '| requests.cpu    | 1424m  | 2000m  | 71.20% | 576m      |' 'quota table should render each metric in its own column'
  assert_contains "$output" '| demo-api-123    | 300m    | 1m      | 576Mi   | 189Mi   |' 'pod table should render request and usage columns'
  assert_contains "$output" '| Analyzed requests       | 1424m | 3872Mi |' 'totals table should render CPU and memory totals in separate columns'
  assert_not_contains "$output" '\t' 'rendered tables should not contain literal tab escape sequences'
}
