#!/usr/bin/env bats

load 'helpers/model-profile'

setup() {
  setup_model_profile_test
}

teardown() {
  teardown_model_profile_test
}

@test "help version and empty list" {
  local output version

  output=$(run_tool --help)
  assert_contains "$output" 'Usage: model-profile [--debug] <command> [--debug] [command options] [--] [operands]' 'help should describe the command entrypoint'
  assert_contains "$output" 'list      List saved model profiles' 'help should describe the list command'
  assert_contains "$output" 'read      Prompt for and show details for one saved model profile' 'help should list the read command'
  assert_contains "$output" 'test      Send a tiny chat request to test a model profile' 'help should list the test command'
  assert_contains "$output" '--debug                   Print request debug steps to stderr' 'help should list the debug flag'
  assert_contains "$output" 'Git is required for profile persistence commands.' 'help should document the Git persistence dependency'
  assert_contains "$output" 'curl and jq are required' 'help should document request-only dependencies'
  assert_contains "$output" 'MODEL_PROFILE_DEBUG=true                  Deprecated fallback for --debug' 'help should describe the deprecated debug env'
  assert_contains "$output" 'MODEL_PROFILE_CURL_CONNECT_TIMEOUT=<s>    Connect timeout, default 10, max 120' 'help should document the connect timeout limit'
  assert_contains "$output" 'MODEL_PROFILE_MAX_RESPONSE_BYTES=<bytes>  Response body cap, default 1048576, max 10485760' 'help should document the response byte limit'
  assert_contains "$output" 'Must be HTTPS URLs with a DNS hostname or public IPv4 literal.' 'help should describe custom endpoint policy'
  assert_contains "$output" 'same-directory atomic publication' 'help should document failure-safe publication behavior'
  assert_contains "$output" 'Grammar:' 'help should document the normalized command grammar'
  assert_contains "$output" 'Exit status:' 'help should document status meanings'

  version=$(run_tool --version)
  assert_eq "$version" "$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" 'version output should match VERSION file'

  output=$(run_tool list)
  assert_contains "$output" 'No model profiles found.' 'list should explain when there are no saved profiles'
}

@test "every command rejects extra operands before prompting storage or transport" {
  local command
  local -a commands=(create update list read profiles models ask test delete)

  write_model_profile_curl_fake

  for command in "${commands[@]}"; do
    rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "$MODEL_PROFILE_CURL_AUTH_LOG"
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" "$command" extra-one extra-two

    assert_eq "$status" 1 "$command should reject extra operands"
    assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "$command rejection should not start transport"
  done

  assert_file_not_exists "$(profile_file_path extra-one)" 'rejected create invocation should not write profile state'
}

@test "every command rejects unknown options before prompting storage or transport" {
  local command
  local -a commands=(create update list read profiles models ask test delete)

  write_model_profile_curl_fake

  for command in "${commands[@]}"; do
    rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "$MODEL_PROFILE_CURL_AUTH_LOG"
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" "$command" --unknown-option

    assert_eq "$status" 1 "$command should reject unknown options"
    assert_contains "$output" 'unknown' "$command should describe unknown options"
    assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "$command rejection should not start transport"
  done
}

@test "every command accepts documented debug placement with valid arity" {
  local output

  write_model_profile_curl_fake
  printf 'debug-profile\n1\nexample-openai\ngpt-5, gpt-4o\ndebug-token\n' |
    run_tool create --debug >/dev/null 2>&1

  run_tool list --debug >/dev/null
  run_tool profiles --debug >/dev/null
  run_tool models debug-profile --debug >/dev/null
  output=$(printf '1\n' | run_tool read --debug)
  assert_contains "$output" 'debug-profile' 'read should accept command-local --debug'

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"debug ask"}}]}' \
    run_tool ask --debug debug-profile --message 'hello')
  assert_eq "$output" 'debug ask' 'ask should accept --debug before operands'

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"OK"}}]}' \
    run_tool test debug-profile --debug)
  assert_contains "$output" 'debug-profile' 'test should accept --debug after operands'
}

