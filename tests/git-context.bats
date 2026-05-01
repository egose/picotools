#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/git-context"

setup() {
  TMP_HOME="$(mktemp -d)" || return 1
  export TMP_HOME
  export HOME="$TMP_HOME"
  export XDG_CONFIG_HOME="$TMP_HOME/.config"
  export CONTEXT_DIR="$XDG_CONFIG_HOME/git-contexts"
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

assert_git_config_file_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local message="$4"

  assert_eq "$(git config -f "$file" --get "$key")" "$expected" "$message"
}

assert_git_local_value() {
  local repo="$1"
  local key="$2"
  local expected="$3"
  local message="$4"

  assert_eq "$(git -C "$repo" config --local --get "$key")" "$expected" "$message"
}

assert_git_local_all_values() {
  local repo="$1"
  local key="$2"
  local expected="$3"
  local message="$4"

  assert_eq "$(git -C "$repo" config --local --get-all "$key")" "$expected" "$message"
}

assert_git_local_unset() {
  local repo="$1"
  local key="$2"
  local message="$3"

  if git -C "$repo" config --local --get "$key" >/dev/null 2>&1; then
    fail "$message"
  fi
}

assert_git_config_file_unset() {
  local file="$1"
  local key="$2"
  local message="$3"

  if git config -f "$file" --get "$key" >/dev/null 2>&1; then
    fail "$message"
  fi
}

init_repo() {
  local repo="$1"

  mkdir -p "$repo"
  git init -q "$repo"
}

run_tool() {
  "$TOOL" "$@"
}

run_set_in_repo() {
  local repo="$1"

  (
    cd "$repo" || return 1
    printf '1\n' | run_tool set >/dev/null 2>&1
  )
}

context_file_path() {
  printf '%s/%s.gitconfig\n' "$CONTEXT_DIR" "$1"
}

write_git_config_values() {
  local file="$1"
  shift

  mkdir -p "$(dirname "$file")"

  while [ "$#" -gt 0 ]; do
    git config -f "$file" "$1" "$2"
    shift 2
  done
}

write_local_git_config_values() {
  local repo="$1"
  shift

  while [ "$#" -gt 0 ]; do
    git -C "$repo" config --local "$1" "$2"
    shift 2
  done
}

append_local_git_config_values() {
  local repo="$1"
  shift

  while [ "$#" -gt 0 ]; do
    git -C "$repo" config --local --add "$1" "$2"
    shift 2
  done
}

assert_command_fails() {
  local expected_message="$1"
  shift

  local output

  if output=$("$@" 2>&1); then
    fail "command should fail with a non-zero exit status"
  fi

  assert_contains "$output" "$expected_message" 'command should explain why it failed'
}

assert_create_fails() {
  local input="$1"
  local expected_message="$2"
  local context_name="$3"
  local unexpected_prompt="${4:-}"
  local output context_file

  context_file="$(context_file_path "$context_name")"

  if output=$(printf '%b' "$input" | run_tool create 2>&1); then
    fail "create should fail with a non-zero exit status"
  fi

  assert_contains "$output" "$expected_message" 'create should explain why the requested flow is unavailable'

  if [ -n "$unexpected_prompt" ]; then
    assert_not_contains "$output" "$unexpected_prompt" 'create should fail before prompting for later values'
  fi

  if [ -e "$context_file" ]; then
    fail 'create should not save a context file when the requested flow is unavailable'
  fi
}

@test "help version and empty list" {
  local output version

  output=$(run_tool --help)
  assert_contains "$output" 'Usage: git-context <command>' 'help should describe the command entrypoint'
  assert_contains "$output" 'read      Show detailed information for a saved git context' 'help should list the read command'

  version=$(run_tool --version)
  assert_eq "$version" "$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" 'version output should match VERSION file'

  output=$(run_tool list)
  assert_contains "$output" 'No git contexts found.' 'list should explain when there are no saved contexts'
}

