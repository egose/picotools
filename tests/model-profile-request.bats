#!/usr/bin/env bats

load 'helpers/model-profile'

setup() {
  setup_model_profile_test
  write_model_profile_curl_fake
}

teardown() {
  teardown_model_profile_test
}

repeat_bytes() {
  local count="$1"
  local char="${2:-x}"

  printf '%*s' "$count" '' | tr ' ' "$char"
}

chat_payload_size() {
  local model="$1"
  local system_message="$2"
  local user_message="$3"
  local system_message_file user_message_file payload_file size

  system_message_file="$TMP_HOME/payload-system.txt"
  user_message_file="$TMP_HOME/payload-user.txt"
  payload_file="$TMP_HOME/payload.json"
  printf '%s' "$system_message" >"$system_message_file"
  printf '%s' "$user_message" >"$user_message_file"
  # shellcheck disable=SC2016
  "$MODEL_PROFILE_REAL_JQ" -n \
    --arg model "$model" \
    --rawfile system_message "$system_message_file" \
    --rawfile user_message "$user_message_file" \
    '{model: $model, messages: [{role: "system", content: $system_message}, {role: "user", content: $user_message}]}' >"$payload_file"
  size=$(wc -c <"$payload_file")
  rm -f "$system_message_file" "$user_message_file" "$payload_file"
  printf '%s\n' "$size"
}

@test "ask sends chat completion to azure-openai" {
  local output

  create_azure_openai_profile

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"azure answer"}}]}' \
    run_tool ask work-openai --model gpt-4o --message 'Hello from test')

  assert_eq "$output" 'azure answer' 'ask should print the response text'
  assert_eq "$(<"$MODEL_PROFILE_CURL_URL_LOG")" 'https://example-openai.openai.azure.com/openai/v1/chat/completions' 'ask should use the Azure OpenAI base URL'
  assert_secret_eq "$(<"$MODEL_PROFILE_CURL_AUTH_LOG")" 'Authorization: Bearer secret-openai-token' 'ask should send the stored API key as a bearer token'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.model' 'gpt-4o' 'ask should send the selected model'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[0].content' 'You are a helpful assistant.' 'ask should send the default system message'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[1].content' 'Hello from test' 'ask should send the prompted user message'
  read_curl_args
  assert_curl_request_temp_files_removed
}

@test "request body round-trips special characters through real jq" {
  local output system_message user_message

  system_message=$'System "quoted" \\ path\ttab\nline café 雪'
  user_message=$'User "quoted" \\ slash\ttab\nsecond line café 雪'

  create_azure_openai_profile work-openai "$MODEL_PROFILE_API_KEY_SENTINEL"
  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"special answer"}}]}' \
    run_tool ask work-openai --model gpt-4o --system-message "$system_message" --message "$user_message")

  assert_eq "$output" 'special answer' 'ask should print the response text for special-character prompts'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[0].content' "$system_message" 'system message should round-trip through generated JSON exactly'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[1].content' "$user_message" 'user message should round-trip through generated JSON exactly'
  read_curl_args "$MODEL_PROFILE_CURL_PUBLIC_ARGS_NUL_LOG"
  assert_no_curl_arg_contains "$MODEL_PROFILE_API_KEY_SENTINEL" "$MODEL_PROFILE_CURL_PUBLIC_ARGS_NUL_LOG"
}

