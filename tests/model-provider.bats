#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/model-provider"

setup() {
  TMP_HOME="$(mktemp -d)" || return 1
  export TMP_HOME
  export HOME="$TMP_HOME"
  export XDG_CONFIG_HOME="$TMP_HOME/.config"
  export XDG_DATA_HOME="$TMP_HOME/.local/share"
  export CONFIG_DIR="$XDG_CONFIG_HOME/model-provider"
  export DATA_DIR="$XDG_DATA_HOME/model-provider"
}

teardown() {
  rm -rf "$TMP_HOME"
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

assert_config_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local message="$4"

  assert_eq "$(git config -f "$file" --get "$key")" "$expected" "$message"
}

profile_file_path() {
  printf '%s/%s.conf\n' "$CONFIG_DIR" "$1"
}

token_file_path() {
  printf '%s/%s.token\n' "$DATA_DIR" "$1"
}

write_curl_stub() {
  local stub_bin="$1"

  mkdir -p "$stub_bin"
  cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=''
url=''
body=''
auth=''

while [ "$#" -gt 0 ]; do
  case "$1" in
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
  -d)
    body="$2"
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

printf '%s\n' "$url" >"$CURL_URL_LOG"
printf '%s\n' "$auth" >"$CURL_AUTH_LOG"
printf '%s\n' "$body" >"$CURL_BODY_LOG"
printf '%s\n' "$CURL_RESPONSE_BODY" >"$output_file"
printf '200'
EOF
  chmod +x "$stub_bin/curl"
}

write_jq_stub() {
  local stub_bin="$1"

  mkdir -p "$stub_bin"
  cat >"$stub_bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = '-n' ]; then
  model=''
  system_message=''
  user_message=''
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --arg)
      case "$2" in
      model)
        model="$3"
        ;;
      system_message)
        system_message="$3"
        ;;
      user_message)
        user_message="$3"
        ;;
      esac
      shift 3
      ;;
    *)
      shift
      ;;
    esac
  done

  printf '{"model":"%s","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}]}' "$model" "$system_message" "$user_message"
  exit 0
fi