@test "create list and delete context" {
  local output context_file

  context_file="$(context_file_path personal)"

  printf 'personal\nJane Dev\njane@example.com\nno\nno\n' |
    run_tool create >/dev/null 2>&1

  assert_file_exists "$context_file" 'create should save the named context'

  output=$(run_tool list)
  assert_contains "$output" '| # ' 'list should print an index column'
  assert_contains "$output" '| Name' 'list should print a table header'
  assert_contains "$output" 'personal' 'list should include the context name'
  assert_contains "$output" 'Jane Dev' 'list should include the user name'
  assert_contains "$output" 'jane@example.com' 'list should include the email'
  assert_contains "$output" ' no ' 'list should show disabled optional features'
  assert_not_contains "$output" 'Autocrlf' 'list should not include the detailed optional settings columns'

  assert_not_contains "$output" 'Actions:' 'list should not prompt for follow-up actions'
  assert_not_contains "$output" 'Select context for details' 'list should not prompt for detail selection'

  printf '1\ny\n' | run_tool delete >/dev/null 2>&1

  assert_file_not_exists "$context_file" 'delete should remove the selected context file'
}

@test "delete context can remove SSH and GPG material" {
  local context_file ssh_key_path gpg_log stub_bin output

  context_file="$(context_file_path work)"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"
  gpg_log="$TMP_HOME/gpg.log"
  stub_bin="$TMP_HOME/bin"

  mkdir -p "$CONTEXT_DIR" "$stub_bin" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path" "$ssh_key_path.pub"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    user.signingkey 'ABC123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg \
    core.autocrlf false \
    core.fileMode true \
    core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes"

  cat >"$stub_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" > "$GPG_LOG"
EOF
  chmod +x "$stub_bin/gpg"

  output=$(printf '1\ny\ny\ny\n' |
    PATH="$stub_bin:$PATH" \
      GPG_LOG="$gpg_log" \
      "$TOOL" delete 2>&1)

  assert_contains "$output" 'Deleted context.' 'delete should confirm the context was deleted'
  assert_file_not_exists "$context_file" 'delete should remove the selected context file'
  assert_file_not_exists "$ssh_key_path" 'delete should remove the SSH private key when requested'
  assert_file_not_exists "$ssh_key_path.pub" 'delete should remove the SSH public key when requested'
  assert_contains "$(<"$gpg_log")" '--batch --yes --delete-secret-and-public-key ABC123' 'delete should remove the GPG key when requested'
}

@test "create context with existing SSH and GPG values" {
  local context_file ssh_key_path output

  ssh_key_path="$TMP_HOME/id_ed25519"
  context_file="$(context_file_path work)"

  touch "$ssh_key_path"

  printf 'work\nJane Dev\njane@example.com\nyes\n%s\nyes\nABC123\n' "$ssh_key_path" |
    run_tool create >/dev/null 2>&1

  assert_file_exists "$context_file" 'create should save the named context'
  assert_git_config_file_value "$context_file" user.name 'Jane Dev' 'create should save the git user name'
  assert_git_config_file_value "$context_file" user.email 'jane@example.com' 'create should save the git email'
  assert_git_config_file_value "$context_file" core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'create should save the managed SSH command'
  assert_git_config_file_value "$context_file" user.signingkey 'ABC123' 'create should save the signing key'
  assert_git_config_file_value "$context_file" commit.gpgsign true 'create should enable commit signing'
  assert_git_config_file_value "$context_file" tag.gpgsign true 'create should enable tag signing'
  assert_git_config_file_value "$context_file" gpg.program gpg 'create should default gpg.program to gpg'
  assert_git_config_file_value "$context_file" core.autocrlf false 'create should default core.autocrlf to false'
  assert_git_config_file_value "$context_file" core.fileMode true 'create should default core.fileMode to true'
  assert_git_config_file_value "$context_file" pull.rebase false 'create should default pull.rebase to false'
  assert_git_config_file_value "$context_file" rebase.autoStash false 'create should default rebase.autoStash to false'
  assert_git_config_file_value "$context_file" push.default simple 'create should default push.default to simple'
  assert_git_config_file_value "$context_file" push.autoSetupRemote false 'create should default push.autoSetupRemote to false'
  assert_git_config_file_value "$context_file" core.editor vim 'create should default core.editor to vim'

  output=$(run_tool list)
  assert_contains "$output" ' yes ' 'list should include enabled optional feature states'
  assert_not_contains "$output" "$ssh_key_path" 'list should not include the detailed SSH key path'
  assert_not_contains "$output" 'ABC123' 'list should not include the detailed signing key'
}

