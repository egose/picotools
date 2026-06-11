#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-release-setup"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"
  export GIT_API_BIN="$TMP_DIR/bin/git-api"

  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=''

while [ "$#" -gt 0 ]; do
  case "$1" in
  -f)
    output="$2"
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done

printf '%s\n' "$output" >"$TMP_DIR/ssh-keygen-path.log"
printf '%s\n' 'PRIVATE KEY' >"$output"
printf '%s\n' 'ssh-ed25519 PUBLIC KEY' >"$output.pub"
EOF
  chmod +x "$TMP_DIR/bin/ssh-keygen"

  cat >"$TMP_DIR/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = '-c' ]; then
  exit 0
fi

if [ "${1:-}" = '-' ]; then
  printf '%s' "${PUBLIC_KEY_JSON:-}" >"$TMP_DIR/python-public-key.json"
  cp "$2" "$TMP_DIR/python-secret.txt"
  printf '%s\n' '{"encrypted_value":"sealed-private-key","key_id":"test-key-id"}'
  exit 0
fi

echo "unexpected python3 invocation: $*" >&2
exit 1
EOF
  chmod +x "$TMP_DIR/bin/python3"

  cat >"$TMP_DIR/bin/git-api" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

debug='false'
if [ "${1:-}" = '--debug' ]; then
  debug='true'
  shift
fi

printf '%s|%s\n' "$debug" "$*" >>"$TMP_DIR/git-api.log"

case "${1:-}" in
repos/list-deploy-keys)
  if [ -n "${EXISTING_DEPLOY_KEYS_JSON:-}" ]; then
    printf '%s\n' "$EXISTING_DEPLOY_KEYS_JSON"
  else
    printf '%s\n' '[]'
  fi
  ;;
repos/delete-deploy-key)
  printf '%s\n' "$4" >>"$TMP_DIR/deleted-deploy-keys.log"
  printf '%s\n' '{}'
  ;;
actions/get-repo-public-key)
  printf '%s\n' '{"key_id":"test-key-id","key":"ZmFrZS1yZXBvLXB1YmxpYy1rZXk="}'
  ;;
actions/create-or-update-repo-secret)
  cp "$6" "$TMP_DIR/repo-secret-body.json"
  printf '%s\n' '{}'
  ;;
repos/create-deploy-key)
  cp "$5" "$TMP_DIR/deploy-key-body.json"
  printf '%s\n' '{}'
  ;;
actions/set-github-actions-default-workflow-permissions-repository)
  cp "$5" "$TMP_DIR/workflow-permissions-body.json"
  printf '%s\n' '{}'
  ;;
*)
  echo "unexpected git-api invocation: $*" >&2
  exit 1
  ;;
esac
EOF
  chmod +x "$TMP_DIR/bin/git-api"
}

