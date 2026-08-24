#!/usr/bin/env bats

load 'helpers/model-profile'

setup() {
  setup_model_profile_test
  write_model_profile_curl_fake
}

teardown() {
  teardown_model_profile_test
}

write_profile_config() {
  local name="$1"
  local provider_type="$2"
  local location="$3"
  local models="$4"
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
  printf '%s\n' "token-$name" >"$(token_file_path "$name")"
  chmod 600 "$(token_file_path "$name")"
}

@test "profile names reject traversal aliases controls and delimiters" {
  local invalid_name

  for invalid_name in '.' '..' '.hidden' '../outside' 'nested/name' 'bad\name' 'bad|name' $'bad\tname' $'bad\nname'; do
    run "$MODEL_PROFILE_TOOL" models "$invalid_name"
    assert_eq "$status" 1 "models should reject invalid profile name: $invalid_name"
  done

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask '../outside' --message 'hello'
  assert_eq "$status" 1 'ask should reject traversal profile names before requests'
  assert_file_not_exists "$MODEL_PROFILE_CURL_AUTH_LOG" 'ask should not call curl for an invalid profile name'

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" test $'bad\tname'
  assert_eq "$status" 1 'test should reject tabbed profile names before requests'
  assert_file_not_exists "$MODEL_PROFILE_CURL_AUTH_LOG" 'test should not call curl for an invalid profile name'
}

@test "accepted names with internal spaces are discoverable and map to one config token pair" {
  local output

  create_azure_openai_profile 'work openai profile' 'space-name-token' 'gpt-5, gpt-4o'

  assert_file_exists "$(profile_file_path 'work openai profile')" 'config should use the exact accepted profile name'
  assert_file_exists "$(token_file_path 'work openai profile')" 'token should use the exact accepted profile name'

  output=$(run_tool profiles)
  assert_contains "$output" 'work openai profile' 'profiles should discover accepted names with internal spaces'

  output=$(run_tool models 'work openai profile')
  assert_contains "$output" 'gpt-5' 'models should read from the exact accepted profile config'
  assert_contains "$output" 'gpt-4o' 'models should expose every configured model'
}

@test "symlinked and non-regular profile files are not listed or used" {
  local outside_file output

  mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  outside_file="$TMP_HOME/outside-profile.conf"
  git config -f "$outside_file" provider.type azure-openai
  git config -f "$outside_file" provider.resourceName outside-openai
  git config -f "$outside_file" provider.models gpt-5
  ln -s "$outside_file" "$(profile_file_path linked)"
  mkfifo "$(profile_file_path fifo)"

  output=$(run_tool profiles)
  assert_not_contains "$output" 'linked' 'profiles should not list symlinked profile files'
  assert_not_contains "$output" 'fifo' 'profiles should not list non-regular profile files'

  run "$MODEL_PROFILE_TOOL" models linked
  assert_eq "$status" 1 'direct models should reject a symlinked profile file'

  run "$MODEL_PROFILE_TOOL" models fifo
  assert_eq "$status" 1 'direct models should reject a non-regular profile file'

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask linked --message 'hello'
  assert_eq "$status" 1 'ask should reject symlinked profile files before requests'
  assert_file_not_exists "$MODEL_PROFILE_CURL_AUTH_LOG" 'ask should not call curl for a symlinked profile file'
}

@test "symlinked profile directory is rejected across lookup paths" {
  local original_config_dir outside_config_dir input_file

  write_profile_config work-openai azure-openai example-openai gpt-5
  original_config_dir="$TMP_HOME/original-config-dir"
  outside_config_dir="$TMP_HOME/outside-config-dir"
  mv "$CONFIG_DIR" "$original_config_dir"
  mkdir -p "$outside_config_dir"
  git config -f "$outside_config_dir/work-openai.conf" provider.type azure-openai
  git config -f "$outside_config_dir/work-openai.conf" provider.resourceName outside-openai
  git config -f "$outside_config_dir/work-openai.conf" provider.models gpt-5
  ln -s "$outside_config_dir" "$CONFIG_DIR"

  run "$MODEL_PROFILE_TOOL" profiles
  assert_eq "$status" 1 'profiles should reject a symlinked profile directory'
  assert_not_contains "$output" 'work-openai' 'profiles should not list outside profile files'

  run "$MODEL_PROFILE_TOOL" list
  assert_eq "$status" 1 'list should reject a symlinked profile directory'
  assert_not_contains "$output" 'outside-openai' 'list should not read outside profile files'

  run "$MODEL_PROFILE_TOOL" models work-openai
  assert_eq "$status" 1 'direct models should reject a symlinked profile directory'

  input_file="$TMP_HOME/read-input"
  printf '1\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" read <"$input_file"
  assert_eq "$status" 1 'interactive read should reject a symlinked profile directory'

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask work-openai --message 'hello'
  assert_eq "$status" 1 'ask should reject a symlinked profile directory before requests'
  assert_file_not_exists "$MODEL_PROFILE_CURL_AUTH_LOG" 'ask should not call curl through a symlinked profile directory'
}