if [ "${1:-}" = '-r' ]; then
  filter="$2"
  input=$(cat)

  case "$filter" in
  '.choices[0].message.content // empty')
    content=${input#*\"content\":\"}
    content=${content%%\"*}
    printf '%s\n' "$content"
    exit 0
    ;;
  '.error.message // .message // empty')
    if [[ "$input" == *\"message\":\"* ]]; then
      content=${input#*\"message\":\"}
      content=${content%%\"*}
      printf '%s\n' "$content"
    fi
    exit 0
    ;;
  esac
fi

exit 1
EOF
  chmod +x "$stub_bin/jq"
}

run_tool() {
  "$TOOL" "$@"
}

@test "help version and empty list" {
  local output version

  output=$(run_tool --help)
  assert_contains "$output" 'Usage: model-provider <command>' 'help should describe the command entrypoint'
  assert_contains "$output" 'list      List saved model provider profiles' 'help should describe the list command'
  assert_contains "$output" 'read      Show detailed information for a saved model provider profile' 'help should list the read command'

  version=$(run_tool --version)
  assert_eq "$version" "$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" 'version output should match VERSION file'

  output=$(run_tool list)
  assert_contains "$output" 'No model provider profiles found.' 'list should explain when there are no saved profiles'
}

@test "create azure-openai profile stores metadata and token separately" {
  local output profile_file token_file detail_output

  profile_file="$(profile_file_path work-openai)"
  token_file="$(token_file_path work-openai)"

  printf 'work-openai\n1\nexample-openai\ngpt-5, gpt-4o\nsecret-openai-token\n' |
    run_tool create >/dev/null 2>&1

  assert_file_exists "$profile_file" 'create should save provider metadata under config'
  assert_file_exists "$token_file" 'create should save the token under local data'
  assert_eq "$(<"$token_file")" 'secret-openai-token' 'token file should store the provided token'
  assert_config_value "$profile_file" provider.type 'azure-openai' 'config should store the provider type'
  assert_config_value "$profile_file" provider.resourceName 'example-openai' 'config should store the resource name'
  assert_config_value "$profile_file" provider.models 'gpt-5,gpt-4o' 'config should store the normalized model list'

  output=$(run_tool list)
  assert_contains "$output" '| # ' 'list should include the row index column'
  assert_contains "$output" 'work-openai' 'list should include the profile name'
  assert_contains "$output" 'Azure OpenAI' 'list should include the readable provider label'
  assert_contains "$output" 'example-openai' 'list should include the resource name'
  assert_contains "$output" 'gpt-5,gpt-4o' 'list should include the normalized model list'
  assert_contains "$output" ' yes ' 'list should report that the token exists'

  assert_not_contains "$output" 'Actions:' 'list should not prompt for follow-up actions'
  assert_not_contains "$output" 'Select profile for details' 'list should not prompt for detail selection'

  detail_output=$(printf '1\n' | run_tool read)
  assert_contains "$detail_output" 'Azure OpenAI' 'read should show the readable provider label'
  assert_contains "$detail_output" 'example-openai' 'read should show the Azure resource name'
  assert_contains "$detail_output" 'https://example-openai.openai.azure.com/' 'read should show the generated Azure OpenAI endpoint'
  assert_contains "$detail_output" 'Models' 'read should show the models field'
  assert_contains "$detail_output" 'gpt-5,gpt-4o' 'read should show the normalized model list'
  assert_contains "$detail_output" 'Token Stored' 'read should show the token stored field'
  assert_contains "$detail_output" 'yes' 'read should show that the token is stored'
  assert_contains "$detail_output" "$profile_file" 'read should show the config path'
  assert_contains "$detail_output" "$token_file" 'read should show the token path'
  assert_not_contains "$detail_output" 'secret-openai-token' 'read should not print the token value'
}

@test "create normalizes comma-separated model values" {
  local profile_file output

  profile_file="$(profile_file_path normalized-models)"

  printf 'normalized-models\n1\nexample-openai\ngpt-5, gpt-4o ,  o3-mini\nsecret-openai-token\n' |
    run_tool create >/dev/null 2>&1

  assert_config_value "$profile_file" provider.models 'gpt-5,gpt-4o,o3-mini' 'create should trim whitespace around comma-separated model names'

  output=$(run_tool list)
  assert_contains "$output" 'gpt-5,gpt-4o,o3-mini' 'list should show normalized model values'
}

@test "create supports azure-cognitive-services, gemini, and custom" {
  local output

  printf 'vision\n2\nexample-vision\nvision, document-intelligence\nvision-secret\n' |
    run_tool create >/dev/null 2>&1
  printf 'gemini-main\n3\ngemini-2.5-pro, gemini-2.5-flash\ngemini-secret\n' |
    run_tool create >/dev/null 2>&1
  printf 'custom-main\n4\nhttps://custom.example.com/openai/v1\ncustom-model, custom-model-2\ncustom-secret\n' |
    run_tool create >/dev/null 2>&1

  assert_config_value "$(profile_file_path vision)" provider.type 'azure-cognitive-services' 'create should support azure-cognitive-services'
  assert_config_value "$(profile_file_path vision)" provider.resourceName 'example-vision' 'azure-cognitive-services should store a resource name'
  assert_file_exists "$(token_file_path vision)" 'azure-cognitive-services should store a token file'

  assert_config_value "$(profile_file_path gemini-main)" provider.type 'gemini' 'create should support gemini'
  assert_config_value "$(profile_file_path vision)" provider.models 'vision,document-intelligence' 'azure-cognitive-services should store the normalized model list'
  assert_config_value "$(profile_file_path gemini-main)" provider.models 'gemini-2.5-pro,gemini-2.5-flash' 'gemini should store the normalized model list'
  assert_file_exists "$(token_file_path gemini-main)" 'gemini should store a token file'

  assert_config_value "$(profile_file_path custom-main)" provider.type 'custom' 'create should support custom'
  assert_config_value "$(profile_file_path custom-main)" provider.endpointUrl 'https://custom.example.com/openai/v1/' 'custom should store a normalized endpoint URL'
  assert_config_value "$(profile_file_path custom-main)" provider.models 'custom-model,custom-model-2' 'custom should store the normalized model list'
  assert_eq "$(git config -f "$(profile_file_path custom-main)" --get provider.resourceName 2>/dev/null || true)" '' 'custom should not store a resource name'
  assert_file_exists "$(token_file_path custom-main)" 'custom should store a token file'

  output=$(run_tool list)
  assert_contains "$output" 'vision' 'list should include azure-cognitive-services profiles'
  assert_contains "$output" 'gemini-main' 'list should include gemini profiles'
  assert_contains "$output" 'custom-main' 'list should include custom profiles'
  assert_contains "$output" 'https://custom.example.com/openai/v1/' 'list should show the custom endpoint URL'
}

@test "profiles and models commands expose saved configuration" {
  local output

  printf 'vision\n2\nexample-vision\nvision, document-intelligence\nvision-secret\n' |
    run_tool create >/dev/null 2>&1
  printf 'gemini-main\n3\ngemini-2.5-pro, gemini-2.5-flash\ngemini-secret\n' |
    run_tool create >/dev/null 2>&1

  output=$(run_tool profiles)
  assert_contains "$output" 'vision' 'profiles should include azure-cognitive-services profiles'
  assert_contains "$output" 'gemini-main' 'profiles should include gemini profiles'

  output=$(run_tool models gemini-main)
  assert_contains "$output" 'gemini-2.5-pro' 'models should include the first configured model'
  assert_contains "$output" 'gemini-2.5-flash' 'models should include the second configured model'
}

@test "create supports profile names with spaces" {
  local profile_file token_file output detail_output

  profile_file="$(profile_file_path 'work openai')"
  token_file="$(token_file_path 'work openai')"

  printf 'work openai\n1\nexample-openai\ngpt-5, gpt-4o\nsecret-openai-token\n' |
    run_tool create >/dev/null 2>&1

  assert_file_exists "$profile_file" 'create should save config files for names with spaces'
  assert_file_exists "$token_file" 'create should save token files for names with spaces'

  output=$(run_tool list)
  assert_contains "$output" 'work openai' 'list should include profile names with spaces'

  assert_not_contains "$output" 'Select profile for details' 'list should stay non-interactive for names with spaces'

  detail_output=$(printf '1\n' | run_tool read)
  assert_contains "$detail_output" 'work openai' 'read should show profile names with spaces'
}

@test "ask sends chat completion to azure-openai" {
  local stub_bin curl_url_log curl_auth_log curl_body_log output

  stub_bin="$TMP_HOME/bin"
  curl_url_log="$TMP_HOME/curl-url.log"
  curl_auth_log="$TMP_HOME/curl-auth.log"
  curl_body_log="$TMP_HOME/curl-body.log"

  write_curl_stub "$stub_bin"
  write_jq_stub "$stub_bin"

  printf 'work-openai\n1\nexample-openai\ngpt-5, gpt-4o\nsecret-openai-token\n' |
    run_tool create >/dev/null 2>&1

  output=$(PATH="$stub_bin:$PATH" \
    CURL_URL_LOG="$curl_url_log" \
    CURL_AUTH_LOG="$curl_auth_log" \
    CURL_BODY_LOG="$curl_body_log" \
    CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"azure answer"}}]}' \
    "$TOOL" ask work-openai --model gpt-4o --message 'Hello from test')

  assert_eq "$output" 'azure answer' 'ask should print the response text'
  assert_eq "$(<"$curl_url_log")" 'https://example-openai.openai.azure.com/openai/v1/chat/completions' 'ask should use the Azure OpenAI base URL'
  assert_eq "$(<"$curl_auth_log")" 'Authorization: Bearer secret-openai-token' 'ask should send the stored API key as a bearer token'
  assert_contains "$(<"$curl_body_log")" '"model":"gpt-4o"' 'ask should send the selected model'
  assert_contains "$(<"$curl_body_log")" '"role":"system","content":"You are a helpful assistant."' 'ask should send the default system message'
  assert_contains "$(<"$curl_body_log")" '"role":"user","content":"Hello from test"' 'ask should send the prompted user message'
}

@test "ask supports interactive mode with no arguments" {
  local stub_bin curl_url_log curl_auth_log curl_body_log output

  stub_bin="$TMP_HOME/bin"
  curl_url_log="$TMP_HOME/curl-url.log"
  curl_auth_log="$TMP_HOME/curl-auth.log"
  curl_body_log="$TMP_HOME/curl-body.log"

  write_curl_stub "$stub_bin"
  write_jq_stub "$stub_bin"

  printf 'work-openai\n1\nexample-openai\ngpt-5, gpt-4o\nsecret-openai-token\n' |
    run_tool create >/dev/null 2>&1

  output=$(printf '1\n2\n\nHello from interactive mode\n' |
    PATH="$stub_bin:$PATH" \
      CURL_URL_LOG="$curl_url_log" \
      CURL_AUTH_LOG="$curl_auth_log" \
      CURL_BODY_LOG="$curl_body_log" \
      CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"interactive answer"}}]}' \
      "$TOOL" ask)

  assert_eq "$output" 'interactive answer' 'interactive ask should print the response text'
  assert_eq "$(<"$curl_url_log")" 'https://example-openai.openai.azure.com/openai/v1/chat/completions' 'interactive ask should use the Azure OpenAI base URL'
  assert_contains "$(<"$curl_body_log")" '"model":"gpt-4o"' 'interactive ask should send the selected model'
  assert_contains "$(<"$curl_body_log")" '"role":"system","content":"You are a helpful assistant."' 'interactive ask should send the default system message'
  assert_contains "$(<"$curl_body_log")" '"role":"user","content":"Hello from interactive mode"' 'interactive ask should send the prompted user message'
}

