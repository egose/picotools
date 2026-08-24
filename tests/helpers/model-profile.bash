#!/usr/bin/env bash

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
MODEL_PROFILE_TOOL="${MODEL_PROFILE_TOOL:-$REPO_ROOT/tools/bin/model-profile}"
# shellcheck disable=SC2034 # Used by focused Bats suites after loading this helper.
MODEL_PROFILE_API_KEY_SENTINEL='model-profile-test-api-key-sentinel'
MODEL_PROFILE_REAL_JQ="${MODEL_PROFILE_REAL_JQ:-$(asdf which jq 2>/dev/null || command -v jq)}"

setup_model_profile_test() {
  TMP_HOME="$(mktemp -d)" || return 1
  export TMP_HOME
  export HOME="$TMP_HOME"
  export XDG_CONFIG_HOME="$TMP_HOME/.config"
  export XDG_DATA_HOME="$TMP_HOME/.local/share"
  export CONFIG_DIR="$XDG_CONFIG_HOME/model-profile"
  export DATA_DIR="$XDG_DATA_HOME/model-profile"
  export MODEL_PROFILE_STUB_BIN="$TMP_HOME/bin"
  export MODEL_PROFILE_CURL_ARGS_NUL_LOG="$TMP_HOME/curl-args.nul"
  export MODEL_PROFILE_CURL_PUBLIC_ARGS_NUL_LOG="$TMP_HOME/curl-public-args.nul"
  export MODEL_PROFILE_CURL_URL_LOG="$TMP_HOME/curl-url.log"
  export MODEL_PROFILE_CURL_AUTH_LOG="$TMP_HOME/curl-auth.log"
  export MODEL_PROFILE_CURL_AUTH_CONFIG_PATH_LOG="$TMP_HOME/curl-auth-config-path.log"
  export MODEL_PROFILE_CURL_AUTH_CONFIG_MODE_LOG="$TMP_HOME/curl-auth-config-mode.log"
  export MODEL_PROFILE_CURL_BODY_LOG="$TMP_HOME/curl-body.json"
  mkdir -p "$MODEL_PROFILE_STUB_BIN"
  ln -s "$MODEL_PROFILE_REAL_JQ" "$MODEL_PROFILE_STUB_BIN/jq"
}

teardown_model_profile_test() {
  if [ -n "${TMP_HOME:-}" ]; then
    rm -rf "$TMP_HOME"
    [ ! -e "$TMP_HOME" ] || fail "temporary HOME/XDG state was not removed"
  fi
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

assert_secret_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (secret values differed)"
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*)
    fail "$message (unexpected '$needle')"
    ;;
  esac
}

assert_file_exists() {
  local path="$1"
  local message="$2"

  [ -f "$path" ] || fail "$message ($path)"
}

assert_file_not_exists() {
  local path="$1"
  local message="$2"

  if [ -e "$path" ]; then
    fail "$message ($path)"
  fi
}

assert_file_mode() {
  local path="$1"
  local expected="$2"
  local message="$3"
  local actual

  actual=$(stat -c '%a' "$path")
  assert_eq "$actual" "$expected" "$message"
}

assert_no_transaction_artifacts() {
  local name="$1"
  local pattern
  local -a patterns=(
    "$CONFIG_DIR/.${name}.conf.tmp.*"
    "$CONFIG_DIR/.${name}.conf.backup.*"
    "$DATA_DIR/.${name}.token.tmp.*"
    "$DATA_DIR/.${name}.token.backup.*"
  )

  for pattern in "${patterns[@]}"; do
    if compgen -G "$pattern" >/dev/null; then
      fail "transaction artifacts should be cleaned up for $name ($pattern)"
    fi
  done
}

assert_config_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local message="$4"

  assert_eq "$(git config -f "$file" --get "$key")" "$expected" "$message"
}

assert_json_string_eq() {
  local file="$1"
  local filter="$2"
  local expected="$3"
  local message="$4"
  local actual_file expected_file

  actual_file="$TMP_HOME/json-actual.$$"
  expected_file="$TMP_HOME/json-expected.$$"
  "$MODEL_PROFILE_REAL_JQ" -rj "$filter" <"$file" >"$actual_file"
  printf '%s' "$expected" >"$expected_file"
  if ! cmp -s "$actual_file" "$expected_file"; then
    rm -f "$actual_file" "$expected_file"
    fail "$message (JSON string mismatch)"
  fi
  rm -f "$actual_file" "$expected_file"
}

profile_file_path() {
  printf '%s/%s.conf\n' "$CONFIG_DIR" "$1"
}

token_file_path() {
  printf '%s/%s.token\n' "$DATA_DIR" "$1"
}

run_tool() {
  "$MODEL_PROFILE_TOOL" "$@"
}

create_azure_openai_profile() {
  local name="${1:-work-openai}"
  local token="${2:-secret-openai-token}"
  local models="${3:-gpt-5, gpt-4o}"

  printf '%s\n1\nexample-openai\n%s\n%s\n' "$name" "$models" "$token" |
    run_tool create >/dev/null 2>&1
}