@test "curl argv excludes secrets and uses an option-safe URL operand" {
  local prompt_sentinel='model-profile-test-prompt-sentinel'

  create_azure_openai_profile work-openai "$MODEL_PROFILE_API_KEY_SENTINEL"

  PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"debug answer"}}]}' \
    MODEL_PROFILE_CURL_MAX_TIME=42 \
    run_tool ask work-openai --model gpt-4o --message "$prompt_sentinel" >/dev/null

  read_curl_args
  assert_curl_arg_eq 0 '-q' 'curl should disable ambient configuration as the first argument'
  assert_curl_arg_eq 2 '--proxy' 'curl should explicitly configure proxy behavior'
  assert_curl_arg_eq 3 '' 'curl should disable proxy use'
  assert_curl_arg_eq 4 '--noproxy' 'curl should explicitly bypass proxies'
  assert_curl_arg_eq 5 '*' 'curl should bypass proxies for every destination'
  assert_curl_arg_eq 6 '--max-redirs' 'curl should explicitly configure redirect behavior'
  assert_curl_arg_eq 7 '0' 'curl should not follow redirects'
  assert_curl_arg_eq 8 '--proto' 'curl should explicitly configure allowed protocols'
  assert_curl_arg_eq 9 '=https' 'curl should only allow HTTPS requests'
  assert_curl_arg_eq 10 '--proto-redir' 'curl should explicitly configure redirect protocols'
  assert_curl_arg_eq 11 '=https' 'curl should only allow HTTPS redirect targets if redirects are ever enabled'
  assert_curl_arg_eq 12 '--connect-timeout' 'curl should keep --connect-timeout as its own argument'
  assert_curl_arg_eq 13 '10' 'curl should pass the default connect timeout'
  assert_curl_arg_eq 14 '--max-time' 'curl should keep --max-time as its own argument'
  assert_curl_arg_eq 15 '42' 'curl should keep the max-time value as its own argument'
  assert_curl_arg_before_url '--' 'curl should pass the request URL after an explicit operand separator'
  assert_eq "$(<"$MODEL_PROFILE_CURL_AUTH_CONFIG_MODE_LOG")" '600' 'curl auth config should be mode 0600 while curl reads it'
  assert_no_curl_arg_contains "$MODEL_PROFILE_API_KEY_SENTINEL" "$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
  assert_no_curl_arg_contains "$prompt_sentinel" "$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
  assert_curl_request_temp_files_removed
}

@test "hostile curlrc cannot change request policy" {
  create_azure_openai_profile work-openai "$MODEL_PROFILE_API_KEY_SENTINEL"
  printf '%s\n' 'trace = trace.log' 'location' 'proxy = http://proxy.invalid:8080' 'output = stolen.out' >"$HOME/.curlrc"

  PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"policy answer"}}]}' \
    run_tool ask work-openai --model gpt-4o --message 'Hello from test' >/dev/null

  read_curl_args
  assert_curl_arg_eq 0 '-q' 'curl should ignore hostile .curlrc before any other curl argument'
  assert_curl_arg_eq 2 '--proxy' 'curl should explicitly override proxy configuration'
  assert_curl_arg_eq 3 '' 'curl should disable proxy use despite .curlrc'
  assert_curl_arg_eq 6 '--max-redirs' 'curl should explicitly configure redirects despite .curlrc'
  assert_curl_arg_eq 7 '0' 'curl should not follow redirects from .curlrc'
  assert_file_not_exists "$HOME/trace.log" 'hostile .curlrc trace output should not be created'
  assert_file_not_exists "$HOME/stolen.out" 'hostile .curlrc alternate output should not be created'
  assert_no_curl_arg_contains "$MODEL_PROFILE_API_KEY_SENTINEL" "$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
}

@test "test sends a tiny connection check and prints details" {
  local output

  create_azure_openai_profile
  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"OK"}}]}' \
    run_tool test work-openai)

  assert_contains "$output" '| Field ' 'test should render a two-column table'
  assert_contains "$output" '| Profile ' 'test should show the selected profile name'
  assert_contains "$output" 'work-openai' 'test should print the profile value'
  assert_contains "$output" '| Type ' 'test should show the provider type'
  assert_contains "$output" 'Azure OpenAI' 'test should show the readable provider label'
  assert_contains "$output" '| Endpoint ' 'test should show the provider endpoint'
  assert_contains "$output" 'https://example-openai.openai.azure.com/' 'test should print the resolved endpoint'
  assert_contains "$output" '| Model ' 'test should show the selected model'
  assert_contains "$output" 'gpt-5' 'test should default to the first configured model'
  assert_contains "$output" '| Status ' 'test should show the request status'
  assert_contains "$output" 'OK' 'test should print the probe response'
  assert_eq "$(<"$MODEL_PROFILE_CURL_URL_LOG")" 'https://example-openai.openai.azure.com/openai/v1/chat/completions' 'test should use the provider chat completions endpoint'
  assert_secret_eq "$(<"$MODEL_PROFILE_CURL_AUTH_LOG")" 'Authorization: Bearer secret-openai-token' 'test should send the stored API key as a bearer token'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.model' 'gpt-5' 'test should use the default configured model when --model is omitted'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[0].content' 'You are a connection test. Reply with the single word OK.' 'test should send the fixed system message'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[1].content' 'Reply with OK.' 'test should send the fixed user message'
}