@test "ask sends chat completion to gemini" {
  local stub_bin curl_url_log curl_auth_log curl_body_log output

  stub_bin="$TMP_HOME/bin"
  curl_url_log="$TMP_HOME/curl-url.log"
  curl_auth_log="$TMP_HOME/curl-auth.log"
  curl_body_log="$TMP_HOME/curl-body.log"

  write_curl_stub "$stub_bin"
  write_jq_stub "$stub_bin"

  printf 'gemini-main\n3\ngemini-2.5-pro, gemini-2.5-flash\ngemini-secret\n' |
    run_tool create >/dev/null 2>&1

  output=$(PATH="$stub_bin:$PATH" \
    CURL_URL_LOG="$curl_url_log" \
    CURL_AUTH_LOG="$curl_auth_log" \
    CURL_BODY_LOG="$curl_body_log" \
    CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"gemini answer"}}]}' \
    "$TOOL" ask gemini-main --system-message 'Talk like a pirate' --user-message 'Hello Gemini')

  assert_eq "$output" 'gemini answer' 'ask should print the Gemini response text'
  assert_eq "$(<"$curl_url_log")" 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions' 'ask should use the Gemini OpenAI-compatible base URL'
  assert_eq "$(<"$curl_auth_log")" 'Authorization: Bearer gemini-secret' 'ask should send the Gemini API key as a bearer token'
  assert_contains "$(<"$curl_body_log")" '"model":"gemini-2.5-pro"' 'ask should default to the first configured model'
  assert_contains "$(<"$curl_body_log")" '"role":"system","content":"Talk like a pirate"' 'ask should send the custom system message'
  assert_contains "$(<"$curl_body_log")" '"role":"user","content":"Hello Gemini"' 'ask should send the prompted user message'
}