@test "read context displays detailed values" {
  local context_file ssh_key_path output

  context_file="$(context_file_path work)"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"

  mkdir -p "$CONTEXT_DIR" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"
  printf '%s\n' 'ssh-ed25519 AAAATEST jane@example.com' >"$ssh_key_path.pub"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    user.signingkey 'ABC123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg2 \
    core.autocrlf input \
    core.fileMode false \
    pull.rebase true \
    rebase.autoStash true \
    push.default current \
    push.autoSetupRemote true \
    core.editor nano \
    core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes"

  output=$(printf '1\nno\n' | run_tool read 2>&1)

  assert_contains "$output" '| Field ' 'read should render a table header'
  assert_contains "$output" '| Name ' 'read should include the context name field'
  assert_contains "$output" '| User ' 'read should include the user field'
  assert_contains "$output" '| Email ' 'read should include the email field'
  assert_contains "$output" '| SSH ' 'read should include SSH enabled field'
  assert_contains "$output" '| SSH Key ' 'read should include the SSH key field'
  assert_contains "$output" "$ssh_key_path" 'read should include the SSH key path'
  assert_contains "$output" '| SSH Command ' 'read should include the SSH command field'
  assert_contains "$output" "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'read should include the SSH command'
  assert_contains "$output" '| GPG ' 'read should include the GPG field'
  assert_contains "$output" '| Signing Key ' 'read should include the signing key field'
  assert_contains "$output" 'ABC123' 'read should include the signing key value'
  assert_contains "$output" '| Commit GPG Sign ' 'read should include commit signing field'
  assert_contains "$output" '| Tag GPG Sign ' 'read should include tag signing field'
  assert_contains "$output" '| GPG Program ' 'read should include gpg.program field'
  assert_contains "$output" 'gpg2' 'read should include gpg.program value'
  assert_contains "$output" '| Autocrlf ' 'read should include core.autocrlf field'
  assert_contains "$output" 'input' 'read should include core.autocrlf value'
  assert_contains "$output" '| FileMode ' 'read should include core.fileMode field'
  assert_contains "$output" 'false' 'read should include false values'
  assert_contains "$output" '| Pull Rebase ' 'read should include pull.rebase field'
  assert_contains "$output" '| Rebase AutoStash ' 'read should include rebase.autoStash field'
  assert_contains "$output" '| Push Default ' 'read should include push.default field'
  assert_contains "$output" 'current' 'read should include push.default value'
  assert_contains "$output" '| Push AutoSetupRemote ' 'read should include push.autoSetupRemote field'
  assert_contains "$output" '| Core Editor ' 'read should include core.editor field'
  assert_contains "$output" 'nano' 'read should include core.editor value'
  assert_contains "$output" 'Display public SSH key? [y/N]:' 'read should prompt before displaying the public SSH key'
  assert_not_contains "$output" 'Public SSH Key (' 'read should not print the public SSH key when declined'
}

@test "read context can display public SSH key" {
  local context_file ssh_key_path output public_key

  context_file="$(context_file_path work)"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"
  public_key='ssh-ed25519 AAAATEST jane@example.com'

  mkdir -p "$CONTEXT_DIR" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"
  printf '%s\n' "$public_key" >"$ssh_key_path.pub"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" \
    core.autocrlf false \
    core.fileMode true

  output=$(printf '1\nyes\n' | run_tool read 2>&1)

  assert_contains "$output" 'Display public SSH key? [y/N]:' 'read should prompt before displaying the public SSH key'
  assert_contains "$output" "Public SSH Key ($ssh_key_path.pub):" 'read should print the public key header when requested'
  assert_contains "$output" "$public_key" 'read should print the public key contents when requested'
}