@test "schema validation fails before token reads or network requests" {
  local file original_data_dir outside_data_dir

  write_profile_config broken unknown-provider unused gpt-5
  original_data_dir="$TMP_HOME/original-data-dir"
  outside_data_dir="$TMP_HOME/outside-data-dir"
  mv "$DATA_DIR" "$original_data_dir"
  mkdir -p "$outside_data_dir"
  ln -s "$outside_data_dir" "$DATA_DIR"

  run "$MODEL_PROFILE_TOOL" list
  assert_eq "$status" 1 'list should fail on unknown providers before credential status checks'
  assert_contains "$output" "invalid profile 'broken'" 'list should report the schema failure'
  assert_not_contains "$output" 'unsafe API key storage' 'list should not inspect credentials before schema validation'

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask broken --message 'hello'
  assert_eq "$status" 1 'ask should fail on unknown providers before requests'
  assert_file_not_exists "$MODEL_PROFILE_CURL_AUTH_LOG" 'ask should not call curl for invalid schema'

  rm -f "$DATA_DIR"
  mv "$original_data_dir" "$DATA_DIR"

  write_profile_config missing-models azure-openai example-openai gpt-5
  git config -f "$(profile_file_path missing-models)" --unset-all provider.models
  run "$MODEL_PROFILE_TOOL" models missing-models
  assert_eq "$status" 1 'models should reject profiles with no model list'

  write_profile_config duplicate-key azure-openai example-openai gpt-5
  git config -f "$(profile_file_path duplicate-key)" --add provider.models gpt-4o
  run "$MODEL_PROFILE_TOOL" models duplicate-key
  assert_eq "$status" 1 'models should reject duplicate managed keys'

  write_profile_config incompatible custom https://custom.example.com/openai/v1 custom-model
  git config -f "$(profile_file_path incompatible)" provider.resourceName stray-resource
  run "$MODEL_PROFILE_TOOL" models incompatible
  assert_eq "$status" 1 'models should reject provider-inconsistent fields'

  file="$(profile_file_path malformed)"
  printf '%s\n' '[provider' >"$file"
  run "$MODEL_PROFILE_TOOL" models malformed
  assert_eq "$status" 1 'models should reject malformed config files'
}

@test "model names are normalized and reject separators controls and empty values" {
  local input_file

  input_file="$TMP_HOME/bad-models-input"
  printf 'bad-models\n1\nexample-openai\ngpt-5, bad/model\nsecret\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" create <"$input_file"
  assert_eq "$status" 1 'create should reject model names with path separators'
  assert_file_not_exists "$(profile_file_path bad-models)" 'invalid model names should not be saved'

  input_file="$TMP_HOME/tab-models-input"
  printf 'tab-models\n1\nexample-openai\ngpt-5, bad\tmodel\nsecret\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" create <"$input_file"
  assert_eq "$status" 1 'create should reject model names with tabs'
  assert_file_not_exists "$(profile_file_path tab-models)" 'tabbed model names should not be saved'

  input_file="$TMP_HOME/empty-models-input"
  printf 'empty-models\n1\nexample-openai\n   \nsecret\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" create <"$input_file"
  assert_eq "$status" 1 'create should reject model lists that normalize to empty'
  assert_file_not_exists "$(profile_file_path empty-models)" 'empty normalized model lists should not be saved'
}

@test "valid legacy profiles for all providers remain readable" {
  local output

  write_profile_config 'legacy openai' azure-openai example-openai 'gpt-5, gpt-4o'
  write_profile_config 'legacy cognitive' azure-cognitive-services example-vision 'vision, document-intelligence'
  write_profile_config 'legacy gemini' gemini '' 'gemini-2.5-pro, gemini-2.5-flash'
  write_profile_config 'legacy custom' custom 'https://custom.example.com/openai/v1' 'custom-model, custom-model-2'

  output=$(run_tool list)
  assert_contains "$output" 'legacy openai' 'list should read existing Azure OpenAI profiles'
  assert_contains "$output" 'legacy cognitive' 'list should read existing Azure Cognitive Services profiles'
  assert_contains "$output" 'legacy gemini' 'list should read existing Gemini profiles'
  assert_contains "$output" 'legacy custom' 'list should read existing custom profiles'

  output=$(run_tool models 'legacy custom')
  assert_contains "$output" 'custom-model' 'models should read normalized existing custom model names'
  assert_contains "$output" 'custom-model-2' 'models should read normalized existing custom model names with spaces after commas'
}