write_model_profile_config() {
  local name="$1"
  local provider_type="$2"
  local location="$3"
  local models="${4:-gpt-5}"
  local token="${5:-$MODEL_PROFILE_API_KEY_SENTINEL}"
  local file

  mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  file="$(profile_file_path "$name")"
  git config -f "$file" provider.type "$provider_type"
  case "$provider_type" in
  azure-openai | azure-cognitive-services)
    git config -f "$file" provider.resourceName "$location"
    ;;
  custom)
    git config -f "$file" provider.endpointUrl "$location"
    ;;
  esac
  git config -f "$file" provider.models "$models"
  printf '%s\n' "$token" >"$(token_file_path "$name")"
  chmod 600 "$(token_file_path "$name")"
}

assert_no_key_read_or_transport() {
  local message="$1"

  assert_file_not_exists "$MODEL_PROFILE_CURL_AUTH_LOG" "$message: curl auth log should not exist"
  assert_file_not_exists "$MODEL_PROFILE_CURL_URL_LOG" "$message: curl URL log should not exist"
}

write_model_profile_curl_fake() {
  cat >"$MODEL_PROFILE_STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=''
url=''
body=''
auth=''
config_file=''
connect_timeout=''
max_time=''
scenario="${MODEL_PROFILE_CURL_SCENARIO:-success}"
http_code="${MODEL_PROFILE_CURL_HTTP_CODE:-200}"

if [ -n "${MODEL_PROFILE_CURL_ARGS_NUL_LOG:-}" ]; then
  : >"$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
  for arg in "$@"; do
    printf '%s\0' "$arg" >>"$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
  done
fi

if [ -n "${MODEL_PROFILE_CURL_PUBLIC_ARGS_NUL_LOG:-}" ]; then
  : >"$MODEL_PROFILE_CURL_PUBLIC_ARGS_NUL_LOG"
  for arg in "$@"; do
    case "$arg" in
    Authorization:*)
      printf '%s\0' 'Authorization: Bearer <redacted>' >>"$MODEL_PROFILE_CURL_PUBLIC_ARGS_NUL_LOG"
      ;;
    *)
      printf '%s\0' "$arg" >>"$MODEL_PROFILE_CURL_PUBLIC_ARGS_NUL_LOG"
      ;;
    esac
  done
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
  --)
    shift
    if [ "$#" -gt 0 ]; then
      url="$1"
      shift
    fi
    ;;
  -K | --config)
    config_file="$2"
    printf '%s\n' "$config_file" >"$MODEL_PROFILE_CURL_AUTH_CONFIG_PATH_LOG"
    stat -c '%a' "$config_file" >"$MODEL_PROFILE_CURL_AUTH_CONFIG_MODE_LOG"
    while IFS= read -r config_line; do
      case "$config_line" in
      'header = "Authorization: Bearer '*'"')
        auth=${config_line#'header = "'}
        auth=${auth%'"'}
        ;;
      esac
    done <"$config_file"
    shift 2
    ;;
  -o)
    output_file="$2"
    shift 2
    ;;
  -w)
    shift 2
    ;;
  -H)
    if [[ "$2" == Authorization:* ]]; then
      auth="$2"
    fi
    shift 2
    ;;
  -d | --data-binary)
    if [[ "$2" == @* ]]; then
      body=$(<"${2#@}")
    else
      body="$2"
    fi
    shift 2
    ;;
  --connect-timeout)
    connect_timeout="$2"
    shift 2
    ;;
  --max-time)
    max_time="$2"
    shift 2
    ;;
  --proxy | --noproxy | --max-redirs | --proto | --proto-redir)
    shift 2
    ;;
  -*)
    shift
    ;;
  *)
    url="$1"
    shift
    ;;
  esac
done

write_response_body() {
  local response_body="$1"
  local response_payload
  local response_limit="${MODEL_PROFILE_MAX_RESPONSE_BYTES:-}"

  response_payload="${response_body}"
  response_payload+=$'\n'
  if [[ "$response_limit" =~ ^[0-9]+$ ]] && [ "$response_limit" -gt 0 ] && [ "${#response_payload}" -gt "$((response_limit + 1))" ]; then
    printf '%s' "${response_payload:0:$((response_limit + 1))}" >"$output_file"
    return 0
  fi

  printf '%s' "$response_payload" >"$output_file"
}

printf '%s\n' "$url" >"$MODEL_PROFILE_CURL_URL_LOG"
printf '%s\n' "$auth" >"$MODEL_PROFILE_CURL_AUTH_LOG"
printf '%s' "$body" >"$MODEL_PROFILE_CURL_BODY_LOG"

case "$scenario" in
success)
  write_response_body "${MODEL_PROFILE_CURL_RESPONSE_BODY:-'{"choices":[{"message":{"content":"test answer"}}]}'}"
  printf '%s' "$http_code"
  ;;
