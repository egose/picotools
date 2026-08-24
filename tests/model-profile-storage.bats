#!/usr/bin/env bats

load 'helpers/model-profile'

setup() {
  setup_model_profile_test
}

teardown() {
  teardown_model_profile_test
}

@test "create azure-openai profile stores metadata and token separately" {
  local output profile_file token_file detail_output

  profile_file="$(profile_file_path work-openai)"
  token_file="$(token_file_path work-openai)"

  create_azure_openai_profile

  assert_file_exists "$profile_file" 'create should save provider metadata under config'
  assert_file_exists "$token_file" 'create should save the token under local data'
  assert_secret_eq "$(<"$token_file")" 'secret-openai-token' 'token file should store the provided token'
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

@test "create supports profile names with spaces" {
  local profile_file token_file output detail_output

  profile_file="$(profile_file_path 'work openai')"
  token_file="$(token_file_path 'work openai')"

  create_azure_openai_profile 'work openai'

  assert_file_exists "$profile_file" 'create should save config files for names with spaces'
  assert_file_exists "$token_file" 'create should save token files for names with spaces'

  output=$(run_tool list)
  assert_contains "$output" 'work openai' 'list should include profile names with spaces'

  assert_not_contains "$output" 'Select profile for details' 'list should stay non-interactive for names with spaces'

  detail_output=$(printf '1\n' | run_tool read)
  assert_contains "$detail_output" 'work openai' 'read should show profile names with spaces'
}

@test "update rewrites metadata and can replace the token" {
  local profile_file token_file

  create_azure_openai_profile

  profile_file="$(profile_file_path work-openai)"
  token_file="$(token_file_path work-openai)"

  printf '1\n4\nhttps://custom.example.com/openai/v1\ncustom-model-1, custom-model-2\ny\nreplacement-token\n' | run_tool update >/dev/null 2>&1

  assert_config_value "$profile_file" provider.type 'custom' 'update should allow changing the provider type'
  assert_eq "$(git config -f "$profile_file" --get provider.resourceName 2>/dev/null || true)" '' 'update should remove resourceName when unused by the new provider type'
  assert_config_value "$profile_file" provider.endpointUrl 'https://custom.example.com/openai/v1/' 'update should store the custom endpoint URL'
  assert_config_value "$profile_file" provider.models 'custom-model-1,custom-model-2' 'update should store the normalized model list'
  assert_secret_eq "$(<"$token_file")" 'replacement-token' 'update should replace the stored token when requested'
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

@test "token storage rejects symlinked credential directory across commands" {
  local profile_file original_data_dir outside_dir outside_token output input_file

  create_azure_openai_profile work-openai 'stored-token-value'
  profile_file="$(profile_file_path work-openai)"
  original_data_dir="$TMP_HOME/original-data-dir"
  outside_dir="$TMP_HOME/outside-data-dir"
  outside_token="$outside_dir/work-openai.token"
  mv "$DATA_DIR" "$original_data_dir"
  mkdir -p "$outside_dir"
  printf '%s\n' 'outside-token-value' >"$outside_token"
  chmod 600 "$outside_token"
  ln -s "$outside_dir" "$DATA_DIR"

  run_tool profiles >/dev/null

  run "$MODEL_PROFILE_TOOL" list
  assert_eq "$status" 1 'list should fail closed for a symlinked credential directory'
  assert_not_contains "$output" 'outside-token-value' 'list should not expose outside credential content'

  input_file="$TMP_HOME/read-input"
  printf '1\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" read <"$input_file"
  assert_eq "$status" 1 'read should fail closed for a symlinked credential directory'
  assert_not_contains "$output" 'outside-token-value' 'read should not expose outside credential content'

  write_model_profile_curl_fake
  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask work-openai --message 'hello'
  assert_eq "$status" 1 'ask should fail closed for a symlinked credential directory'
  assert_file_not_exists "$MODEL_PROFILE_CURL_AUTH_LOG" 'ask should not call curl after unsafe storage is rejected'

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" test work-openai
  assert_eq "$status" 1 'test should fail closed for a symlinked credential directory'

  input_file="$TMP_HOME/create-input"
  printf 'new-profile\n3\ngemini-model\nnew-token-value\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" create <"$input_file"
  assert_eq "$status" 1 'create should reject a symlinked credential directory'

  input_file="$TMP_HOME/update-input"
  printf '1\n1\nexample-openai\ngpt-5\ny\nreplacement-token-value\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" update <"$input_file"
  assert_eq "$status" 1 'update should reject a symlinked credential directory when writing credentials'

  input_file="$TMP_HOME/delete-input"
  printf '1\ny\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" delete <"$input_file"
  assert_eq "$status" 1 'delete should reject a symlinked credential directory'
  assert_file_exists "$outside_token" 'delete should not remove an outside credential through a symlinked directory'
  assert_secret_eq "$(<"$outside_token")" 'outside-token-value' 'outside credential content should remain unchanged'
  assert_file_exists "$profile_file" 'failed delete should leave profile metadata in place'
}

@test "token storage rejects symlinked token leaf across commands" {
  local token_file outside_token output input_file

  create_azure_openai_profile work-openai 'stored-token-value'
  token_file="$(token_file_path work-openai)"
  outside_token="$TMP_HOME/outside-token-file"
  rm -f "$token_file"
  printf '%s\n' 'outside-token-value' >"$outside_token"
  chmod 600 "$outside_token"
  ln -s "$outside_token" "$token_file"

  run "$MODEL_PROFILE_TOOL" list
  assert_eq "$status" 1 'list should fail closed for a symlinked credential file'
  assert_not_contains "$output" 'outside-token-value' 'list should not expose outside credential content'

  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask work-openai --message 'hello'
  assert_eq "$status" 1 'ask should fail closed for a symlinked credential file'

  input_file="$TMP_HOME/update-input"
  printf '1\n1\nexample-openai\ngpt-5\ny\nreplacement-token-value\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" update <"$input_file"
  assert_eq "$status" 1 'update should reject a symlinked credential file'
  assert_secret_eq "$(<"$outside_token")" 'outside-token-value' 'update should not modify an outside credential through a symlink'

  input_file="$TMP_HOME/delete-input"
  printf '1\ny\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" delete <"$input_file"
  assert_eq "$status" 1 'delete should reject a symlinked credential file'
  assert_file_exists "$outside_token" 'delete should not remove an outside credential through a symlinked token'
}

@test "token storage rejects hard links and non-regular destinations promptly" {
  local token_file peer_file fifo_file input_file

  create_azure_openai_profile work-openai 'stored-token-value'
  token_file="$(token_file_path work-openai)"
  peer_file="$TMP_HOME/linked-peer-token"
  ln "$token_file" "$peer_file"

  input_file="$TMP_HOME/update-input"
  printf '1\n1\nexample-openai\ngpt-5\ny\nreplacement-token-value\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" update <"$input_file"
  assert_eq "$status" 1 'update should reject a hard-linked credential file'
  assert_secret_eq "$(<"$peer_file")" 'stored-token-value' 'hard-linked peer content should remain unchanged'

  rm -f "$token_file" "$peer_file"
  fifo_file="$token_file"
  mkfifo "$fifo_file"

  run timeout 5 "$MODEL_PROFILE_TOOL" update <"$input_file"
  assert_eq "$status" 1 'update should reject a FIFO credential path without blocking'
}

@test "token storage enforces credential modes and read policy" {
  local token_file output input_file

  umask 022
  create_azure_openai_profile work-openai 'stored-token-value'
  token_file="$(token_file_path work-openai)"

  assert_file_mode "$DATA_DIR" 700 'credential directory should be created with owner-only permissions'
  assert_file_mode "$token_file" 600 'credential file should be created with owner-only permissions'

  chmod 755 "$DATA_DIR"
  run "$MODEL_PROFILE_TOOL" list
  assert_eq "$status" 1 'list should fail closed for a permissive credential directory'

  chmod 700 "$DATA_DIR"
  chmod 644 "$token_file"
  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask work-openai --message 'hello'
  assert_eq "$status" 1 'ask should fail closed for a permissive credential file'

  input_file="$TMP_HOME/update-input"
  printf '1\n1\nexample-openai\ngpt-5\ny\nreplacement-token-value\n' >"$input_file"
  run "$MODEL_PROFILE_TOOL" update <"$input_file"
  assert_eq "$status" 0 'explicit credential write should repair safe permissive storage'
  assert_file_mode "$DATA_DIR" 700 'credential directory should be repaired during explicit write'
  assert_file_mode "$token_file" 600 'credential file should be atomically rewritten with owner-only permissions'

  : >"$token_file"
  chmod 600 "$token_file"
  run "$MODEL_PROFILE_TOOL" list
  assert_eq "$status" 1 'list should fail closed for a blank credential file'
  assert_not_contains "$output" 'Token Stored' 'blank credential failure should not render profile details'
}

@test "token storage rejects malformed credential content" {
  local token_file

  create_azure_openai_profile work-openai 'stored-token-value'
  token_file="$(token_file_path work-openai)"

  printf 'first-line\nsecond-line\n' >"$token_file"
  chmod 600 "$token_file"
  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask work-openai --message 'hello'
  assert_eq "$status" 1 'ask should reject multiline credential content'

  printf 'contains\ttab\n' >"$token_file"
  chmod 600 "$token_file"
  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask work-openai --message 'hello'
  assert_eq "$status" 1 'ask should reject control bytes in credential content'

  printf 'contains\0nul\n' >"$token_file"
  chmod 600 "$token_file"
  run env PATH="$MODEL_PROFILE_STUB_BIN:$PATH" "$MODEL_PROFILE_TOOL" ask work-openai --message 'hello'
  assert_eq "$status" 1 'ask should reject NUL bytes in credential content'
}

@test "token storage preserves previous credential when atomic replacement fails" {
  local token_file fake_bin input_file temp_count

  create_azure_openai_profile work-openai 'stored-token-value'
  token_file="$(token_file_path work-openai)"
  fake_bin="$TMP_HOME/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  chmod +x "$fake_bin/mv"

  input_file="$TMP_HOME/update-input"
  printf '1\n1\nexample-openai\ngpt-5\ny\nreplacement-token-value\n' >"$input_file"
  run env PATH="$fake_bin:$PATH" "$MODEL_PROFILE_TOOL" update <"$input_file"
  assert_eq "$status" 1 'update should fail when atomic replacement fails'
  assert_secret_eq "$(<"$token_file")" 'stored-token-value' 'failed replacement should preserve the previous complete credential'
  temp_count=$(compgen -G "$DATA_DIR/.work-openai.token.tmp.*" | wc -l)
  assert_eq "$temp_count" 0 'failed replacement should remove staged credential temporaries'
}

@test "transaction failures during create publish neither profile nor token" {
  local step name input_file
  local -a steps=(profile-candidate token-candidate token-publish profile-publish)

  for step in "${steps[@]}"; do
    name="create-fails-${step}"
    input_file="$TMP_HOME/${name}-input"
    printf '%s\n1\nexample-openai\ngpt-5\nnew-token\n' "$name" >"$input_file"

    run env MODEL_PROFILE_FAIL_TRANSACTION_STEP="$step" "$MODEL_PROFILE_TOOL" create <"$input_file"
    assert_eq "$status" 1 "create should fail at injected step $step"
    assert_file_not_exists "$(profile_file_path "$name")" "failed create at $step should not publish a profile"
    assert_file_not_exists "$(token_file_path "$name")" "failed create at $step should not publish a token"
    assert_no_transaction_artifacts "$name"
  done
}

@test "transaction failures during update preserve the previous profile and token pair" {
  local step input_file profile_file token_file
  local -a steps=(profile-candidate token-candidate token-publish profile-publish)

  for step in "${steps[@]}"; do
    rm -rf "$CONFIG_DIR" "$DATA_DIR"
    create_azure_openai_profile work-openai 'old-azure-token' 'gpt-5'
    profile_file="$(profile_file_path work-openai)"
    token_file="$(token_file_path work-openai)"
    input_file="$TMP_HOME/update-${step}-input"
    printf '1\n4\nhttps://custom.example.com/openai/v1\ncustom-model\ny\nnew-custom-token\n' >"$input_file"

    run env MODEL_PROFILE_FAIL_TRANSACTION_STEP="$step" "$MODEL_PROFILE_TOOL" update <"$input_file"
    assert_eq "$status" 1 "update should fail at injected step $step"
    assert_config_value "$profile_file" provider.type 'azure-openai' "failed update at $step should preserve provider type"
    assert_config_value "$profile_file" provider.resourceName 'example-openai' "failed update at $step should preserve resource name"
    assert_eq "$(git config -f "$profile_file" --get provider.endpointUrl 2>/dev/null || true)" '' "failed update at $step should not leave a custom endpoint"
    assert_config_value "$profile_file" provider.models 'gpt-5' "failed update at $step should preserve models"
    assert_secret_eq "$(<"$token_file")" 'old-azure-token' "failed update at $step should preserve token"
    assert_no_transaction_artifacts work-openai
  done
}

@test "update cancellation before token capture leaves the previous Azure profile and token" {
  local profile_file token_file input_file

  create_azure_openai_profile work-openai 'old-azure-token' 'gpt-5'
  profile_file="$(profile_file_path work-openai)"
  token_file="$(token_file_path work-openai)"
  input_file="$TMP_HOME/update-eof-input"
  printf '1\n4\nhttps://custom.example.com/openai/v1\ncustom-model\ny\n' >"$input_file"

  run "$MODEL_PROFILE_TOOL" update <"$input_file"
  assert_eq "$status" 1 'update should fail when token input reaches EOF'
  assert_config_value "$profile_file" provider.type 'azure-openai' 'EOF before token capture should preserve provider type'
  assert_eq "$(git config -f "$profile_file" --get provider.endpointUrl 2>/dev/null || true)" '' 'EOF before token capture should not leave a custom endpoint'
  assert_secret_eq "$(<"$token_file")" 'old-azure-token' 'EOF before token capture should preserve the old token'
  assert_no_transaction_artifacts work-openai
}

@test "handled signal during update publication rolls back the profile and token" {
  local profile_file token_file input_file

  create_azure_openai_profile work-openai 'old-azure-token' 'gpt-5'
  profile_file="$(profile_file_path work-openai)"
  token_file="$(token_file_path work-openai)"
  input_file="$TMP_HOME/update-signal-input"
  printf '1\n4\nhttps://custom.example.com/openai/v1\ncustom-model\ny\nnew-custom-token\n' >"$input_file"

  run env MODEL_PROFILE_FAIL_TRANSACTION_STEP=signal:profile-publish "$MODEL_PROFILE_TOOL" update <"$input_file"
  [ "$status" -ne 0 ] || fail 'signalled update should fail'
  assert_config_value "$profile_file" provider.type 'azure-openai' 'signal during profile publish should restore provider type'
  assert_eq "$(git config -f "$profile_file" --get provider.endpointUrl 2>/dev/null || true)" '' 'signal during profile publish should not leave a custom endpoint'
  assert_secret_eq "$(<"$token_file")" 'old-azure-token' 'signal during profile publish should restore token'
  assert_no_transaction_artifacts work-openai
}

@test "delete preflight failure removes neither profile nor token" {
  local profile_file token_file outside_token input_file

  create_azure_openai_profile work-openai 'stored-token-value'
  profile_file="$(profile_file_path work-openai)"
  token_file="$(token_file_path work-openai)"
  outside_token="$TMP_HOME/outside-token-file"
  rm -f "$token_file"
  printf '%s\n' 'outside-token-value' >"$outside_token"
  chmod 600 "$outside_token"
  ln -s "$outside_token" "$token_file"
  input_file="$TMP_HOME/delete-preflight-input"
  printf '1\ny\n' >"$input_file"

  run "$MODEL_PROFILE_TOOL" delete <"$input_file"
  assert_eq "$status" 1 'delete should fail when token preflight rejects the token path'
  assert_file_exists "$profile_file" 'delete preflight failure should keep the profile'
  [ -L "$token_file" ] || fail 'delete preflight failure should keep the token symlink'
  assert_secret_eq "$(<"$outside_token")" 'outside-token-value' 'delete preflight failure should keep outside token content'
  assert_no_transaction_artifacts work-openai
}

@test "successful delete removes profile token and transaction artifacts" {
  local profile_file token_file input_file

  create_azure_openai_profile work-openai 'stored-token-value'
  profile_file="$(profile_file_path work-openai)"
  token_file="$(token_file_path work-openai)"
  input_file="$TMP_HOME/delete-success-input"
  printf '1\ny\n' >"$input_file"

  run "$MODEL_PROFILE_TOOL" delete <"$input_file"
  assert_eq "$status" 0 'delete should succeed'
  assert_file_not_exists "$profile_file" 'successful delete should remove the profile'
  assert_file_not_exists "$token_file" 'successful delete should remove the token'
  assert_no_transaction_artifacts work-openai
}