teardown() {
  rm -rf "$TMP_DIR"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
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

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

@test "help and version describe git-release-setup" {
  local version

  version="$(<"$REPO_ROOT/VERSION")"

  run "$TOOL" --help
  [ "$status" -eq 0 ] || fail 'help should succeed'
  assert_contains "$output" 'Usage: git-release-setup' 'help should document the tool entrypoint'
  assert_contains "$output" '--key-name NAME' 'help should document the key name override'
  assert_contains "$output" 'Fine-grained PAT:' 'help should document token requirements'
  assert_contains "$output" 'Under Repository permissions' 'help should distinguish repository permissions from account permissions'
  assert_contains "$output" 'Secrets: Read and write' 'help should document secrets permission requirements'
  assert_contains "$output" 'Administration: Write' 'help should document administration permission requirements'
  assert_contains "$output" 'Account permissions list is not used' 'help should explain that account permissions are not needed'

  run "$TOOL" --version
  [ "$status" -eq 0 ] || fail 'version should succeed'
  assert_eq "$output" "$version" 'version should match the repository VERSION'
}

@test "fails when the repository argument is missing" {
  run "$TOOL"

  [ "$status" -ne 0 ] || fail 'tool should fail without a repository argument'
  assert_contains "$output" 'Error: missing required repository argument <owner/repo>' 'tool should explain the missing repository'
}

@test "configures release-tag dispatch access for owner slash repo" {
  local generated_key_path

  run "$TOOL" octo/demo

  [ "$status" -eq 0 ] || fail 'tool should succeed for owner/repo input'
  assert_contains "$output" 'Configured release-tag dispatch access for octo/demo.' 'tool should report the configured repository'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|actions/get-repo-public-key octo demo' 'tool should fetch the repository Actions public key'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|actions/create-or-update-repo-secret octo demo SSH_KEY --body-file' 'tool should store the encrypted private key as a secret'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|repos/create-deploy-key octo demo --body-file' 'tool should create the deploy key through git-api'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|actions/set-github-actions-default-workflow-permissions-repository octo demo --body-file' 'tool should update workflow permissions through git-api'
  assert_contains "$(<"$TMP_DIR/python-public-key.json")" '"key_id":"test-key-id"' 'tool should pass the repository public key into the encryption helper'
  assert_eq "$(<"$TMP_DIR/python-secret.txt")" 'PRIVATE KEY' 'tool should encrypt the generated private key'
  assert_contains "$(<"$TMP_DIR/repo-secret-body.json")" '"encrypted_value":"sealed-private-key"' 'tool should upload the encrypted secret payload'
  assert_contains "$(<"$TMP_DIR/repo-secret-body.json")" '"key_id":"test-key-id"' 'tool should upload the repository key id with the secret'
  assert_contains "$(<"$TMP_DIR/deploy-key-body.json")" '"title":"SSH_KEY"' 'tool should name the deploy key after the secret name'
  assert_contains "$(<"$TMP_DIR/deploy-key-body.json")" '"key":"ssh-ed25519 PUBLIC KEY"' 'tool should upload the generated public key'
  assert_contains "$(<"$TMP_DIR/deploy-key-body.json")" '"read_only":false' 'tool should request write access for the deploy key'
  assert_contains "$(<"$TMP_DIR/workflow-permissions-body.json")" '"default_workflow_permissions":"write"' 'tool should grant workflow write permissions'
  assert_contains "$(<"$TMP_DIR/workflow-permissions-body.json")" '"can_approve_pull_request_reviews":true' 'tool should allow workflow PR review approvals'

  generated_key_path="$(<"$TMP_DIR/ssh-keygen-path.log")"
  [ ! -e "$generated_key_path" ] || fail 'tool should clean up the generated private key file'
  [ ! -e "$generated_key_path.pub" ] || fail 'tool should clean up the generated public key file'
}

@test "replaces existing deploy keys with the same title on rerun" {
  export EXISTING_DEPLOY_KEYS_JSON='[{"id":11,"title":"SSH_KEY"},{"id":29,"title":"SSH_KEY"},{"id":40,"title":"OTHER_KEY"}]'

  run "$TOOL" octo/demo

  [ "$status" -eq 0 ] || fail 'tool should succeed when existing deploy keys share the same title'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|repos/list-deploy-keys octo demo --per-page 100' 'tool should inspect existing deploy keys before creating a new one'
  assert_eq "$(<"$TMP_DIR/deleted-deploy-keys.log")" $'11
29' 'tool should delete only deploy keys whose title matches the requested key name'
}

@test "accepts owner and repo as separate arguments" {
  run "$TOOL" octo demo

  [ "$status" -eq 0 ] || fail 'tool should accept owner and repo as separate arguments'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|actions/get-repo-public-key octo demo' 'tool should pass owner and repo separately to git-api'
}

@test "key name override updates the secret and deploy key title" {
  run "$TOOL" --key-name RELEASE_SSH octo/demo

  [ "$status" -eq 0 ] || fail 'tool should support overriding the key name'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'false|actions/create-or-update-repo-secret octo demo RELEASE_SSH --body-file' 'tool should store the secret under the overridden name'
  assert_contains "$(<"$TMP_DIR/deploy-key-body.json")" '"title":"RELEASE_SSH"' 'tool should use the overridden key name as the deploy key title'
}

@test "fails fast when key name contains invalid characters" {
  run "$TOOL" --key-name 'bad key' octo/demo

  [ "$status" -ne 0 ] || fail 'tool should fail when the key name contains invalid characters'
  assert_contains "$output" 'Error: --key-name must start with a letter or underscore and contain only letters, numbers, and underscores' 'tool should explain valid key name characters'
  [ ! -f "$TMP_DIR/git-api.log" ] || fail 'tool should stop before making API calls when the key name is invalid'
}

@test "fails fast when key name uses the reserved GITHUB_ prefix" {
  run "$TOOL" --key-name GITHUB_TOKEN octo/demo

  [ "$status" -ne 0 ] || fail 'tool should fail when the key name uses the reserved prefix'
  assert_contains "$output" 'Error: --key-name must not start with the reserved GITHUB_ prefix' 'tool should explain the reserved prefix rule'
  [ ! -f "$TMP_DIR/git-api.log" ] || fail 'tool should stop before making API calls when the key name is reserved'
}

@test "fails fast when PyNaCl is unavailable" {
  cat >"$TMP_DIR/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = '-c' ]; then
  exit 1
fi

echo "unexpected python3 invocation: $*" >&2
exit 1
EOF
  chmod +x "$TMP_DIR/bin/python3"

  run "$TOOL" octo/demo

  [ "$status" -ne 0 ] || fail 'tool should fail when PyNaCl is unavailable'
  assert_contains "$output" 'Error: python3 with PyNaCl is required to encrypt GitHub Actions secrets' 'tool should explain the PyNaCl requirement'
  [ ! -f "$TMP_DIR/git-api.log" ] || fail 'tool should stop before making GitHub API calls when PyNaCl is unavailable'
}

@test "debug mode logs progress and forwards debug to git-api" {
  run "$TOOL" --debug octo/demo

  [ "$status" -eq 0 ] || fail 'tool should succeed in debug mode'
  assert_contains "$output" '[git-release-setup] Generating SSH keypair' 'debug mode should log key generation progress'
  assert_contains "$(<"$TMP_DIR/git-api.log")" 'true|actions/get-repo-public-key octo demo' 'debug mode should be forwarded to git-api'
}