@test "ask reads large prompt content from files" {
  local system_message_file user_message_file output

  system_message_file="$TMP_HOME/system-message.txt"
  user_message_file="$TMP_HOME/user-message.txt"
  printf '%s' 'System message loaded from file' >"$system_message_file"
  printf '%s' 'User message loaded from file' >"$user_message_file"

  create_azure_openai_profile
  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"file answer"}}]}' \
    run_tool ask work-openai --model gpt-4o --system-message-file "$system_message_file" --message-file "$user_message_file")

  assert_eq "$output" 'file answer' 'ask should print the response text when reading prompt files'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[0].content' 'System message loaded from file' 'ask should load the system message from a file'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[1].content' 'User message loaded from file' 'ask should load the user message from a file'
  read_curl_args
  assert_curl_request_temp_files_removed
}

@test "message files must be safe readable regular files" {
  local regular_file symlink_file fifo_file unsafe_path

  regular_file="$TMP_HOME/regular-message.txt"
  symlink_file="$TMP_HOME/symlink-message.txt"
  fifo_file="$TMP_HOME/fifo-message.txt"
  printf '%s' 'regular message' >"$regular_file"
  ln -s "$regular_file" "$symlink_file"
  mkfifo "$fifo_file"

  create_azure_openai_profile

  for unsafe_path in "$symlink_file" "$fifo_file" /dev/null; do
    rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
      "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message-file "$unsafe_path"

    assert_eq "$status" 1 "unsafe message file should fail: $unsafe_path"
    assert_contains "$output" 'regular file' 'unsafe message file should explain the regular-file policy'
    assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "unsafe message file should not invoke curl: $unsafe_path"
  done
}

@test "oversized message file fails before request construction" {
  local user_message_file

  user_message_file="$TMP_HOME/oversized-message.txt"
  repeat_bytes 33 >"$user_message_file"
  create_azure_openai_profile

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_MAX_PAYLOAD_BYTES=32 \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --system-message '' --message-file "$user_message_file"

  assert_eq "$status" 1 'oversized message file should fail before curl'
  assert_contains "$output" 'user message exceeds request payload limit of 32 bytes' 'oversized message file should report the configured limit'
  assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" 'oversized message file should not invoke curl'
  assert_file_not_exists "$MODEL_PROFILE_CURL_BODY_LOG" 'oversized message file should not construct a curl payload'
}

@test "payload byte cap accepts the exact edge and rejects one byte above" {
  local user_message payload_size output

  user_message='payload edge prompt'
  payload_size=$(chat_payload_size gpt-4o '' "$user_message")
  create_azure_openai_profile

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_MAX_PAYLOAD_BYTES="$payload_size" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"payload edge answer"}}]}' \
    run_tool ask work-openai --model gpt-4o --system-message '' --message "$user_message")

  assert_eq "$output" 'payload edge answer' 'payload at the configured cap should be accepted'
  read_curl_args
  assert_curl_request_temp_files_removed

  rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_MAX_PAYLOAD_BYTES="$((payload_size - 1))" \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --system-message '' --message "$user_message"

  assert_eq "$status" 1 'payload one byte over the cap should fail'
  assert_contains "$output" 'request payload exceeds limit' 'payload overflow should report a bounded error'
  assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" 'oversized payload should not invoke curl'
}