@test "create rejects missing existing SSH key path" {
  assert_create_fails \
    'work\nJane Dev\njane@example.com\nyes\n/tmp/does-not-exist\n' \
    'Error: SSH private key path does not exist' \
    'work' \
    'Use GPG signing?'
}

@test "create context with generated SSH and GPG values" {
  local context_file stub_bin ssh_key_path ssh_log gpg_log gpg_batch_log generated_signing_key

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"
  ssh_log="$TMP_HOME/ssh-keygen.log"
  gpg_log="$TMP_HOME/gpg.log"
  gpg_batch_log="$TMP_HOME/gpg-batch.log"
  generated_signing_key='7CDA630DC8C8E970338510C77367EB84A74DB94D'

  mkdir -p "$stub_bin"

  cat >"$stub_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" > "$SSH_KEYGEN_LOG"
printf '%s\n' 'Generating public/private ed25519 key pair.'
printf '%s\n' "Your identification has been saved in $SSH_KEYGEN_PATH"
mkdir -p "$(dirname "$SSH_KEYGEN_PATH")"
touch "$SSH_KEYGEN_PATH"
EOF
  chmod +x "$stub_bin/ssh-keygen"

  cat >"$stub_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" > "$GPG_LOG"
status_fd=''
batch_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status-fd)
      status_fd="$2"
      shift 2
      ;;
    --generate-key)
      batch_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "$batch_file" ]; then
  cat "$batch_file" > "$GPG_BATCH_LOG"
fi

if [ -n "$status_fd" ]; then
  printf '[GNUPG:] KEY_CREATED P %s\n' "$GPG_GENERATED_KEY" >&$status_fd
fi
EOF
  chmod +x "$stub_bin/gpg"

  printf 'work\nJane Dev\njane@example.com\nyes\n\nyes\n\n' |
    PATH="$stub_bin:$PATH" \
      SSH_KEYGEN_LOG="$ssh_log" \
      SSH_KEYGEN_PATH="$ssh_key_path" \
      GPG_LOG="$gpg_log" \
      GPG_BATCH_LOG="$gpg_batch_log" \
      GPG_GENERATED_KEY="$generated_signing_key" \
      "$TOOL" create >/dev/null 2>&1

  assert_file_exists "$context_file" 'create should save the generated context'
  assert_git_config_file_value "$context_file" core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'create should save the generated SSH command'
  assert_git_config_file_value "$context_file" user.signingkey "$generated_signing_key" 'create should save the generated signing key after GPG generation'
  assert_git_config_file_value "$context_file" commit.gpgsign true 'create should enable commit signing after GPG generation'
  assert_git_config_file_value "$context_file" tag.gpgsign true 'create should enable tag signing after GPG generation'
  assert_git_config_file_value "$context_file" gpg.program gpg 'create should still default gpg.program after GPG generation'
  assert_git_config_file_value "$context_file" pull.rebase false 'create should still default pull.rebase after GPG generation'
  assert_git_config_file_value "$context_file" rebase.autoStash false 'create should still default rebase.autoStash after GPG generation'
  assert_git_config_file_value "$context_file" push.default simple 'create should still default push.default after GPG generation'
  assert_git_config_file_value "$context_file" push.autoSetupRemote false 'create should still default push.autoSetupRemote after GPG generation'
  assert_git_config_file_value "$context_file" core.editor vim 'create should still default core.editor after GPG generation'
  assert_contains "$(<"$ssh_log")" '-t ed25519 -C jane@example.com' 'create should invoke ssh-keygen with the expected arguments'
  assert_contains "$(<"$ssh_log")" "-f $ssh_key_path" 'create should generate an SSH key path from the context name'
  assert_contains "$(<"$gpg_log")" '--batch' 'create should invoke batch GPG key generation when the signing key is blank'
  assert_contains "$(<"$gpg_log")" '--generate-key' 'create should invoke batch GPG key generation when the signing key is blank'
  assert_contains "$(<"$gpg_batch_log")" 'Key-Type: RSA' 'create should request an RSA primary key by default'
  assert_contains "$(<"$gpg_batch_log")" 'Subkey-Type: RSA' 'create should request an RSA subkey by default'
  assert_contains "$(<"$gpg_batch_log")" 'Key-Length: 3072' 'create should request the default 3072-bit key size'
  assert_contains "$(<"$gpg_batch_log")" 'Expire-Date: 0' 'create should request a non-expiring GPG key by default'
}