@test "azure resource names reject URL delimiters controls invalid labels and length before credentials" {
  local invalid_resource name original_data_dir outside_data_dir
  local index=0
  local -a invalid_resources=(
    'bad@host'
    'bad/path'
    'bad?query'
    'bad#fragment'
    'bad:443'
    'bad name'
    $'bad	name'
    'bad_name'
    'bad.name'
    '-bad'
    'bad-'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  )

  for invalid_resource in "${invalid_resources[@]}"; do
    name="azure-bad-$index"
    write_profile_config "$name" azure-openai "$invalid_resource" gpt-5
    index=$((index + 1))
  done

  original_data_dir="$TMP_HOME/original-data-dir"
  outside_data_dir="$TMP_HOME/outside-data-dir"
  mv "$DATA_DIR" "$original_data_dir"
  mkdir -p "$outside_data_dir"
  ln -s "$outside_data_dir" "$DATA_DIR"

  index=0
  for invalid_resource in "${invalid_resources[@]}"; do
    name="azure-bad-$index"
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask "$name" --message 'hello'
    assert_eq "$status" 1 "ask should reject invalid Azure resource name: $invalid_resource"
    assert_contains "$output" "invalid profile '$name'" 'ask should report a profile validation error'
    assert_not_contains "$output" 'unsafe API key storage' 'ask should not inspect token storage for invalid Azure destinations'
    assert_no_key_read_or_transport 'invalid Azure resource names should fail before transport'
    index=$((index + 1))
  done
}

@test "custom endpoint URLs reject unsafe URL forms and address literals before credentials" {
  local endpoint name index original_data_dir outside_data_dir
  local -a endpoints=(
    'custom.example.com/openai/v1'
    'ftp://custom.example.com/openai/v1'
    'http://custom.example.com/openai/v1'
    'https://user@custom.example.com/openai/v1'
    'https://custom.example.com/openai v1'
    'https://custom.example.com/openai/v1?api-version=1'
    'https://custom.example.com/openai/v1#fragment'
    'https:///openai/v1'
    'https://custom.example.com:bad/openai/v1'
    'https://custom.example.com:99999/openai/v1'
    '--config'
    'https://localhost/openai/v1'
    'https://127.0.0.1/openai/v1'
    'https://10.0.0.1/openai/v1'
    'https://172.16.0.1/openai/v1'
    'https://192.168.1.1/openai/v1'
    'https://169.254.1.1/openai/v1'
  )

  index=0
  for endpoint in "${endpoints[@]}"; do
    name="custom-bad-$index"
    write_profile_config "$name" custom "$endpoint" custom-model
    index=$((index + 1))
  done

  original_data_dir="$TMP_HOME/original-data-dir"
  outside_data_dir="$TMP_HOME/outside-data-dir"
  mv "$DATA_DIR" "$original_data_dir"
  mkdir -p "$outside_data_dir"
  ln -s "$outside_data_dir" "$DATA_DIR"

  index=0
  for endpoint in "${endpoints[@]}"; do
    name="custom-bad-$index"
    run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask "$name" --message 'hello'
    assert_eq "$status" 1 "ask should reject invalid custom endpoint: $endpoint"
    assert_contains "$output" "invalid profile '$name'" 'ask should report custom endpoint validation errors'
    assert_not_contains "$output" 'unsafe API key storage' 'ask should not inspect token storage for invalid custom destinations'
    assert_no_key_read_or_transport 'invalid custom endpoints should fail before transport'
    index=$((index + 1))
  done
}

@test "externally modified custom endpoint is revalidated before request use" {
  local original_data_dir outside_data_dir

  printf 'custom-main\n4\nhttps://custom.example.com/openai/v1\ncustom-model\ncustom-secret\n' |
    run_tool create >/dev/null 2>&1
  git config -f "$(profile_file_path custom-main)" provider.endpointUrl 'http://127.0.0.1/openai/v1'
  original_data_dir="$TMP_HOME/original-data-dir"
  outside_data_dir="$TMP_HOME/outside-data-dir"
  mv "$DATA_DIR" "$original_data_dir"
  mkdir -p "$outside_data_dir"
  ln -s "$outside_data_dir" "$DATA_DIR"

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask custom-main --message 'hello'
  assert_eq "$status" 1 'ask should reject custom endpoint modifications before requests'
  assert_contains "$output" "invalid profile 'custom-main'" 'ask should identify the externally modified profile'
  assert_not_contains "$output" 'unsafe API key storage' 'ask should not inspect token storage for externally modified destinations'
  assert_no_key_read_or_transport 'externally modified custom endpoint should fail before transport'
}