@test "ask prints debug steps and honors curl max time env" {
  local output

  create_azure_openai_profile
  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"debug answer"}}]}' \
    MODEL_PROFILE_CURL_MAX_TIME=42 \
    run_tool ask --debug work-openai --model gpt-4o --message 'Hello from test' 2>&1)

  assert_contains "$output" '[model-profile] Preparing chat completion request for profile' 'ask should print request preparation in debug mode'
  assert_contains "$output" '[model-profile] Starting HTTP request' 'ask should print the HTTP request start in debug mode'
  assert_contains "$output" '[model-profile] HTTP request completed with status 200' 'ask should print the HTTP status in debug mode'
  assert_contains "$output" 'debug answer' 'ask should still print the response text in debug mode'
  read_curl_args
  assert_curl_arg_eq 12 '--connect-timeout' 'ask should pass the default curl connect timeout flag'
  assert_curl_arg_eq 13 '10' 'ask should pass the default curl connect timeout value'
  assert_curl_arg_eq 14 '--max-time' 'ask should pass the configured curl max time flag'
  assert_curl_arg_eq 15 '42' 'ask should pass the configured curl max time value'
}

@test "ask warns when deprecated MODEL_PROFILE_DEBUG env is used" {
  local output

  create_azure_openai_profile
  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"debug answer"}}]}' \
    MODEL_PROFILE_DEBUG=true \
    run_tool ask work-openai --model gpt-4o --message 'Hello from test' 2>&1)

  assert_contains "$output" 'Warning: MODEL_PROFILE_DEBUG is deprecated; use --debug instead.' 'ask should warn when the deprecated debug env is used'
  assert_contains "$output" '[model-profile] Preparing chat completion request for profile' 'ask should still enable debug logging via the deprecated env'
  assert_contains "$output" 'debug answer' 'ask should still print the response text when using the deprecated env'
}

@test "ask supports interactive mode with no arguments" {
  local output

  create_azure_openai_profile
  output=$(printf '1\n2\n\nHello from interactive mode\n' |
    PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
      MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"interactive answer"}}]}' \
      run_tool ask)

  assert_eq "$output" 'interactive answer' 'interactive ask should print the response text'
  assert_eq "$(<"$MODEL_PROFILE_CURL_URL_LOG")" 'https://example-openai.openai.azure.com/openai/v1/chat/completions' 'interactive ask should use the Azure OpenAI base URL'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.model' 'gpt-4o' 'interactive ask should send the selected model'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[0].content' 'You are a helpful assistant.' 'interactive ask should send the default system message'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[1].content' 'Hello from interactive mode' 'interactive ask should send the prompted user message'
}

@test "ask sends chat completion to gemini" {
  local output

  printf 'gemini-main\n3\ngemini-2.5-pro, gemini-2.5-flash\ngemini-secret\n' |
    run_tool create >/dev/null 2>&1

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"gemini answer"}}]}' \
    run_tool ask gemini-main --system-message 'Talk like a pirate' --user-message 'Hello Gemini')

  assert_eq "$output" 'gemini answer' 'ask should print the Gemini response text'
  assert_eq "$(<"$MODEL_PROFILE_CURL_URL_LOG")" 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions' 'ask should use the Gemini OpenAI-compatible base URL'
  assert_secret_eq "$(<"$MODEL_PROFILE_CURL_AUTH_LOG")" 'Authorization: Bearer gemini-secret' 'ask should send the Gemini API key as a bearer token'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.model' 'gemini-2.5-pro' 'ask should default to the first configured model'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[0].content' 'Talk like a pirate' 'ask should send the custom system message'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[1].content' 'Hello Gemini' 'ask should send the prompted user message'
}