@test "create generated SSH key adds suffix when context path exists" {
  local context_file stub_bin ssh_key_path ssh_log

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work_1"
  ssh_log="$TMP_HOME/ssh-keygen.log"

  mkdir -p "$stub_bin" "$TMP_HOME/.ssh"
  touch "$TMP_HOME/.ssh/id_ed25519_work"

  cat >"$stub_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" > "$SSH_KEYGEN_LOG"
mkdir -p "$(dirname "$SSH_KEYGEN_PATH")"
touch "$SSH_KEYGEN_PATH"
EOF
  chmod +x "$stub_bin/ssh-keygen"

  printf 'work\nJane Dev\njane@example.com\nyes\n\nno\n' |
    PATH="$stub_bin:$PATH" \
      SSH_KEYGEN_LOG="$ssh_log" \
      SSH_KEYGEN_PATH="$ssh_key_path" \
      "$TOOL" create >/dev/null 2>&1

  assert_file_exists "$context_file" 'create should save the context when the generated SSH path needs a suffix'
  assert_git_config_file_value "$context_file" core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'create should save the suffixed SSH key path'
  assert_contains "$(<"$ssh_log")" "-f $ssh_key_path" 'create should suffix the generated SSH key path when the base path exists'
}

@test "create fails when generated SSH key is missing" {
  local context_file stub_bin ssh_log output status

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  ssh_log="$TMP_HOME/ssh-keygen.log"

  mkdir -p "$stub_bin"

  cat >"$stub_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" > "$SSH_KEYGEN_LOG"
printf '%s\n' 'Generating public/private ed25519 key pair.'
EOF
  chmod +x "$stub_bin/ssh-keygen"

  if output=$(printf 'work\nJane Dev\njane@example.com\nyes\n' |
    PATH="$stub_bin:$PATH" \
      SSH_KEYGEN_LOG="$ssh_log" \
      "$TOOL" create 2>&1); then
    fail 'create should fail when generated SSH key material is missing'
  else
    status=$?
  fi

  if [ "$status" -eq 0 ]; then
    fail 'create should fail when generated SSH key material is missing'
  fi

  assert_contains "$output" 'Error: Generated SSH private key path does not exist' 'create should explain that SSH generation did not produce a usable key'
  assert_file_not_exists "$context_file" 'create should not save a context when SSH generation fails'
  assert_contains "$(<"$ssh_log")" '-t ed25519 -C jane@example.com' 'create should still attempt SSH generation before failing'
  assert_contains "$(<"$ssh_log")" "-f $TMP_HOME/.ssh/id_ed25519_work" 'create should generate the missing SSH key at the context path'
}

