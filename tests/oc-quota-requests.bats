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
demo-be-789 5m 314Mi
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
demo-be-789
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
  *'get pod demo-be-789 -o jsonpath='*'.resources.requests.cpu'*'.resources.requests.memory'*)
    printf '\t'
    ;;
  *'get pod demo-api-123 -o jsonpath='*'.spec.initContainers'*)
    ;;
  *'get pod demo-worker-456 -o jsonpath='*'.spec.initContainers'*)
    ;;
  *'get pod demo-be-789 -o jsonpath='*'.spec.initContainers'*)
    ;;
  *'get pod demo-api-123 -o jsonpath='*'.spec.overhead.cpu'*)
    printf '\t'
    ;;
  *'get pod demo-worker-456 -o jsonpath='*'.spec.overhead.cpu'*)
    printf '\t'
    ;;
  *'get pod demo-be-789 -o jsonpath='*'.spec.overhead.cpu'*)
    printf '\t'
    ;;
  *'get pod demo-api-123 -o jsonpath='*'.status.qosClass'*)
    echo 'Burstable|||ReplicaSet,'
    ;;
  *'get pod demo-worker-456 -o jsonpath='*'.status.qosClass'*)
    echo 'Burstable|||ReplicaSet,'
    ;;
  *'get pod demo-be-789 -o jsonpath='*'.status.qosClass'*)
    echo 'BestEffort|||ReplicaSet,'
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

@test "renders quota report tables with utilization and slack columns" {
  local output

  output=$("$TOOL")

  assert_contains "$output" '| Namespace | b0c13b-dev' 'overview table should split the namespace field and value into separate columns'
  assert_contains "$output" '| Quota     | compute-long-running-quota |' 'overview table should render the quota name in the value column'
  assert_contains "$output" 'Usage %' 'quota table should include a separate usage percent column'
  assert_contains "$output" 'Usage Bar' 'quota table should include a separate usage bar column'
  assert_contains "$output" '71.20%' 'quota table should render usage percentages'
  assert_contains "$output" '[███████░░░]' 'quota table should render usage progress bars'
  assert_contains "$output" '| demo-api-123' 'pod table should include the demo-api pod row'
  assert_contains "$output" 'CPU Util %' 'pod table should include a separate CPU utilization percent column'
  assert_contains "$output" 'Mem Util %' 'pod table should include a separate memory utilization percent column'
  assert_contains "$output" '0.33%' 'pod table should render CPU utilization percentages'
  assert_contains "$output" '32.81%' 'pod table should render memory utilization percentages'
  assert_contains "$output" '299m' 'pod table should render CPU slack values separately from status'
  assert_contains "$output" '387Mi' 'pod table should render memory slack values separately from status'
  assert_contains "$output" '| demo-be-789' 'pod table should include the BestEffort pod row'
  assert_contains "$output" 'n/a (0 req)' 'pod table should highlight zero-request utilization'
  assert_contains "$output" '-314Mi' 'pod table should show negative slack values separately from status'
  assert_contains "$output" '| Analyzed requests       | 1424m | 3872Mi |' 'totals table should render CPU and memory totals in separate columns'
  assert_contains "$output" 'Sizing indicators:' 'report should include a sizing guidance section'
  assert_contains "$output" 'Primary indicators:' 'guidance should identify utilization as the primary signal'
  assert_contains "$output" 'CPU Util %' 'guidance should include CPU utilization thresholds'
  assert_contains "$output" '20-70%' 'guidance should include the healthy CPU utilization band'
  assert_contains "$output" '0 req in use or >100% sustained' 'guidance should include the bad CPU utilization signal'
  assert_contains "$output" 'Mem Util %' 'guidance should include memory utilization thresholds'
  assert_contains "$output" '50-80%' 'guidance should include the healthy memory utilization band'
  assert_contains "$output" '0 req in use or >95% sustained' 'guidance should include the bad memory utilization signal'
  assert_contains "$output" 'Supporting indicators:' 'guidance should keep slack as supporting information'
  assert_contains "$output" 'Use to estimate reclaimable CPU or burst deficit in millicores' 'guidance should explain how to use CPU slack'
  assert_contains "$output" 'Use to estimate reclaimable memory or memory risk in Mi' 'guidance should explain how to use memory slack'
  assert_contains "$output" 'Rule of thumb: size CPU requests near steady-state p90, and memory requests nearer p95 unless restarts are cheap.' 'report should include a request-sizing rule of thumb'
  assert_contains "$output" 'treat utilization as the severity signal, and use slack to judge the size of the opportunity or risk' 'report should explain the utilization-versus-slack relationship'
  assert_not_contains "$output" '\t' 'rendered tables should not contain literal tab escape sequences'
}