@test "ask sends chat completion to custom endpoint" {
  local output

  printf 'custom-main\n4\nhttps://custom.example.com/openai/v1\ncustom-model, custom-model-2\ncustom-secret\n' |
    run_tool create >/dev/null 2>&1

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"custom answer"}}]}' \
    run_tool ask custom-main --model custom-model-2 --message 'Hello Custom')

  assert_eq "$output" 'custom answer' 'ask should print the custom response text'
  assert_eq "$(<"$MODEL_PROFILE_CURL_URL_LOG")" 'https://custom.example.com/openai/v1/chat/completions' 'ask should use the configured custom endpoint URL'
  assert_secret_eq "$(<"$MODEL_PROFILE_CURL_AUTH_LOG")" 'Authorization: Bearer custom-secret' 'ask should send the custom API key as a bearer token'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.model' 'custom-model-2' 'ask should send the selected custom model'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.messages[1].content' 'Hello Custom' 'ask should send the prompted custom user message'
}

@test "custom request URL preserves validated scheme and authority" {
  local output request_url

  printf 'custom-origin\n4\nhttps://api.custom.example.com:8443/openai/v1//nested\ncustom-model\ncustom-secret\n' |
    run_tool create >/dev/null 2>&1

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"origin answer"}}]}' \
    run_tool ask custom-origin --message 'Hello Custom')

  request_url="$(<"$MODEL_PROFILE_CURL_URL_LOG")"
  assert_eq "$output" 'origin answer' 'ask should complete against a custom endpoint with port and path'
  assert_eq "$request_url" 'https://api.custom.example.com:8443/openai/v1//nested/chat/completions' 'ask should append the chat path without replacing the endpoint authority'
  assert_contains "$request_url" 'https://api.custom.example.com:8443/' 'request URL should keep the validated custom scheme and authority'
}

@test "ask CLI defaults to the first configured model" {
  local output

  printf 'gemini-main\n3\ngemini-2.5-pro, gemini-2.5-flash\ngemini-secret\n' |
    run_tool create >/dev/null 2>&1

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"gemini answer"}}]}' \
    run_tool ask gemini-main --message 'Hello Gemini')

  assert_eq "$output" 'gemini answer' 'ask should print the response text when defaulting the model'
  assert_json_string_eq "$MODEL_PROFILE_CURL_BODY_LOG" '.model' 'gemini-2.5-pro' 'ask should default to the first configured model'
}

@test "transport failure returns status and stderr" {
  create_azure_openai_profile

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_SCENARIO=transport_failure \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

  assert_eq "$status" 1 'transport failure should return status 1'
  assert_contains "$output" 'curl: simulated transport failure' 'transport failure should include curl stderr'
  read_curl_args
  assert_curl_request_temp_files_removed
}

@test "invalid timeout and size overrides fail before curl" {
  local env_name env_value

  create_azure_openai_profile

  for env_name in MODEL_PROFILE_CURL_CONNECT_TIMEOUT MODEL_PROFILE_CURL_MAX_TIME MODEL_PROFILE_MAX_PAYLOAD_BYTES MODEL_PROFILE_MAX_RESPONSE_BYTES MODEL_PROFILE_MAX_DIAGNOSTIC_BYTES; do
    for env_value in 0 invalid; do
      rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
      run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
        "$env_name=$env_value" \
        "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

      assert_eq "$status" 1 "invalid limit should fail: $env_name=$env_value"
      assert_contains "$output" "Error: $env_name must be" 'invalid limit should identify the rejected override'
      assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "invalid limit should not invoke curl: $env_name=$env_value"
    done
  done
}