@test "commands with value options reject missing values before storage or transport" {
  local scenario

  write_model_profile_curl_fake

  for scenario in \
    'models' \
    'ask work-openai --model' \
    'ask work-openai --message' \
    'ask work-openai --message-file' \
    'ask work-openai --system-message' \
    'ask work-openai --system-message-file' \
    'test work-openai --model'; do
    rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "$MODEL_PROFILE_CURL_AUTH_LOG"
    # shellcheck disable=SC2086 # Test scenarios intentionally expand into argv words.
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" $scenario

    assert_eq "$status" 1 "missing value should fail: $scenario"
    assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "missing value should not start transport: $scenario"
  done
}

@test "ask rejects conflicting and repeated message options before profile key reads or curl" {
  local scenario

  write_model_profile_curl_fake
  write_model_profile_config work-openai azure-openai example-openai gpt-5 secret-token

  for scenario in \
    'ask work-openai --message one --user-message two' \
    'ask work-openai --message one --message two' \
    'ask work-openai --message one --message-file /missing' \
    'ask work-openai --system-message one --system-message two' \
    'ask work-openai --system-message one --system-message-file /missing'; do
    rm -f "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "$MODEL_PROFILE_CURL_AUTH_LOG"
    # shellcheck disable=SC2086 # Test scenarios intentionally expand into argv words.
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" $scenario

    assert_eq "$status" 1 "conflicting or repeated message option should fail: $scenario"
    assert_contains "$output" 'conflicting or duplicate' 'message option conflict should be reported by the parser'
    assert_file_not_exists "$MODEL_PROFILE_CURL_AUTH_LOG" "message conflict should not read API keys: $scenario"
    assert_file_not_exists "$MODEL_PROFILE_CURL_ARGS_NUL_LOG" "message conflict should not start transport: $scenario"
  done
}

@test "interactive profile selection statuses distinguish no profiles invalid selection EOF and cancellation" {
  run "$MODEL_PROFILE_TOOL" read
  assert_eq "$status" 1 'no-profile read should return status 1'
  assert_contains "$output" 'No model profiles found.' 'no-profile read should explain the failure'

  create_azure_openai_profile

  run bash -c 'printf "9\n" | "$1" read' bash "$MODEL_PROFILE_TOOL"
  assert_eq "$status" 1 'invalid profile selection should return status 1'
  assert_contains "$output" 'Error: invalid selection' 'invalid profile selection should be reported'

  run bash -c '"$1" read </dev/null' bash "$MODEL_PROFILE_TOOL"
  assert_eq "$status" 1 'EOF during required profile selection should return status 1'

  run bash -c 'printf "q\n" | "$1" read' bash "$MODEL_PROFILE_TOOL"
  assert_eq "$status" 2 'explicit cancellation should return status 2'
  assert_contains "$output" 'Cancelled.' 'explicit cancellation should be reported'
}

@test "deprecated debug env warning is suppressed by explicit supported debug" {
  local output

  write_model_profile_curl_fake
  create_azure_openai_profile

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_DEBUG=true \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"debug answer"}}]}' \
    run_tool ask work-openai --debug --model gpt-4o --message 'Hello from test' 2>&1)

  assert_not_contains "$output" 'MODEL_PROFILE_DEBUG is deprecated' 'explicit --debug should suppress the deprecated env warning'
  assert_contains "$output" '[model-profile] Preparing chat completion request for profile' 'explicit --debug should keep debug logging enabled'
  assert_contains "$output" 'debug answer' 'ask should still complete successfully'
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

@test "create reprompts for unsupported provider selections" {
  local output

  output=$(printf 'broken\n9\n1\nexample-openai\ngpt-5, gpt-4o\nsecret\n' | run_tool create 2>&1)

  assert_contains "$output" 'Provider types:' 'create should show the numbered provider menu'
  assert_contains "$output" '1. Azure OpenAI' 'create should show readable provider labels'
  assert_contains "$output" '4. Custom' 'create should show the custom provider label'
  assert_contains "$output" 'Please choose 1, 2, 3, or 4.' 'create should reject unsupported provider selections before continuing'
  assert_file_exists "$(profile_file_path broken)" 'create should continue after a valid provider type is entered'
}