@test "ask sends chat completion to custom endpoint" {
  local stub_bin curl_url_log curl_auth_log curl_body_log output

  stub_bin="$TMP_HOME/bin"
  curl_url_log="$TMP_HOME/curl-url.log"
  curl_auth_log="$TMP_HOME/curl-auth.log"
  curl_body_log="$TMP_HOME/curl-body.log"

  write_curl_stub "$stub_bin"
  write_jq_stub "$stub_bin"

  printf 'custom-main\n4\nhttps://custom.example.com/openai/v1\ncustom-model, custom-model-2\ncustom-secret\n' |
    run_tool create >/dev/null 2>&1

  output=$(PATH="$stub_bin:$PATH" \
    CURL_URL_LOG="$curl_url_log" \
    CURL_AUTH_LOG="$curl_auth_log" \
    CURL_BODY_LOG="$curl_body_log" \
    CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"custom answer"}}]}' \
    "$TOOL" ask custom-main --model custom-model-2 --message 'Hello Custom')

  assert_eq "$output" 'custom answer' 'ask should print the custom response text'
  assert_eq "$(<"$curl_url_log")" 'https://custom.example.com/openai/v1/chat/completions' 'ask should use the configured custom endpoint URL'
  assert_eq "$(<"$curl_auth_log")" 'Authorization: Bearer custom-secret' 'ask should send the custom API key as a bearer token'
  assert_contains "$(<"$curl_body_log")" '"model":"custom-model-2"' 'ask should send the selected custom model'
  assert_contains "$(<"$curl_body_log")" '"role":"user","content":"Hello Custom"' 'ask should send the prompted custom user message'
}