@test "connect timeout and stalled body produce stable bounded errors" {
  local scenario expected

  create_azure_openai_profile

  for scenario in connect_timeout stalled_body; do
    case "$scenario" in
    connect_timeout)
      expected='curl: simulated connect timeout after 1 seconds'
      ;;
    stalled_body)
      expected='curl: simulated total timeout after 1 seconds'
      ;;
    esac

    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
      MODEL_PROFILE_CURL_SCENARIO="$scenario" \
      MODEL_PROFILE_CURL_CONNECT_TIMEOUT=1 \
      MODEL_PROFILE_CURL_MAX_TIME=1 \
      "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

    assert_eq "$status" 1 "timeout scenario should return status 1: $scenario"
    assert_contains "$output" "$expected" "timeout scenario should include bounded curl stderr: $scenario"
    read_curl_args
    assert_curl_arg_eq 12 '--connect-timeout' 'curl should receive the connect timeout flag'
    assert_curl_arg_eq 13 '1' 'curl should receive the configured connect timeout'
    assert_curl_arg_eq 14 '--max-time' 'curl should receive the total timeout flag'
    assert_curl_arg_eq 15 '1' 'curl should receive the configured total timeout'
    assert_curl_request_temp_files_removed
  done
}

@test "temporary auth config is removed when request is interrupted" {
  local auth_config_path

  create_azure_openai_profile work-openai "$MODEL_PROFILE_API_KEY_SENTINEL"

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_SCENARIO=signal_parent \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

  [ "$status" -ne 0 ] || fail 'interrupted request should exit nonzero'
  auth_config_path="$(<"$MODEL_PROFILE_CURL_AUTH_CONFIG_PATH_LOG")"
  assert_file_not_exists "$auth_config_path" 'curl authentication temporary config should be removed after handled signals'
}

@test "redirect responses are not followed and do not expose credentials in argv" {
  local redirect_location
  local -a redirect_locations=(
    'https://example-openai.openai.azure.com/openai/v1/other'
    'https://attacker.example.com/openai/v1/chat/completions'
    'http://example-openai.openai.azure.com/openai/v1/chat/completions'
  )

  create_azure_openai_profile work-openai "$MODEL_PROFILE_API_KEY_SENTINEL"

  for redirect_location in "${redirect_locations[@]}"; do
    rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "$MODEL_PROFILE_CURL_AUTH_CONFIG_PATH_LOG"
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
      MODEL_PROFILE_CURL_SCENARIO=non_2xx \
      MODEL_PROFILE_CURL_HTTP_CODE=302 \
      MODEL_PROFILE_CURL_RESPONSE_BODY="{\"error\":{\"message\":\"redirect blocked to $redirect_location\"}}" \
      "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

    assert_eq "$status" 1 "redirect response should fail without following: $redirect_location"
    assert_contains "$output" 'Error: redirect blocked to' 'redirect response should use non-secret diagnostics'
    read_curl_args
    assert_curl_arg_eq 6 '--max-redirs' 'curl should configure redirect count explicitly'
    assert_curl_arg_eq 7 '0' 'curl should not follow redirects'
    assert_no_curl_arg_contains "$MODEL_PROFILE_API_KEY_SENTINEL" "$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
    assert_curl_request_temp_files_removed
  done
}

@test "option-like persisted custom endpoint is rejected before curl" {
  write_model_profile_config option-url custom '--output=leak' custom-model "$MODEL_PROFILE_API_KEY_SENTINEL"

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    "$MODEL_PROFILE_TOOL" ask option-url --model custom-model --message 'Hello from test'

  assert_eq "$status" 1 'option-like custom endpoint should fail validation before curl'
  assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" 'option-like custom endpoint should not invoke curl'
}

@test "malformed credential bytes are rejected before curl" {
  local name token_file
  local -a names=(bad-cr bad-lf bad-nul bad-quote)

  for name in "${names[@]}"; do
    write_model_profile_config "$name" azure-openai example-openai gpt-5 good-token
  done
  printf 'bad\rkey\n' >"$(token_file_path bad-cr)"
  printf 'bad\nkey\n' >"$(token_file_path bad-lf)"
  printf 'bad\0key\n' >"$(token_file_path bad-nul)"
  printf 'bad"key\n' >"$(token_file_path bad-quote)"

  for name in "${names[@]}"; do
    rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG"
    token_file="$(token_file_path "$name")"
    chmod 600 "$token_file"
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
      "$MODEL_PROFILE_TOOL" ask "$name" --model gpt-5 --message 'Hello from test'

    assert_eq "$status" 1 "malformed credential should fail before curl: $name"
    assert_contains "$output" "Error: API key content is malformed for profile '$name'" 'malformed credential should report a non-secret diagnostic'
    assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "malformed credential should not invoke curl: $name"
  done
}