@test "update context rewrites selected optional settings" {
  local context_file output

  context_file="$(context_file_path work)"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    core.sshCommand 'ssh -i /tmp/work-key -o IdentitiesOnly=yes' \
    user.signingkey 'OLD123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg \
    core.autocrlf false \
    core.fileMode true

  output=$(printf '1\n1,2,3\ngpg2\ninput\nfalse\n' |
    run_tool update 2>&1)

  assert_contains "$output" 'Optional settings:' 'update should show the optional settings menu'
  assert_contains "$output" '1. GPG Program [gpg]' 'update should show the current gpg.program value'
  assert_contains "$output" '2. Autocrlf [false]' 'update should show the current core.autocrlf value'
  assert_contains "$output" '3. FileMode [true]' 'update should show the current core.fileMode value'
  assert_contains "$output" '4. Pull Rebase [false]' 'update should show the current pull.rebase value'
  assert_contains "$output" '8. Core Editor [vim]' 'update should show the current core.editor value'
  assert_not_contains "$output" 'Use SSH connection?' 'update should not prompt to rewrite SSH settings'
  assert_not_contains "$output" 'Use GPG signing?' 'update should not prompt to rewrite GPG enablement'
  assert_contains "$output" "Updated context 'work'." 'update should confirm the selected context was updated'
  assert_git_config_file_value "$context_file" core.sshCommand 'ssh -i /tmp/work-key -o IdentitiesOnly=yes' 'update should preserve the existing SSH command'
  assert_git_config_file_value "$context_file" user.signingkey 'OLD123' 'update should preserve the existing signing key'
  assert_git_config_file_value "$context_file" gpg.program gpg2 'update should rewrite gpg.program when selected'
  assert_git_config_file_value "$context_file" commit.gpgsign true 'update should preserve commit signing state'
  assert_git_config_file_value "$context_file" tag.gpgsign true 'update should preserve tag signing state'
  assert_git_config_file_value "$context_file" core.autocrlf input 'update should rewrite core.autocrlf when selected'
  assert_git_config_file_value "$context_file" core.fileMode false 'update should rewrite core.fileMode when selected'
}

@test "update context rewrites new managed options" {
  local context_file output

  context_file="$(context_file_path work)"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg \
    core.autocrlf false \
    core.fileMode true \
    pull.rebase false \
    rebase.autoStash false \
    push.default simple \
    push.autoSetupRemote false \
    core.editor vim

  output=$(printf '1\n4,5,6,7,8\ntrue\ntrue\ncurrent\ntrue\nnano\n' |
    run_tool update 2>&1)

  assert_contains "$output" "Updated context 'work'." 'update should confirm the selected context was updated'
  assert_git_config_file_value "$context_file" pull.rebase true 'update should rewrite pull.rebase when selected'
  assert_git_config_file_value "$context_file" rebase.autoStash true 'update should rewrite rebase.autoStash when selected'
  assert_git_config_file_value "$context_file" push.default current 'update should rewrite push.default when selected'
  assert_git_config_file_value "$context_file" push.autoSetupRemote true 'update should rewrite push.autoSetupRemote when selected'
  assert_git_config_file_value "$context_file" core.editor nano 'update should rewrite core.editor when selected'
}

@test "update context rewrites only selected subset" {
  local context_file output

  context_file="$(context_file_path work)"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    user.signingkey 'OLD123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg \
    core.autocrlf false \
    core.fileMode true

  output=$(printf '1\n2\ninput\n' |
    run_tool update 2>&1)

  assert_contains "$output" "Updated context 'work'." 'update should confirm the selected context was updated'
  assert_git_config_file_value "$context_file" gpg.program gpg 'update should preserve gpg.program when it is not selected'
  assert_git_config_file_value "$context_file" core.autocrlf input 'update should rewrite only the selected core.autocrlf value'
  assert_git_config_file_value "$context_file" core.fileMode true 'update should preserve core.fileMode when it is not selected'
}

@test "update rejects gpg program selection when gpg is disabled" {
  local context_file output

  context_file="$(context_file_path work)"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  output=$(printf '1\n1\n2\ninput\n' |
    run_tool update 2>&1)

  assert_contains "$output" 'GPG Program can only be updated when GPG signing is enabled for the context.' 'update should explain why gpg.program is unavailable'
  assert_contains "$output" "Updated context 'work'." 'update should still allow choosing another optional setting'
  assert_git_config_file_value "$context_file" core.autocrlf input 'update should rewrite core.autocrlf after a valid retry'
  assert_git_config_file_value "$context_file" core.fileMode true 'update should preserve core.fileMode when it is not selected'
  assert_git_config_file_unset "$context_file" gpg.program 'update should not create gpg.program when GPG signing is disabled'
}

