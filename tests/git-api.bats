#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-api"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"

  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

outfile=''
method='GET'
url=''
body=''
write_format=''

: >"$TMP_DIR/curl-headers.log"

while [ "$#" -gt 0 ]; do
  case "$1" in
  -o)
    outfile="$2"
    shift 2
    ;;
  -w)
    write_format="$2"
    shift 2
    ;;
  -X)
    method="$2"
    shift 2
    ;;
  -H)
    printf '%s\n' "$2" >>"$TMP_DIR/curl-headers.log"
    shift 2
    ;;
  --data|--data-binary)
    body="$2"
    printf '%s' "$body" >"$TMP_DIR/curl-body.log"
    shift 2
    ;;
  -s|-S|-sS)
    shift
    ;;
  *)
    url="$1"
    shift
    ;;
  esac
done

printf '%s\n' "$method $url" >"$TMP_DIR/curl-request.log"

case "$method $url" in
  'GET https://api.github.com/repos/octo/demo')
    status='200'
    response='{"full_name":"octo/demo"}'
    ;;
  'GET https://api.github.com/users/octo/repos?type=owner')
    status='200'
    response='[{"full_name":"octo/demo"}]'
    ;;
  'GET https://api.github.com/repos/octo/demo/actions/artifacts?per_page=10')
    status='200'
    response='{"total_count":1,"artifacts":[{"id":12,"name":"build"}]}'
    ;;
  'POST https://api.github.com/repos/octo/demo/pulls')
    status='201'
    response='{"number":42,"title":"My PR"}'
    ;;
  'DELETE https://api.github.com/repos/octo/demo/actions/artifacts/12')
    status='204'
    response=''
    ;;
  'GET https://api.github.com/search/repositories?q=picotools')
    status='200'
    response='{"total_count":1,"items":[{"full_name":"egose/picotools"}]}'
    ;;
  *)
    status='404'
    response='{"message":"Unhandled test URL"}'
    ;;
esac

printf '%s' "$response" >"$outfile"
printf '%s' "${write_format//'%{http_code}'/$status}"
EOF
  chmod +x "$TMP_DIR/bin/curl"
}

teardown() {
  rm -rf "$TMP_DIR"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
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

@test "help describes verb-first usage" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'help should succeed'
  assert_contains "$output" '<operationId> [path-args...] [flags]' 'help should document operationId commands'
  assert_contains "$output" 'git-api repos/get octocat hello-world' 'help should show an operationId example'
}

@test "list prints indexed operation ids by default" {
  run "$TOOL" list

  [ "$status" -eq 0 ] || fail 'list should succeed'
  assert_contains "$output" '| OperationId ' 'list should render a table header'
  assert_contains "$output" '| repos/get ' 'list should show a repo operation'
  assert_contains "$output" 'actions/list-artifacts-for-repo' 'list should show an actions operation'
}

@test "list prefix filters the indexed operations" {
  run "$TOOL" list repos/

  [ "$status" -eq 0 ] || fail 'list repos/ should succeed'
  assert_contains "$output" '| repos/get ' 'prefix list should include matching operations'
  assert_contains "$output" 'repos/list-for-user' 'prefix list should include other repo operations'
}

@test "show prints docs and argument info for an operation id" {
  run "$TOOL" show repos/list-for-user

  [ "$status" -eq 0 ] || fail 'show should succeed'
  assert_contains "$output" 'Operation: repos/list-for-user' 'show should include the operation id'
  assert_contains "$output" 'Docs: https://docs.github.com/rest/repos/repos#list-repositories-for-a-user' 'show should include the external docs url'
  assert_contains "$output" 'Path Args: username' 'show should include ordered path args'
  assert_contains "$output" 'Query Flag: --per-page' 'show should include query flags derived from the spec'
}

@test "operation command uses ordered path args" {
  run "$TOOL" repos/get octo demo

  [ "$status" -eq 0 ] || fail 'repos/get should succeed'
  assert_contains "$output" '"full_name": "octo/demo"' 'repos/get should print the API json'
  assert_contains "$(<"$TMP_DIR/curl-request.log")" 'GET https://api.github.com/repos/octo/demo' 'repos/get should call the resolved endpoint'
  assert_contains "$(<"$TMP_DIR/curl-headers.log")" 'X-GitHub-Api-Version: 2026-03-10' 'repos/get should send the default API version header'
}

@test "query params can be passed as flags" {
  run "$TOOL" actions/list-artifacts-for-repo octo demo --per-page 10

  [ "$status" -eq 0 ] || fail 'actions/list-artifacts-for-repo should succeed'
  assert_contains "$output" '"name": "build"' 'actions/list-artifacts-for-repo should print the artifact json'
  assert_contains "$(<"$TMP_DIR/curl-request.log")" 'GET https://api.github.com/repos/octo/demo/actions/artifacts?per_page=10' 'query flags should be appended to the request'
}

@test "post operation sends json body fields" {
  run "$TOOL" pulls/create octo demo --field title='My PR' --field head='feature-1' --field base='main'

  [ "$status" -eq 0 ] || fail 'pulls/create should succeed'
  assert_contains "$output" '"number": 42' 'pulls/create should print the API json'
  assert_contains "$(<"$TMP_DIR/curl-request.log")" 'POST https://api.github.com/repos/octo/demo/pulls' 'pulls/create should call the resolved endpoint'
  assert_contains "$(<"$TMP_DIR/curl-body.log")" '"title":"My PR"' 'pulls/create should encode body fields as json'
}

@test "listing repos for a user is supported" {
  run "$TOOL" repos/list-for-user octo --type owner

  [ "$status" -eq 0 ] || fail 'repos/list-for-user should succeed'
  assert_contains "$(<"$TMP_DIR/curl-request.log")" 'GET https://api.github.com/users/octo/repos?type=owner' 'repos/list-for-user should use ordered path args and query flags'
}

@test "search operation uses required query flags" {
  run "$TOOL" search/repos --q picotools

  [ "$status" -eq 0 ] || fail 'search/repos should succeed'
  assert_contains "$output" '"full_name": "egose/picotools"' 'search/repos should print the search response'
  assert_contains "$(<"$TMP_DIR/curl-request.log")" 'GET https://api.github.com/search/repositories?q=picotools' 'search/repos should pass query flags'
}

@test "operation help uses external docs metadata" {
  run "$TOOL" repos/get --help

  [ "$status" -eq 0 ] || fail 'operation help should succeed'
  assert_contains "$output" 'git-api repos/get <owner> <repo> [flags]' 'operation help should include ordered path args'
  assert_contains "$output" 'Docs: https://docs.github.com/rest/repos/repos#get-a-repository' 'operation help should include the docs url'
}

@test "fails when a required path arg is missing" {
  run "$TOOL" repos/get octo

  [ "$status" -ne 0 ] || fail 'repos/get should fail when a required path arg is missing'
  assert_contains "$output" 'Error: missing required path argument <repo> for repos/get' 'tool should explain the missing path argument'
}