@test "non-2xx response returns status and server error message" {
  create_azure_openai_profile

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_SCENARIO=non_2xx \
    MODEL_PROFILE_CURL_HTTP_CODE=429 \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"error":{"message":"rate limited by fixture"}}' \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

  assert_eq "$status" 1 'non-2xx response should return status 1'
  assert_contains "$output" 'Error: rate limited by fixture' 'non-2xx response should include parsed server error message'
}

@test "remote error diagnostics are sanitized and truncated" {
  create_azure_openai_profile

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_SCENARIO=non_2xx \
    MODEL_PROFILE_CURL_HTTP_CODE=429 \
    MODEL_PROFILE_MAX_DIAGNOSTIC_BYTES=12 \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"error":{"message":"abcdefghijklmnopqrstuv\nsecond line"}}' \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

  assert_eq "$status" 1 'non-2xx response should return status 1'
  assert_contains "$output" 'Error: abcdefghijkl' 'remote diagnostic should be truncated at the configured byte cap'
  assert_not_contains "$output" 'mnop' 'remote diagnostic should not exceed the configured byte cap'
  assert_not_contains "$output" 'second line' 'remote diagnostic should not preserve embedded newlines'
  read_curl_args
  assert_curl_request_temp_files_removed
}

@test "response byte cap accepts the exact edge and rejects oversized success and error bodies" {
  local content response_body response_size output

  content='response edge answer'
  response_body="{\"choices\":[{\"message\":{\"content\":\"$content\"}}]}"
  response_size=$(printf '%s\n' "$response_body" | wc -c)
  create_azure_openai_profile

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_MAX_RESPONSE_BYTES="$response_size" \
    MODEL_PROFILE_CURL_RESPONSE_BODY="$response_body" \
    run_tool ask work-openai --model gpt-4o --message 'Hello from test')

  assert_eq "$output" "$content" 'response at the configured cap should be accepted'
  read_curl_args
  assert_curl_request_temp_files_removed

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_SCENARIO=oversized \
    MODEL_PROFILE_CURL_OVERSIZE_KB=2 \
    MODEL_PROFILE_MAX_RESPONSE_BYTES=128 \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

  assert_eq "$status" 1 'oversized success response should fail'
  assert_contains "$output" 'Error: response exceeded limit of 128 bytes' 'oversized success response should report the response cap'
  read_curl_args
  assert_curl_request_temp_files_removed

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_SCENARIO=non_2xx \
    MODEL_PROFILE_CURL_HTTP_CODE=500 \
    MODEL_PROFILE_MAX_RESPONSE_BYTES=64 \
    MODEL_PROFILE_CURL_RESPONSE_BODY="{\"error\":{\"message\":\"$(repeat_bytes 256 e)\"}}" \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

  assert_eq "$status" 1 'oversized error response should fail'
  assert_contains "$output" 'Error: response exceeded limit of 64 bytes' 'oversized error response should report the response cap'
  read_curl_args
  assert_curl_request_temp_files_removed
}

@test "malformed JSON response returns status and parse stderr" {
  create_azure_openai_profile

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_SCENARIO=malformed_json \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

  assert_eq "$status" 5 'malformed JSON response should return jq parse status'
  assert_contains "$output" 'parse error' 'malformed JSON response should include jq parse stderr'
}

@test "empty content response returns status and explicit stderr" {
  create_azure_openai_profile

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_SCENARIO=empty_content \
    "$MODEL_PROFILE_TOOL" ask work-openai --model gpt-4o --message 'Hello from test'

  assert_eq "$status" 1 'empty content response should return status 1'
  assert_contains "$output" 'Error: response did not contain message content' 'empty content response should include explicit stderr'
}