@test "update preserves existing values when rewriting other optional settings" {
  local context_file output

  context_file="$(context_file_path work)"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    core.sshCommand 'ssh -i /tmp/work-key -o IdentitiesOnly=yes' \
    user.signingkey 'ABC123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg2 \
    core.autocrlf false \
    core.fileMode true

  output=$(printf '1\n3\nfalse\n' |
    run_tool update 2>&1)

  assert_contains "$output" "Updated context 'work'." 'update should confirm the selected context was updated'
  assert_git_config_file_value "$context_file" user.name 'Jane Dev' 'update should preserve the stored user name'
  assert_git_config_file_value "$context_file" user.email 'jane@example.com' 'update should preserve the stored email'
  assert_git_config_file_value "$context_file" core.sshCommand 'ssh -i /tmp/work-key -o IdentitiesOnly=yes' 'update should preserve the stored SSH command'
  assert_git_config_file_value "$context_file" user.signingkey 'ABC123' 'update should preserve the stored signing key'
  assert_git_config_file_value "$context_file" commit.gpgsign true 'update should preserve commit signing'
  assert_git_config_file_value "$context_file" tag.gpgsign true 'update should preserve tag signing'
  assert_git_config_file_value "$context_file" gpg.program gpg2 'update should preserve gpg.program when it is not selected'
  assert_git_config_file_value "$context_file" core.autocrlf false 'update should preserve core.autocrlf when it is not selected'
  assert_git_config_file_value "$context_file" core.fileMode false 'update should rewrite only the selected core.fileMode'
  assert_file_not_exists "$context_file.lock" 'update should not leave a git config lock behind'
}

@test "set overwrites managed local git config values" {
  local context_file repo

  context_file="$(context_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$CONTEXT_DIR"
  init_repo "$repo"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    user.signingkey 'ABC123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg2 \
    core.autocrlf input \
    core.fileMode false \
    pull.rebase true \
    rebase.autoStash true \
    push.default current \
    push.autoSetupRemote true \
    core.editor nano \
    core.sshCommand 'ssh -i /tmp/work-key -o IdentitiesOnly=yes'

  write_local_git_config_values "$repo" \
    user.name 'Old Name' \
    user.email 'old@example.com' \
    user.signingkey 'OLDKEY' \
    commit.gpgsign false \
    tag.gpgsign false \
    gpg.program old-gpg \
    core.autocrlf false \
    core.fileMode true \
    pull.rebase false \
    rebase.autoStash false \
    push.default simple \
    push.autoSetupRemote false \
    core.editor vim \
    core.sshCommand 'ssh -i /tmp/old-key'

  run_set_in_repo "$repo"

  assert_git_local_value "$repo" user.name 'Jane Dev' 'set should overwrite the local user name'
  assert_git_local_value "$repo" user.email 'jane@example.com' 'set should overwrite the local email'
  assert_git_local_value "$repo" user.signingkey 'ABC123' 'set should overwrite the local signing key'
  assert_git_local_value "$repo" commit.gpgsign true 'set should enable local commit signing'
  assert_git_local_value "$repo" tag.gpgsign true 'set should enable local tag signing'
  assert_git_local_value "$repo" gpg.program gpg2 'set should overwrite the local gpg program'
  assert_git_local_value "$repo" core.autocrlf input 'set should overwrite local core.autocrlf'
  assert_git_local_value "$repo" core.fileMode false 'set should overwrite local core.fileMode'
  assert_git_local_value "$repo" pull.rebase true 'set should overwrite local pull.rebase'
  assert_git_local_value "$repo" rebase.autoStash true 'set should overwrite local rebase.autoStash'
  assert_git_local_value "$repo" push.default current 'set should overwrite local push.default'
  assert_git_local_value "$repo" push.autoSetupRemote true 'set should overwrite local push.autoSetupRemote'
  assert_git_local_value "$repo" core.editor nano 'set should overwrite local core.editor'
  assert_git_local_value "$repo" core.sshCommand 'ssh -i /tmp/work-key -o IdentitiesOnly=yes' 'set should overwrite the local SSH command'
}

