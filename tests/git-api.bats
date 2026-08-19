#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-api"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export XDG_DATA_HOME="$TMP_DIR/xdg-data"
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
tr '\0' ' ' </proc/"$PPID"/cmdline >"$TMP_DIR/git-api-parent-cmdline.log"
tr '\0' ' ' </proc/$$/cmdline >"$TMP_DIR/curl-self-cmdline.log"

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
  --config)
    while IFS= read -r config_line; do
      case "$config_line" in
      'header = "'*)
        config_line=${config_line#'header = "'}
        config_line=${config_line%'"'}
        config_line=${config_line//\\\"/\"}
        config_line=${config_line//\\\\/\\}
        printf '%s\n' "$config_line" >>"$TMP_DIR/curl-headers.log"
        ;;
      esac
    done <"$2"
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
  'GET https://github.test/repos/octo/demo')
    status='200'
    response='{"full_name":"octo/demo"}'
    ;;
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
  assert_contains "$output" 'configure' 'help should list configure'
  assert_contains "$output" 'profiles' 'help should list stored profile management'
  assert_contains "$output" '--profile NAME' 'help should document profile selection'
  assert_contains "$output" '--token-stdin' 'help should document stdin token selection'
  assert_contains "$output" 'same precedence as --token' 'help should describe token-stdin precedence'
  assert_contains "$output" 'Auth precedence:' 'help should describe auth precedence'
  assert_contains "$output" '--debug' 'help should list debug mode'
  assert_contains "$output" '<operationId> [path-args...] [flags]' 'help should document operationId commands'
  assert_contains "$output" 'git-api repos/get octocat hello-world' 'help should show an operationId example'
}

@test "configure stores a PAT token for later requests" {
  run bash -lc "printf 'secret-pat\n' | '$TOOL' configure"

  [ "$status" -eq 0 ] || fail 'configure should succeed'
  assert_contains "$output" 'Configured git-api PAT_TOKEN.' 'configure should confirm the saved token'
  assert_eq "$(<"$XDG_DATA_HOME/git-api/pat-token")" 'secret-pat' 'configure should store the PAT token'

  run "$TOOL" repos/get octo demo

  [ "$status" -eq 0 ] || fail 'repos/get should succeed with configured auth'
  assert_contains "$(<"$TMP_DIR/curl-headers.log")" 'Authorization: Bearer secret-pat' 'configured PAT token should be sent as a bearer header'
}

@test "token flag overrides the configured token" {
  mkdir -p "$XDG_DATA_HOME/git-api"
  printf '%s\n' 'stored-pat' >"$XDG_DATA_HOME/git-api/pat-token"

  run "$TOOL" --token override-pat repos/get octo demo

  [ "$status" -eq 0 ] || fail 'repos/get should succeed with token override'
  assert_contains "$(<"$TMP_DIR/curl-headers.log")" 'Authorization: Bearer override-pat' 'token flag should override the stored token'
}

@test "token-stdin overrides a selected profile without exposing the token in argv or output" {
  mkdir -p "$XDG_DATA_HOME/git-api/profiles/work"
  printf '%s\n' 'stored-pat' >"$XDG_DATA_HOME/git-api/profiles/work/token"
  printf '%s\n' 'work' >"$XDG_DATA_HOME/git-api/current-profile"

  run bash -lc "printf 'stdin-override\r\n' | '$TOOL' --debug --token-stdin repos/get octo demo"

  [ "$status" -eq 0 ] || fail 'repos/get should succeed with stdin token override'
  assert_contains "$(<"$TMP_DIR/curl-headers.log")" 'Authorization: Bearer stdin-override' 'token-stdin should override the selected profile token'
  assert_contains "$output" '"full_name": "octo/demo"' 'repos/get should print the API response'
  [[ "$(<"$TMP_DIR/git-api-parent-cmdline.log")" != *stdin-override* ]] || fail 'git-api argv should not contain the stdin token'
  [[ "$(<"$TMP_DIR/curl-self-cmdline.log")" != *stdin-override* ]] || fail 'curl argv should not contain the stdin token'
  [[ "$output" != *stdin-override* ]] || fail 'git-api output should not contain the stdin token'
}

@test "token-stdin rejects empty stdin" {
  run bash -lc "printf '\r\n' | '$TOOL' --token-stdin repos/get octo demo"

  [ "$status" -ne 0 ] || fail 'repos/get should fail when token-stdin receives an empty token'
  assert_contains "$output" 'Error: --token-stdin requires a non-empty token on stdin' 'token-stdin should explain the empty token failure'
}

@test "token-stdin rejects multiline stdin" {
  run bash -lc "printf 'first-line\nsecond-line\n' | '$TOOL' --token-stdin repos/get octo demo"

  [ "$status" -ne 0 ] || fail 'repos/get should fail when token-stdin receives multiple lines'
  assert_contains "$output" 'Error: --token-stdin requires a single-line token on stdin' 'token-stdin should explain the multiline token failure'
}

@test "token and token-stdin cannot be used together" {
  run bash -lc "printf 'stdin-override\n' | '$TOOL' --token explicit --token-stdin repos/get octo demo"

  [ "$status" -ne 0 ] || fail 'git-api should reject conflicting explicit token overrides'
  assert_contains "$output" 'Error: --token and --token-stdin cannot be used together' 'git-api should explain conflicting token override flags'
  [[ "$output" != *stdin-override* ]] || fail 'conflict output should not contain the stdin token'
}

@test "configure profile stores a named PAT token and selects it" {
  run bash -lc "printf 'work-pat\n' | '$TOOL' configure work"

  [ "$status" -eq 0 ] || fail 'configure work should succeed'
  assert_contains "$output" "Configured git-api PAT_TOKEN profile 'work'." 'configure should confirm the saved named profile'
  assert_eq "$(<"$XDG_DATA_HOME/git-api/profiles/work/token")" 'work-pat' 'configure should store the named PAT token'
  assert_eq "$(<"$XDG_DATA_HOME/git-api/current-profile")" 'work' 'configure should select the named profile'

  run "$TOOL" repos/get octo demo

  [ "$status" -eq 0 ] || fail 'repos/get should succeed with current profile auth'
  assert_contains "$(<"$TMP_DIR/curl-headers.log")" 'Authorization: Bearer work-pat' 'current profile token should be sent as a bearer header'
}

@test "profile flag overrides the current profile" {
  mkdir -p "$XDG_DATA_HOME/git-api/profiles/work" "$XDG_DATA_HOME/git-api/profiles/personal"
  printf '%s\n' 'work-pat' >"$XDG_DATA_HOME/git-api/profiles/work/token"
  printf '%s\n' 'personal-pat' >"$XDG_DATA_HOME/git-api/profiles/personal/token"
  printf '%s\n' 'work' >"$XDG_DATA_HOME/git-api/current-profile"

  run "$TOOL" --profile personal repos/get octo demo

  [ "$status" -eq 0 ] || fail 'repos/get should succeed with a profile override'
  assert_contains "$(<"$TMP_DIR/curl-headers.log")" 'Authorization: Bearer personal-pat' 'profile flag should override the current profile token'
}

@test "profiles lists stored profiles and marks the current one" {
  mkdir -p "$XDG_DATA_HOME/git-api/profiles/work" "$XDG_DATA_HOME/git-api/profiles/personal"
  printf '%s\n' 'work-pat' >"$XDG_DATA_HOME/git-api/profiles/work/token"
  printf '%s\n' 'personal-pat' >"$XDG_DATA_HOME/git-api/profiles/personal/token"
  printf '%s\n' 'personal' >"$XDG_DATA_HOME/git-api/current-profile"

  run "$TOOL" profiles

  [ "$status" -eq 0 ] || fail 'profiles should succeed'
  assert_contains "$output" '| Profile ' 'profiles should render a table header'
  assert_contains "$output" 'personal' 'profiles should include the current profile'
  assert_contains "$output" 'work' 'profiles should include stored profiles'
  assert_contains "$output" 'yes' 'profiles should mark the current profile'
}

@test "use switches the current profile" {
  mkdir -p "$XDG_DATA_HOME/git-api/profiles/work" "$XDG_DATA_HOME/git-api/profiles/personal"
  printf '%s\n' 'work-pat' >"$XDG_DATA_HOME/git-api/profiles/work/token"
  printf '%s\n' 'personal-pat' >"$XDG_DATA_HOME/git-api/profiles/personal/token"
  printf '%s\n' 'work' >"$XDG_DATA_HOME/git-api/current-profile"

  run "$TOOL" use personal

  [ "$status" -eq 0 ] || fail 'use should succeed'
  assert_contains "$output" "Using git-api profile 'personal'." 'use should confirm the selected profile'
  assert_eq "$(<"$XDG_DATA_HOME/git-api/current-profile")" 'personal' 'use should update the current profile file'
}

@test "delete-profile removes the stored profile and clears current selection" {
  mkdir -p "$XDG_DATA_HOME/git-api/profiles/work"
  printf '%s\n' 'work-pat' >"$XDG_DATA_HOME/git-api/profiles/work/token"
  printf '%s\n' 'work' >"$XDG_DATA_HOME/git-api/current-profile"

  run "$TOOL" delete-profile work

  [ "$status" -eq 0 ] || fail 'delete-profile should succeed'
  assert_contains "$output" "Deleted git-api profile 'work'." 'delete-profile should confirm removal'
  [ ! -e "$XDG_DATA_HOME/git-api/profiles/work/token" ] || fail 'delete-profile should remove the profile token file'
  [ ! -e "$XDG_DATA_HOME/git-api/current-profile" ] || fail 'delete-profile should clear the current profile selection when deleting it'
}

@test "api root and version can be passed as global flags" {
  run "$TOOL" --api-root https://github.test --api-version 2026-01-01 repos/get octo demo

  [ "$status" -eq 0 ] || fail 'repos/get should succeed with global API overrides'
  assert_contains "$(<"$TMP_DIR/curl-request.log")" 'GET https://github.test/repos/octo/demo' 'api root should override the request root globally'
  assert_contains "$(<"$TMP_DIR/curl-headers.log")" 'X-GitHub-Api-Version: 2026-01-01' 'api version should override the request header globally'
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
  run "$TOOL" --debug repos/get octo demo

  [ "$status" -eq 0 ] || fail 'repos/get should succeed'
  assert_contains "$output" "[git-api] Calling 'repos/get' with method 'GET' path '/repos/octo/demo'" 'debug mode should describe the resolved operation call'
  assert_contains "$output" '[git-api] Preparing GET request to' 'debug mode should describe the outgoing HTTP request'
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
