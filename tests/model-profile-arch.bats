#!/usr/bin/env bats

load 'helpers/model-profile'

setup() {
  setup_model_profile_test
}

teardown() {
  teardown_model_profile_test
}

source_model_profile_modules_script() {
  cat <<'EOF'
set -euo pipefail
repo_root="$1"
script_dir="$repo_root/tools/bin"
. "$repo_root/lib/picotools/load.sh"
picotools_source_modules "$script_dir" box commands config debug prompt table ui version
for module in provider token profile http; do
  . "$repo_root/tools/lib/picotools/model-profile/${module}.sh"
  . "$repo_root/tools/lib/picotools/model-profile/${module}.sh"
done
EOF
}

@test "model-profile modules can be repeatedly sourced and called directly" {
  local script output

  script="$TMP_HOME/source-modules.bash"
  source_model_profile_modules_script >"$script"
  cat >>"$script" <<'EOF'
provider_type_label azure-openai
provider_type_from_selection 4
provider_openai_base_url azure-openai example-openai ''
provider_endpoint custom '' https://custom.example.com/openai/v1/
validate_custom_endpoint_url_value http://127.0.0.1/openai/v1 >/dev/null 2>&1 || printf 'rejected unsafe endpoint\n'
validate_token_content direct-profile '' >/dev/null 2>&1 || printf 'rejected blank token\n'
EOF

  output=$(bash "$script" "$REPO_ROOT")

  assert_contains "$output" 'Azure OpenAI' 'provider label should be available from the provider module'
  assert_contains "$output" 'custom' 'provider selection should resolve from the provider registry'
  assert_contains "$output" 'https://example-openai.openai.azure.com/openai/v1/' 'provider base URL should resolve directly'
  assert_contains "$output" 'https://custom.example.com/openai/v1/' 'custom display endpoint should resolve directly'
  assert_contains "$output" 'rejected unsafe endpoint' 'destination validation should return a non-zero status without exiting'
  assert_contains "$output" 'rejected blank token' 'token validation should return a non-zero status without exiting'
}

@test "installed layout loads model-profile modules for CRUD and stubbed requests" {
  local install_root output

  install_root="$TMP_HOME/install"
  mkdir -p "$install_root/bin" "$install_root/lib/picotools"
  cp "$REPO_ROOT/tools/bin/model-profile" "$install_root/bin/model-profile"
  cp "$REPO_ROOT"/lib/picotools/*.sh "$install_root/lib/picotools/"
  mkdir -p "$install_root/lib/picotools/model-profile"
  cp "$REPO_ROOT"/tools/lib/picotools/model-profile/*.sh "$install_root/lib/picotools/model-profile/"
  chmod +x "$install_root/bin/model-profile"
  MODEL_PROFILE_TOOL="$install_root/bin/model-profile"

  write_model_profile_curl_fake
  printf 'installed-openai\n1\nexample-openai\ngpt-5\ninstalled-token\n' |
    "$MODEL_PROFILE_TOOL" create >/dev/null 2>&1

  output=$("$MODEL_PROFILE_TOOL" list)
  assert_contains "$output" 'installed-openai' 'installed layout should list created profiles'

  output=$("$MODEL_PROFILE_TOOL" models installed-openai)
  assert_contains "$output" 'gpt-5' 'installed layout should read configured models'

  output=$(PATH="$MODEL_PROFILE_STUB_BIN:$PATH" \
    MODEL_PROFILE_CURL_RESPONSE_BODY='{"choices":[{"message":{"content":"installed answer"}}]}' \
    "$MODEL_PROFILE_TOOL" ask installed-openai --message 'hello')
  assert_eq "$output" 'installed answer' 'installed layout should run stubbed requests'

  printf '1\ny\n' | "$MODEL_PROFILE_TOOL" delete >/dev/null 2>&1
  assert_file_not_exists "$(profile_file_path installed-openai)" 'installed layout should delete profile metadata'
  assert_file_not_exists "$(token_file_path installed-openai)" 'installed layout should delete profile token'
}