@test "set unsets disabled SSH and GPG values" {
  local context_file repo

  context_file="$(context_file_path personal)"
  repo="$TMP_HOME/repo"

  mkdir -p "$CONTEXT_DIR"
  init_repo "$repo"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  write_local_git_config_values "$repo" \
    user.signingkey 'OLDKEY' \
    gpg.program old-gpg \
    core.sshCommand 'ssh -i /tmp/old-key' \
    commit.gpgsign true \
    tag.gpgsign true \
    pull.rebase true \
    rebase.autoStash true \
    push.default current \
    push.autoSetupRemote true \
    core.editor nano

  run_set_in_repo "$repo"

  assert_git_local_value "$repo" user.name 'Jane Dev' 'set should still update the local user name'
  assert_git_local_value "$repo" user.email 'jane@example.com' 'set should still update the local email'
  assert_git_local_value "$repo" commit.gpgsign false 'set should disable local commit signing'
  assert_git_local_value "$repo" tag.gpgsign false 'set should disable local tag signing'
  assert_git_local_value "$repo" core.autocrlf false 'set should still update local core.autocrlf'
  assert_git_local_value "$repo" core.fileMode true 'set should still update local core.fileMode'
  assert_git_local_value "$repo" pull.rebase false 'set should apply the default pull.rebase for older contexts'
  assert_git_local_value "$repo" rebase.autoStash false 'set should apply the default rebase.autoStash for older contexts'
  assert_git_local_value "$repo" push.default simple 'set should apply the default push.default for older contexts'
  assert_git_local_value "$repo" push.autoSetupRemote false 'set should apply the default push.autoSetupRemote for older contexts'
  assert_git_local_value "$repo" core.editor vim 'set should apply the default core.editor for older contexts'
  assert_git_local_unset "$repo" core.sshCommand 'set should unset the local SSH command when SSH is disabled'
  assert_git_local_unset "$repo" user.signingkey 'set should unset the local signing key when GPG is disabled'
  assert_git_local_unset "$repo" gpg.program 'set should unset the local gpg program when GPG is disabled'
}

@test "set replaces duplicate local values cleanly" {
  local context_file repo

  context_file="$(context_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$CONTEXT_DIR"
  init_repo "$repo"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf input \
    core.fileMode false

  append_local_git_config_values "$repo" \
    user.name 'Old Name One' \
    user.name 'Old Name Two' \
    core.autocrlf false \
    core.autocrlf true \
    core.sshCommand 'ssh -i /tmp/old-key-1' \
    core.sshCommand 'ssh -i /tmp/old-key-2' \
    user.signingkey OLDKEY1 \
    user.signingkey OLDKEY2 \
    gpg.program old-gpg-1 \
    gpg.program old-gpg-2

  run_set_in_repo "$repo"

  assert_git_local_all_values "$repo" user.name 'Jane Dev' 'set should replace duplicate local user.name entries'
  assert_git_local_all_values "$repo" core.autocrlf input 'set should replace duplicate local core.autocrlf entries'
  assert_git_local_unset "$repo" core.sshCommand 'set should remove duplicate local SSH entries when SSH is disabled'
  assert_git_local_unset "$repo" user.signingkey 'set should remove duplicate local signing keys when GPG is disabled'
  assert_git_local_unset "$repo" gpg.program 'set should remove duplicate local gpg.program entries when GPG is disabled'
}

@test "set fails outside git repository" {
  local context_file outside_dir

  context_file="$(context_file_path work)"
  outside_dir="$TMP_HOME/outside"

  mkdir -p "$CONTEXT_DIR" "$outside_dir"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  assert_command_fails \
    'Error: set must be run inside a Git repository' \
    bash -c "cd \"$outside_dir\" && printf '1\\n' | HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" \"$TOOL\" set" \
    --
}