transport_failure)
  printf '%s\n' 'curl: simulated transport failure' >&2
  exit 7
  ;;
connect_timeout)
  printf 'curl: simulated connect timeout after %s seconds\n' "$connect_timeout" >&2
  exit 28
  ;;
stalled_body)
  printf 'curl: simulated total timeout after %s seconds\n' "$max_time" >&2
  exit 28
  ;;
non_2xx)
  write_response_body "${MODEL_PROFILE_CURL_RESPONSE_BODY:-'{"error":{"message":"rate limited by fixture"}}'}"
  printf '%s' "${MODEL_PROFILE_CURL_HTTP_CODE:-429}"
  ;;
malformed_json)
  write_response_body '{not valid json'
  printf '200'
  ;;
empty_content)
  write_response_body '{"choices":[{"message":{"content":""}}]}'
  printf '200'
  ;;
slow)
  sleep "${MODEL_PROFILE_CURL_SLEEP_SECONDS:-1}"
  write_response_body "${MODEL_PROFILE_CURL_RESPONSE_BODY:-'{"choices":[{"message":{"content":"slow answer"}}]}'}"
  printf '200'
  ;;
oversized)
  if [[ "${MODEL_PROFILE_MAX_RESPONSE_BYTES:-}" =~ ^[0-9]+$ ]] && [ "${MODEL_PROFILE_MAX_RESPONSE_BYTES:-0}" -gt 0 ]; then
    printf '%*s' "$((MODEL_PROFILE_MAX_RESPONSE_BYTES + 1))" '' | tr ' ' x >"$output_file"
  else
    dd if=/dev/zero bs=1024 count="${MODEL_PROFILE_CURL_OVERSIZE_KB:-128}" status=none | tr '\0' x >"$output_file"
  fi
  printf '200'
  ;;
signal_parent)
  kill -TERM "$PPID"
  sleep 1
  exit 143
  ;;
*)
  printf '%s\n' 'curl: unknown fixture scenario' >&2
  exit 2
  ;;
esac
EOF
  chmod +x "$MODEL_PROFILE_STUB_BIN/curl"
}

read_curl_args() {
  local log_file="${1:-$MODEL_PROFILE_CURL_ARGS_NUL_LOG}"

  MODEL_PROFILE_CURL_ARGS=()
  while IFS= read -r -d '' arg; do
    MODEL_PROFILE_CURL_ARGS+=("$arg")
  done <"$log_file"
}

assert_curl_arg_eq() {
  local index="$1"
  local expected="$2"
  local message="$3"

  assert_eq "${MODEL_PROFILE_CURL_ARGS[$index]:-}" "$expected" "$message"
}

assert_curl_arg_before_url() {
  local expected="$1"
  local message="$2"
  local index

  for index in "${!MODEL_PROFILE_CURL_ARGS[@]}"; do
    if [ "${MODEL_PROFILE_CURL_ARGS[$index]}" = "$expected" ]; then
      [ "$((index + 1))" -lt "${#MODEL_PROFILE_CURL_ARGS[@]}" ] || fail "$message (missing URL after '$expected')"
      assert_eq "${MODEL_PROFILE_CURL_ARGS[$((index + 1))]}" "$(<"$MODEL_PROFILE_CURL_URL_LOG")" "$message"
      return 0
    fi
  done

  fail "$message (missing '$expected')"
}

assert_no_curl_arg_contains() {
  local needle="$1"
  local log_file="${2:-$MODEL_PROFILE_CURL_PUBLIC_ARGS_NUL_LOG}"
  local arg

  while IFS= read -r -d '' arg; do
    case "$arg" in
    *"$needle"*)
      fail 'curl argument record exposed a sensitive sentinel'
      ;;
    esac
  done <"$log_file"
}

assert_curl_request_temp_files_removed() {
  local arg next_is_output=false next_is_payload=false next_is_config=false

  for arg in "${MODEL_PROFILE_CURL_ARGS[@]}"; do
    if [ "$next_is_config" = true ]; then
      assert_file_not_exists "$arg" 'curl authentication temporary config should be removed after request handling'
      next_is_config=false
      continue
    fi
    if [ "$next_is_output" = true ]; then
      assert_file_not_exists "$arg" 'curl response temporary file should be removed after request handling'
      next_is_output=false
      continue
    fi
    if [ "$next_is_payload" = true ]; then
      case "$arg" in
      @*)
        assert_file_not_exists "${arg#@}" 'curl request payload temporary file should be removed after request handling'
        ;;
      esac
      next_is_payload=false
      continue
    fi

    case "$arg" in
    -o)
      next_is_output=true
      ;;
    -K | --config)
      next_is_config=true
      ;;
    --data-binary)
      next_is_payload=true
      ;;
    --data-binary=@*)
      assert_file_not_exists "${arg#--data-binary=@}" 'curl request payload temporary file should be removed after request handling'
      ;;
    @*)
      assert_file_not_exists "${arg#@}" 'curl request payload temporary file should be removed after request handling'
      ;;
    esac
  done
}