@test "ask CLI defaults to the first configured model" {
  local stub_bin curl_body_log output

  stub_bin="$TMP_HOME/bin"
  curl_body_log="$TMP_HOME/curl-body.log"

  write_curl_stub "$stub_bin"
  write_jq_stub "$stub_bin"

  printf 'gemini-main\n3\ngemini-2.5-pro, gemini-2.5-flash\ngemini-secret\n' |
    run_tool create >/dev/null 2>&1

  output=$(PATH="$stub_bin:$PATH" \
    CURL_URL_LOG="$TMP_HOME/curl-url.log" \
    CURL_AUTH_LOG="$TMP_HOME/curl-auth.log" \
    CURL_BODY_LOG="$curl_body_log" \
    CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"gemini answer"}}]}' \
    "$TOOL" ask gemini-main --message 'Hello Gemini')

  assert_eq "$output" 'gemini answer' 'ask should print the response text when defaulting the model'
  assert_contains "$(<"$curl_body_log")" '"model":"gemini-2.5-pro"' 'ask should default to the first configured model'
}

@test "update rewrites metadata and can replace the token" {
  local profile_file token_file

  printf 'work-openai\n1\nexample-openai\ngpt-5, gpt-4o\nsecret-openai-token\n' |
    run_tool create >/dev/null 2>&1

  profile_file="$(profile_file_path work-openai)"
  token_file="$(token_file_path work-openai)"

  printf '1\n4\nhttps://custom.example.com/openai/v1\ncustom-model-1, custom-model-2\ny\nreplacement-token\n' | run_tool update >/dev/null 2>&1

  assert_config_value "$profile_file" provider.type 'custom' 'update should allow changing the provider type'
  assert_eq "$(git config -f "$profile_file" --get provider.resourceName 2>/dev/null || true)" '' 'update should remove resourceName when unused by the new provider type'
  assert_config_value "$profile_file" provider.endpointUrl 'https://custom.example.com/openai/v1/' 'update should store the custom endpoint URL'
  assert_config_value "$profile_file" provider.models 'custom-model-1,custom-model-2' 'update should store the normalized model list'
  assert_eq "$(<"$token_file")" 'replacement-token' 'update should replace the stored token when requested'
}

@test "delete removes profile metadata and token" {
  local profile_file token_file

  printf 'gemini-main\n3\ngemini-2.5-pro, gemini-2.5-flash\ngemini-secret\n' |
    run_tool create >/dev/null 2>&1

  profile_file="$(profile_file_path gemini-main)"
  token_file="$(token_file_path gemini-main)"

  printf '1\ny\n' | run_tool delete >/dev/null 2>&1

  assert_file_not_exists "$profile_file" 'delete should remove the config file'
  assert_file_not_exists "$token_file" 'delete should remove the token file'
}

@test "create reprompts for unsupported provider selections" {
  local output

  output=$(printf 'broken\n9\n1\nexample-openai\ngpt-5, gpt-4o\nsecret\n' | run_tool create 2>&1)

  assert_contains "$output" 'Provider types:' 'create should show the numbered provider menu'
  assert_contains "$output" '1. Azure OpenAI' 'create should show readable provider labels'
  assert_contains "$output" '4. Custom' 'create should show the custom provider label'
  assert_contains "$output" 'Please choose 1, 2, 3, or 4.' 'create should reject unsupported provider selections before continuing'
  assert_file_exists "$(profile_file_path broken)" 'create should continue after a valid provider type is entered'
}
