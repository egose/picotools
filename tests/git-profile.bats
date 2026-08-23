#!/usr/bin/env bats

load 'helpers/git-profile'

@test "help version and empty list" {
  local output version

  output=$(run_tool --help)
  assert_contains "$output" 'Usage: git-profile [--debug] <command>' 'help should describe the command entrypoint'
  assert_contains "$output" 'read [--commands]' 'help should list the read command grammar'
  assert_contains "$output" 'token                      Print the active repository profile' 'help should list the token command'
  assert_contains "$output" 'create, update, list, commands, delete, set, and token accept no command' 'help should document no-argument command grammar'
  assert_contains "$output" 'picotools.gitProfile' 'help should describe the repository marker'
  assert_contains "$output" 'writes a secret to stdout' 'help should warn that token prints a secret'
  assert_contains "$output" 'Saved profile files are tool-owned' 'help should document saved profile file ownership'
  assert_contains "$output" 'fail closed when permissions drift' 'help should document PAT read permission policy'
  assert_contains "$output" 'same-directory atomic replacement' 'help should document failure-safe PAT persistence'
  assert_contains "$output" 'picotools.sshKeyPath' 'help should document structured SSH key compatibility'
  assert_contains "$output" '--debug' 'help should list debug mode'

  version=$(run_tool --version)
  assert_eq "$version" "$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" 'version output should match VERSION file'

  output=$(run_tool list)
  assert_contains "$output" 'No git profiles found.' 'list should explain when there are no saved profiles'
}

@test "help and version do not require operational dependencies" {
  local restricted_path output version

  restricted_path=$(path_with_commands "$TMP_HOME/no-operational-deps-bin" bash cat dirname tr)

  output=$(PATH="$restricted_path" "$TOOL" --help)
  assert_contains "$output" 'Usage: git-profile [--debug] <command>' 'help should work without git ssh-keygen or gpg on PATH'
  assert_contains "$output" 'Operational commands require git.' 'help should document mandatory git dependency'

  version=$(PATH="$restricted_path" "$TOOL" --version)
  assert_eq "$version" "$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")" 'version should work without git ssh-keygen or gpg on PATH'
}

@test "create requires git before prompting or saving" {
  local restricted_path output context_file

  restricted_path=$(path_with_commands "$TMP_HOME/no-git-bin" bash dirname)
  context_file="$(context_file_path work)"

  if output=$(printf 'work\nJane Dev\njane@example.com\nno\nno\n\n' | PATH="$restricted_path" "$TOOL" create 2>&1); then
    fail 'create should fail when git is missing'
  fi

  assert_contains "$output" 'Error: git is required but not installed' 'create should report the missing git dependency'
  assert_not_contains "$output" 'Context name:' 'create should fail before prompting for profile input'
  assert_file_not_exists "$context_file" 'create should not save a profile when git is missing'
}

@test "generated SSH flow requires ssh-keygen before later prompts or saving" {
  local restricted_path output context_file

  restricted_path=$(path_with_commands "$TMP_HOME/no-ssh-keygen-bin" bash dirname git mkdir mktemp rm)
  context_file="$(context_file_path work)"

  if output=$(printf 'work\nJane Dev\njane@example.com\nyes\n\n' | PATH="$restricted_path" "$TOOL" create 2>&1); then
    fail 'create should fail when generated SSH is requested without ssh-keygen'
  fi

  assert_contains "$output" 'Error: ssh-keygen is required but not installed' 'generated SSH should report the missing ssh-keygen dependency'
  assert_not_contains "$output" 'Add SSH key to agent on shell start?' 'generated SSH should fail before later SSH prompts'
  assert_file_not_exists "$context_file" 'create should not save a profile when SSH key generation cannot run'
}

@test "generated GPG flow requires gpg before PAT prompt or saving" {
  local restricted_path output context_file

  restricted_path=$(path_with_commands "$TMP_HOME/no-gpg-bin" bash dirname git mkdir mktemp rm)
  context_file="$(context_file_path work)"

  if output=$(printf 'work\nJane Dev\njane@example.com\nno\nyes\n\n' | PATH="$restricted_path" "$TOOL" create 2>&1); then
    fail 'create should fail when generated GPG is requested without gpg'
  fi

  assert_contains "$output" 'Error: gpg is required but not installed' 'generated GPG should report the missing gpg dependency'
  assert_not_contains "$output" 'GitHub PAT' 'generated GPG should fail before prompting for PAT storage'
  assert_file_not_exists "$context_file" 'create should not save a profile when GPG key generation cannot run'
}

@test "delete requires configured GPG command before profile mutation" {
  local context_file restricted_path output

  context_file="$(context_file_path work)"
  restricted_path=$(path_with_commands "$TMP_HOME/no-configured-gpg-bin" bash basename dirname git sort)

  mkdir -p "$PROFILE_DIR"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    user.signingkey 'ABC123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg-missing \
    core.autocrlf false \
    core.fileMode true

  if output=$(printf '1\ny\ny\n' | PATH="$restricted_path" "$TOOL" delete 2>&1); then
    fail 'delete should fail when the configured GPG command is missing'
  fi

  assert_contains "$output" 'Error: gpg-missing is required but not installed' 'delete should report the missing configured GPG command'
  assert_file_exists "$context_file" 'delete should preserve the profile when configured GPG deletion cannot run'
}

@test "profile modules validate candidate state directly" {
  local output
  local -A profile=()

  source_git_profile_modules
  git_profile_state_defaults profile
  profile[user_name]='Jane Dev'
  profile[email]='jane@example.com'
  profile[use_ssh]=yes
  profile[ssh_key_path]='relative-key'

  if output=$(git_profile_state_validate_candidate 'candidate profile test' profile 2>&1); then
    fail 'candidate validation should reject relative managed SSH key paths'
  fi

  assert_contains "$output" "non-absolute managed SSH key path 'picotools.sshKeyPath'" 'candidate validation should report the schema violation'

  profile[use_ssh]=no
  profile[ssh_key_path]=''
  profile[push_default]=current
  git_profile_state_validate_candidate 'candidate profile test' profile
}

@test "profile modules serialize and validate profile state directly" {
  local context_file ssh_key_path
  local -A profile=()

  context_file="$(context_file_path module)"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_module"
  mkdir -p "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"

  source_git_profile_modules
  register_git_profile_module_test_hooks
  git_profile_state_defaults profile
  profile[user_name]='Jane Dev'
  profile[email]='jane@example.com'
  profile[use_ssh]=yes
  profile[ssh_key_path]="$ssh_key_path"
  profile[use_gpg]=yes
  profile[signing_key]='ABC123'
  profile[gpg_program]='gpg2'
  profile[autocrlf]=input
  profile[file_mode]=false
  profile[pull_rebase]=merges
  profile[rebase_autostash]=true
  profile[push_default]=upstream
  profile[push_autosetupremote]=true
  profile[core_editor]=nano
  # shellcheck disable=SC2034 # read through nameref in save_context
  profile[ssh_add_on_start]=true

  save_context "$context_file" profile

  validate_profile_file_schema "$context_file"
  assert_mode "$context_file" 600 'direct profile serialization should publish a private config file'
  assert_git_config_file_value "$context_file" user.name 'Jane Dev' 'direct serialization should save user.name'
  assert_git_config_file_value "$context_file" picotools.sshKeyPath "$ssh_key_path" 'direct serialization should save structured SSH path'
  assert_git_config_file_value "$context_file" core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'direct serialization should derive the SSH command'
  assert_git_config_file_value "$context_file" gpg.program gpg2 'direct serialization should save gpg.program'
  assert_git_config_file_value "$context_file" pull.rebase merges 'direct serialization should save accepted pull.rebase values'
}

@test "installed layout resolves git-profile modules for operational list" {
  local install_dir output

  install_dir="$TMP_HOME/install"
  mkdir -p "$install_dir/bin" "$install_dir/lib/picotools"
  cp "$TOOL" "$install_dir/bin/git-profile"
  cp "$REPO_ROOT"/lib/picotools/*.sh "$install_dir/lib/picotools/"
  cp -R "$REPO_ROOT/tools/lib/picotools/git-profile" "$install_dir/lib/picotools/git-profile"

  output=$("$install_dir/bin/git-profile" list)

  assert_contains "$output" 'No git profiles found.' 'installed layout should resolve extracted modules for operational commands'
}

@test "no-argument commands reject unsupported arguments before work" {
  local command output

  for command in create list commands delete set update; do
    if output=$(run_tool "$command" unexpected 2>&1); then
      fail "$command should fail when an unsupported argument is provided"
    fi

    assert_contains "$output" "Error: $command does not accept arguments: unexpected" "$command should reject extra arguments"
    assert_contains "$output" 'Usage: git-profile [--debug] <command>' "$command should print usage for unsupported arguments"
  done

  if output=$(run_tool read unexpected 2>&1); then
    fail 'read should fail when an unsupported argument is provided'
  fi
  assert_contains "$output" "Error: unknown read option 'unexpected'" 'read should reject unsupported options before selecting a profile'
}

@test "debug is accepted only before the command" {
  local output

  if output=$(run_tool clone --debug 2>&1); then
    fail 'clone should reject subcommand-local --debug'
  fi

  assert_contains "$output" 'Error: --debug is a global option; place it before the command' 'clone should document the global-only debug grammar'
}

@test "list prints debug details when enabled" {
  local output

  printf 'personal\nJane Dev\njane@example.com\nno\nno\n\n' |
    run_tool create >/dev/null 2>&1

  output=$(run_tool --debug list 2>&1)
  assert_contains "$output" '[git-profile] Listing 1 saved profile(s)' 'debug mode should describe the number of saved profiles'
  assert_contains "$output" 'personal' 'debug mode should still print the context list'
}

@test "create list and delete context" {
  local output context_file

  context_file="$(context_file_path personal)"

  printf 'personal\nJane Dev\njane@example.com\nno\nno\n\n' |
    run_tool create >/dev/null 2>&1

  assert_file_exists "$context_file" 'create should save the named context'

  output=$(run_tool list)
  assert_contains "$output" '| # ' 'list should print an index column'
  assert_contains "$output" '| Name' 'list should print a table header'
  assert_contains "$output" '| PAT' 'list should print the PAT status column'
  assert_contains "$output" 'personal' 'list should include the context name'
  assert_contains "$output" 'Jane Dev' 'list should include the user name'
  assert_contains "$output" 'jane@example.com' 'list should include the email'
  assert_contains "$output" ' no ' 'list should show disabled optional features'
  assert_not_contains "$output" 'Autocrlf' 'list should not include the detailed optional settings columns'

  assert_not_contains "$output" 'Actions:' 'list should not prompt for follow-up actions'
  assert_not_contains "$output" 'Select profile for details' 'list should not prompt for detail selection'

  printf '1\ny\n' | run_tool delete >/dev/null 2>&1

  assert_file_not_exists "$context_file" 'delete should remove the selected context file'
}

@test "delete context can remove SSH and GPG material" {
  local context_file ssh_key_path gpg_log stub_bin output

  context_file="$(context_file_path work)"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"
  gpg_log="$TMP_HOME/gpg.log"
  stub_bin="$TMP_HOME/bin"

  mkdir -p "$PROFILE_DIR" "$stub_bin" "$(dirname "$ssh_key_path")"
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

printf '%s\n' "$@" > "$GPG_LOG"
EOF
  chmod +x "$stub_bin/gpg"

  output=$(printf '1\ny\ny\ny\n' |
    PATH="$stub_bin:$PATH" \
      GPG_LOG="$gpg_log" \
      "$TOOL" delete 2>&1)

  assert_contains "$output" 'Deleted profile.' 'delete should confirm the profile was deleted'
  assert_file_not_exists "$context_file" 'delete should remove the selected context file'
  assert_file_not_exists "$ssh_key_path" 'delete should remove the SSH private key when requested'
  assert_file_not_exists "$ssh_key_path.pub" 'delete should remove the SSH public key when requested'
  assert_eq "$(sed -n '1p' "$gpg_log")" '--batch' 'delete should invoke GPG in batch mode'
  assert_eq "$(sed -n '2p' "$gpg_log")" '--yes' 'delete should confirm the GPG deletion non-interactively'
  assert_eq "$(sed -n '3p' "$gpg_log")" '--delete-secret-and-public-key' 'delete should request GPG key deletion'
  assert_eq "$(sed -n '4p' "$gpg_log")" '--' 'delete should terminate GPG option parsing before the signing key'
  assert_eq "$(sed -n '5p' "$gpg_log")" 'ABC123' 'delete should pass the signing key as an operand'
}

@test "delete PAT preflight failure preserves profile PAT SSH and GPG material" {
  local context_file token_file token_target ssh_key_path gpg_log stub_bin output
  local token='ghp_delete_preflight_sentinel'

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  token_target="$TMP_HOME/outside-delete.token"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"
  gpg_log="$TMP_HOME/gpg.log"
  stub_bin="$TMP_HOME/bin"

  mkdir -p "$PROFILE_DIR" "$PROFILE_DATA_DIR" "$stub_bin" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path" "$ssh_key_path.pub"
  printf '%s\n' "$token" >"$token_target"
  ln -s "$token_target" "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"

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

printf '%s\n' "$@" > "$GPG_LOG"
EOF
  chmod +x "$stub_bin/gpg"

  if output=$(printf '1\ny\ny\ny\n' |
    PATH="$stub_bin:$PATH" GPG_LOG="$gpg_log" "$TOOL" delete 2>&1); then
    fail 'delete should fail before mutation when PAT deletion is unsafe'
  fi

  assert_contains "$output" "refusing to delete PAT for profile 'work'" 'delete should explain why PAT deletion was rejected'
  assert_file_exists "$context_file" 'failed delete preflight should leave the profile file in place'
  [ -L "$token_file" ] || fail 'failed delete preflight should leave the token symlink in place'
  assert_eq "$(<"$token_target")" "$token" 'failed delete preflight should leave PAT material unchanged'
  assert_file_exists "$ssh_key_path" 'failed delete preflight should preserve SSH private key material'
  assert_file_exists "$ssh_key_path.pub" 'failed delete preflight should preserve SSH public key material'
  assert_file_not_exists "$gpg_log" 'failed delete preflight should not invoke GPG deletion'
  assert_not_contains "$output" "$token" 'delete failure output should not print the PAT value'
}

@test "delete rejects dash-leading GPG signing identifiers before mutation" {
  local context_file gpg_log stub_bin output

  context_file="$(context_file_path work)"
  gpg_log="$TMP_HOME/gpg.log"
  stub_bin="$TMP_HOME/bin"

  mkdir -p "$PROFILE_DIR" "$stub_bin"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    user.signingkey '-ABC123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg \
    core.autocrlf false \
    core.fileMode true

  cat >"$stub_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" > "$GPG_LOG"
EOF
  chmod +x "$stub_bin/gpg"

  if output=$(printf '1\ny\ny\n' |
    PATH="$stub_bin:$PATH" GPG_LOG="$gpg_log" "$TOOL" delete 2>&1); then
    fail 'delete should reject option-like GPG signing identifiers'
  fi

  assert_contains "$output" 'unsafe identifier: -ABC123' 'delete should explain that the GPG identifier is unsafe'
  assert_file_exists "$context_file" 'unsafe GPG identifiers should fail before profile deletion'
  assert_file_not_exists "$gpg_log" 'unsafe GPG identifiers should fail before invoking GPG'
}

@test "delete rejects malformed GPG signing identifiers before mutation" {
  local context_file gpg_log stub_bin output

  context_file="$(context_file_path work)"
  gpg_log="$TMP_HOME/gpg.log"
  stub_bin="$TMP_HOME/bin"

  mkdir -p "$PROFILE_DIR" "$stub_bin"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    user.signingkey 'ABC 123' \
    commit.gpgsign true \
    tag.gpgsign true \
    gpg.program gpg \
    core.autocrlf false \
    core.fileMode true

  cat >"$stub_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" > "$GPG_LOG"
EOF
  chmod +x "$stub_bin/gpg"

  if output=$(printf '1\ny\ny\n' |
    PATH="$stub_bin:$PATH" GPG_LOG="$gpg_log" "$TOOL" delete 2>&1); then
    fail 'delete should reject malformed GPG signing identifiers'
  fi

  assert_contains "$output" 'unsafe identifier: ABC 123' 'delete should explain that the GPG identifier is malformed'
  assert_file_exists "$context_file" 'malformed GPG identifiers should fail before profile deletion'
  assert_file_not_exists "$gpg_log" 'malformed GPG identifiers should fail before invoking GPG'
}

@test "delete uses option-safe SSH key deletion for dash-leading paths" {
  local context_file ssh_key_path output

  context_file="$(context_file_path work)"
  ssh_key_path='-work-key'

  mkdir -p "$PROFILE_DIR"
  touch "$TMP_HOME/$ssh_key_path" "$TMP_HOME/$ssh_key_path.pub"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true \
    core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes"

  output=$(
    cd "$TMP_HOME" || return 1
    printf '1\ny\ny\n' | "$TOOL" delete 2>&1
  )

  assert_contains "$output" 'Deleted profile.' 'delete should complete when deleting a dash-leading SSH key path'
  assert_file_not_exists "$context_file" 'delete should remove the selected context file'
  assert_file_not_exists "$TMP_HOME/$ssh_key_path" 'delete should remove the dash-leading SSH private key as an operand'
  assert_file_not_exists "$TMP_HOME/$ssh_key_path.pub" 'delete should remove the dash-leading SSH public key as an operand'
}

@test "create context with existing SSH and GPG values" {
  local context_file ssh_key_path output

  ssh_key_path="$TMP_HOME/id_ed25519"
  context_file="$(context_file_path work)"

  touch "$ssh_key_path"

  printf 'work\nJane Dev\njane@example.com\nyes\n%s\nyes\nyes\nABC123\n\n' "$ssh_key_path" |
    run_tool create >/dev/null 2>&1

  assert_file_exists "$context_file" 'create should save the named context'
  assert_git_config_file_value "$context_file" user.name 'Jane Dev' 'create should save the git user name'
  assert_git_config_file_value "$context_file" user.email 'jane@example.com' 'create should save the git email'
  assert_git_config_file_value "$context_file" picotools.sshKeyPath "$ssh_key_path" 'create should save the structured SSH key path'
  assert_git_config_file_value "$context_file" core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'create should save the managed SSH command'
  assert_git_config_file_value "$context_file" picotools.sshAddOnStart true 'create should save the SSH add-on-start preference'
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

  mkdir -p "$PROFILE_DIR" "$(dirname "$ssh_key_path")"
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
    picotools.sshAddOnStart true \
    core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes"

  output=$(printf '1\nno\n' | run_tool read 2>&1)

  assert_contains "$output" '| Field ' 'read should render a table header'
  assert_contains "$output" '| Name ' 'read should include the context name field'
  assert_contains "$output" '| User ' 'read should include the user field'
  assert_contains "$output" '| Email ' 'read should include the email field'
  assert_contains "$output" '| PAT ' 'read should include the PAT field'
  assert_contains "$output" '| SSH ' 'read should include SSH enabled field'
  assert_contains "$output" '| SSH Key ' 'read should include the SSH key field'
  assert_contains "$output" "$ssh_key_path" 'read should include the SSH key path'
  assert_contains "$output" '| SSH Command ' 'read should include the SSH command field'
  assert_contains "$output" "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'read should include the SSH command'
  assert_contains "$output" '| SSH Add On Start ' 'read should include the SSH add-on-start field'
  assert_contains "$output" 'true' 'read should include the SSH add-on-start value'
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

  mkdir -p "$PROFILE_DIR" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"
  printf '%s\n' "$public_key" >"$ssh_key_path.pub"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    picotools.sshAddOnStart true \
    core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" \
    core.autocrlf false \
    core.fileMode true

  output=$(printf '1\nyes\n' | run_tool read 2>&1)

  assert_contains "$output" 'Display public SSH key? [y/N]:' 'read should prompt before displaying the public SSH key'
  assert_contains "$output" "Public SSH Key ($ssh_key_path.pub):" 'read should print the public key header when requested'
  assert_contains "$output" "$public_key" 'read should print the public key contents when requested'
}

@test "profile selection failures return non-zero status" {
  local context_file output

  if output=$(run_tool read 2>&1); then
    fail 'read should fail when there are no profiles to select'
  fi
  assert_contains "$output" 'No git profiles found.' 'read should explain when profile selection has no options'

  context_file="$(context_file_path work)"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  if output=$(printf '99\n' | run_tool read 2>&1); then
    fail 'read should fail when profile selection is invalid'
  fi
  assert_contains "$output" 'Error: invalid selection' 'read should propagate invalid selection failures'

  if output=$(printf 'q\n' | run_tool read 2>&1); then
    fail 'read should fail when profile selection is cancelled explicitly'
  fi
  assert_contains "$output" 'Cancelled.' 'read should report explicit profile selection cancellation'
}

@test "create rejects missing existing SSH key path" {
  assert_create_fails \
    'work\nJane Dev\njane@example.com\nyes\n/tmp/does-not-exist\n' \
    'Error: SSH private key path does not exist' \
    'work' \
    'Use GPG signing?'
}

@test "create rejects blank required identity values before saving" {
  local context_file output

  context_file="$(context_file_path blank)"

  if output=$(printf 'blank\n   \njane@example.com\nno\nno\n\n' | run_tool create 2>&1); then
    fail 'create should reject a blank required user.name value'
  fi

  assert_contains "$output" "blank required value 'user.name'" 'create should explain that user.name is required'
  assert_file_not_exists "$context_file" 'create should not persist a profile with a blank identity'
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

printf '%s\n' "$@" > "$SSH_KEYGEN_LOG"
printf '%s\n' 'Generating public/private ed25519 key pair.'
printf '%s\n' "Your identification has been saved in $SSH_KEYGEN_PATH"
mkdir -p "$(dirname "$SSH_KEYGEN_PATH")"
touch "$SSH_KEYGEN_PATH"
EOF
  chmod +x "$stub_bin/ssh-keygen"

  cat >"$stub_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" > "$GPG_LOG"
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

  printf 'work\nJane Dev\njane@example.com\nyes\n\nno\nyes\n\n\n' |
    PATH="$stub_bin:$PATH" \
      SSH_KEYGEN_LOG="$ssh_log" \
      SSH_KEYGEN_PATH="$ssh_key_path" \
      GPG_LOG="$gpg_log" \
      GPG_BATCH_LOG="$gpg_batch_log" \
      GPG_GENERATED_KEY="$generated_signing_key" \
      "$TOOL" create >/dev/null 2>&1

  assert_file_exists "$context_file" 'create should save the generated context'
  assert_git_config_file_value "$context_file" picotools.sshKeyPath "$ssh_key_path" 'create should save the generated structured SSH key path'
  assert_git_config_file_value "$context_file" core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'create should save the generated SSH command'
  assert_git_config_file_value "$context_file" picotools.sshAddOnStart false 'create should default SSH add-on-start to false when declined'
  assert_git_config_file_value "$context_file" user.signingkey "$generated_signing_key" 'create should save the generated signing key after GPG generation'
  assert_git_config_file_value "$context_file" commit.gpgsign true 'create should enable commit signing after GPG generation'
  assert_git_config_file_value "$context_file" tag.gpgsign true 'create should enable tag signing after GPG generation'
  assert_git_config_file_value "$context_file" gpg.program gpg 'create should still default gpg.program after GPG generation'
  assert_git_config_file_value "$context_file" pull.rebase false 'create should still default pull.rebase after GPG generation'
  assert_git_config_file_value "$context_file" rebase.autoStash false 'create should still default rebase.autoStash after GPG generation'
  assert_git_config_file_value "$context_file" push.default simple 'create should still default push.default after GPG generation'
  assert_git_config_file_value "$context_file" push.autoSetupRemote false 'create should still default push.autoSetupRemote after GPG generation'
  assert_git_config_file_value "$context_file" core.editor vim 'create should still default core.editor after GPG generation'
  assert_contains "$(<"$ssh_log")" '-t' 'create should invoke ssh-keygen with the key type option'
  assert_contains "$(<"$ssh_log")" 'ed25519' 'create should request the ed25519 key type'
  assert_contains "$(<"$ssh_log")" '-C' 'create should invoke ssh-keygen with the comment option'
  assert_contains "$(<"$ssh_log")" 'jane@example.com' 'create should pass the email as the SSH key comment'
  assert_contains "$(<"$ssh_log")" '-f' 'create should invoke ssh-keygen with the key path option'
  assert_contains "$(<"$ssh_log")" "$ssh_key_path" 'create should generate an SSH key path from the context name'
  assert_contains "$(<"$gpg_log")" '--batch' 'create should invoke batch GPG key generation when the signing key is blank'
  assert_contains "$(<"$gpg_log")" '--generate-key' 'create should invoke batch GPG key generation when the signing key is blank'
  assert_contains "$(<"$gpg_batch_log")" 'Key-Type: RSA' 'create should request an RSA primary key by default'
  assert_contains "$(<"$gpg_batch_log")" 'Subkey-Type: RSA' 'create should request an RSA subkey by default'
  assert_contains "$(<"$gpg_batch_log")" 'Key-Length: 3072' 'create should request the default 3072-bit key size'
  assert_contains "$(<"$gpg_batch_log")" 'Expire-Date: 0' 'create should request a non-expiring GPG key by default'
}

@test "create reports missing GPG KEY_CREATED status without unbound variables" {
  local context_file stub_bin output

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  mkdir -p "$stub_bin"

  cat >"$stub_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

exit 0
EOF
  chmod +x "$stub_bin/gpg"

  if output=$(printf 'work\nJane Dev\njane@example.com\nno\nyes\n\n\n' |
    PATH="$stub_bin:$PATH" "$TOOL" create 2>&1); then
    fail 'create should fail when GPG does not report a generated signing key'
  fi

  assert_contains "$output" 'Error: failed to determine generated GPG signing key from GPG status output' 'create should report missing GPG KEY_CREATED status'
  assert_not_contains "$output" 'unbound variable' 'create should not fail with an unbound signing_key diagnostic'
  assert_file_not_exists "$context_file" 'failed GPG parsing should not save a profile'
}

@test "create reports malformed GPG KEY_CREATED status" {
  local context_file stub_bin output

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  mkdir -p "$stub_bin"

  cat >"$stub_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

status_fd=''
while [ "$#" -gt 0 ]; do
  case "$1" in
  --status-fd)
    status_fd="$2"
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done

if [ -n "$status_fd" ]; then
  printf '%s\n' '[GNUPG:] KEY_CREATED P' >&$status_fd
fi
EOF
  chmod +x "$stub_bin/gpg"

  if output=$(printf 'work\nJane Dev\njane@example.com\nno\nyes\n\n\n' |
    PATH="$stub_bin:$PATH" "$TOOL" create 2>&1); then
    fail 'create should fail when GPG reports a malformed KEY_CREATED status'
  fi

  assert_contains "$output" 'Error: failed to determine generated GPG signing key from GPG status output' 'create should report malformed GPG KEY_CREATED status'
  assert_not_contains "$output" 'unbound variable' 'create should not fail with an unbound signing_key diagnostic'
  assert_file_not_exists "$context_file" 'failed GPG parsing should not save a profile'
}

@test "failed create removes generated SSH material and leaves GPG recovery fingerprint" {
  local context_file outside_data stub_bin ssh_key_path output
  local generated_signing_key='7CDA630DC8C8E970338510C77367EB84A74DB94D'

  context_file="$(context_file_path work)"
  outside_data="$TMP_HOME/outside-data"
  stub_bin="$TMP_HOME/bin"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"

  mkdir -p "$(dirname "$PROFILE_DATA_DIR")" "$outside_data" "$stub_bin"
  ln -s "$outside_data" "$PROFILE_DATA_DIR"

  cat >"$stub_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

key_path=''
while [ "$#" -gt 0 ]; do
  case "$1" in
  -f)
    key_path="$2"
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done

mkdir -p "$(dirname "$key_path")"
touch "$key_path" "$key_path.pub"
EOF
  chmod +x "$stub_bin/ssh-keygen"

  cat >"$stub_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

status_fd=''
while [ "$#" -gt 0 ]; do
  case "$1" in
  --status-fd)
    status_fd="$2"
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done

if [ -n "$status_fd" ]; then
  printf '[GNUPG:] KEY_CREATED P %s\n' "$GPG_GENERATED_KEY" >&$status_fd
fi
EOF
  chmod +x "$stub_bin/gpg"

  if output=$(printf 'work\nJane Dev\njane@example.com\nyes\n\nno\nyes\n\ncreate-token\n' |
    PATH="$stub_bin:$PATH" GPG_GENERATED_KEY="$generated_signing_key" "$TOOL" create 2>&1); then
    fail 'create should fail when PAT publication is unsafe after generating material'
  fi

  assert_contains "$output" 'data directory is a symbolic link' 'create should explain why PAT publication failed'
  assert_contains "$output" "Generated GPG signing key retained after failed create: $generated_signing_key" 'create should report the retained generated GPG fingerprint'
  assert_file_not_exists "$context_file" 'failed create should not leave a new profile file'
  assert_file_not_exists "$outside_data/work.token" 'failed create should not write a token into the unsafe data target'
  assert_file_not_exists "$ssh_key_path" 'failed create should remove the generated SSH private key'
  assert_file_not_exists "$ssh_key_path.pub" 'failed create should remove the generated SSH public key'
  assert_no_profile_temps "$PROFILE_DIR"
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

printf '%s\n' "$@" > "$SSH_KEYGEN_LOG"
mkdir -p "$(dirname "$SSH_KEYGEN_PATH")"
touch "$SSH_KEYGEN_PATH"
EOF
  chmod +x "$stub_bin/ssh-keygen"

  printf 'work\nJane Dev\njane@example.com\nyes\n\nno\nno\n\n' |
    PATH="$stub_bin:$PATH" \
      SSH_KEYGEN_LOG="$ssh_log" \
      SSH_KEYGEN_PATH="$ssh_key_path" \
      "$TOOL" create >/dev/null 2>&1

  assert_file_exists "$context_file" 'create should save the context when the generated SSH path needs a suffix'
  assert_git_config_file_value "$context_file" picotools.sshKeyPath "$ssh_key_path" 'create should save the structured suffixed SSH key path'
  assert_git_config_file_value "$context_file" core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'create should save the suffixed SSH key path'
  assert_git_config_file_value "$context_file" picotools.sshAddOnStart false 'create should save SSH add-on-start as false when declined'
  assert_contains "$(<"$ssh_log")" '-f' 'create should invoke ssh-keygen with the key path option'
  assert_contains "$(<"$ssh_log")" "$ssh_key_path" 'create should suffix the generated SSH key path when the base path exists'
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

printf '%s\n' "$@" > "$SSH_KEYGEN_LOG"
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
  assert_contains "$(<"$ssh_log")" '-t' 'create should still pass the SSH key type option before failing'
  assert_contains "$(<"$ssh_log")" 'ed25519' 'create should still request the ed25519 key type before failing'
  assert_contains "$(<"$ssh_log")" '-C' 'create should still pass the SSH key comment option before failing'
  assert_contains "$(<"$ssh_log")" 'jane@example.com' 'create should still pass the email as the SSH key comment before failing'
  assert_contains "$(<"$ssh_log")" '-f' 'create should still pass the SSH key path option before failing'
  assert_contains "$(<"$ssh_log")" "$TMP_HOME/.ssh/id_ed25519_work" 'create should generate the missing SSH key at the context path'
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

  output=$(printf '1\n1\ngpg2\n2\ninput\n3\nfalse\n11\n' |
    run_tool update 2>&1)

  assert_contains "$output" 'Optional settings:' 'update should show the optional settings menu'
  assert_contains "$output" 'Select setting:' 'update should prompt for a selected setting'
  assert_contains "$output" '1. GPG Program [gpg]' 'update should show the current gpg.program value'
  assert_contains "$output" '2. Autocrlf [false]' 'update should show the current core.autocrlf value'
  assert_contains "$output" '3. FileMode [true]' 'update should show the current core.fileMode value'
  assert_contains "$output" '4. Pull Rebase [false]' 'update should show the current pull.rebase value'
  assert_contains "$output" '8. Core Editor [vim]' 'update should show the current core.editor value'
  assert_contains "$output" '9. SSH Add On Start [false]' 'update should show the current SSH add-on-start value'
  assert_contains "$output" '10. PAT [no]' 'update should offer PAT as an updatable field'
  assert_contains "$output" '11. Done' 'update should offer a done option'
  assert_not_contains "$output" 'Use SSH connection?' 'update should not prompt to rewrite SSH settings'
  assert_not_contains "$output" 'Use GPG signing?' 'update should not prompt to rewrite GPG enablement'
  assert_contains "$output" "Updated profile 'work'." 'update should confirm the selected profile was updated'
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

  output=$(printf '1\n4\ntrue\n5\ntrue\n6\ncurrent\n7\ntrue\n8\nnano\n11\n' |
    run_tool update 2>&1)

  assert_contains "$output" "Updated profile 'work'." 'update should confirm the selected profile was updated'
  assert_git_config_file_value "$context_file" pull.rebase true 'update should rewrite pull.rebase when selected'
  assert_git_config_file_value "$context_file" rebase.autoStash true 'update should rewrite rebase.autoStash when selected'
  assert_git_config_file_value "$context_file" push.default current 'update should rewrite push.default when selected'
  assert_git_config_file_value "$context_file" push.autoSetupRemote true 'update should rewrite push.autoSetupRemote when selected'
  assert_git_config_file_value "$context_file" core.editor nano 'update should rewrite core.editor when selected'
}

@test "update rejects invalid managed values before persistence" {
  local context_file output

  context_file="$(context_file_path work)"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true \
    pull.rebase false \
    push.default simple

  if output=$(printf '1\n6\nsideways\n11\n' | run_tool update 2>&1); then
    fail 'update should reject an invalid push.default candidate'
  fi

  assert_contains "$output" "invalid value 'sideways' for 'push.default'" 'update should explain the invalid managed value'
  assert_git_config_file_value "$context_file" push.default simple 'failed update should preserve the previous push.default value'
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

  output=$(printf '1\n2\ninput\n11\n' |
    run_tool update 2>&1)

  assert_contains "$output" "Updated profile 'work'." 'update should confirm the selected profile was updated'
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

  output=$(printf '1\n1\n2\ninput\n11\n' |
    run_tool update 2>&1)

  assert_contains "$output" 'GPG Program can only be updated when GPG signing is enabled for the profile.' 'update should explain why gpg.program is unavailable'
  assert_contains "$output" "Updated profile 'work'." 'update should still allow choosing another optional setting'
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

  output=$(printf '1\n3\nfalse\n11\n' |
    run_tool update 2>&1)

  assert_contains "$output" "Updated profile 'work'." 'update should confirm the selected profile was updated'
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

@test "failed update profile write preserves the previous profile and token" {
  local context_file token_file stub_bin real_git output

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  stub_bin="$TMP_HOME/bin"
  real_git="$(command -v git)"

  mkdir -p "$stub_bin" "$PROFILE_DATA_DIR"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true \
    core.editor vim
  printf '%s\n' 'old-token' >"$token_file"
  chmod 600 "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"

  cat >"$stub_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [ "\${1:-}" = config ] && [ "\${2:-}" = -f ] && [[ "\${3:-}" == */.work.gitconfig.tmp.* ]] && [ "\${4:-}" = core.editor ]; then
  exit 23
fi

exec "$real_git" "\$@"
EOF
  chmod +x "$stub_bin/git"

  if output=$(printf '1\n8\nnano\n11\n' | PATH="$stub_bin:$PATH" "$TOOL" update 2>&1); then
    fail 'update should fail when candidate profile writing fails'
  fi

  assert_git_config_file_value "$context_file" core.editor vim 'failed profile write should preserve the previous profile value'
  assert_eq "$(tr -d '\r\n' <"$token_file")" 'old-token' 'failed profile write should preserve the previous token'
  assert_no_profile_temps "$PROFILE_DIR"
  assert_no_token_temps "$PROFILE_DATA_DIR"
}

@test "failed update PAT write rolls back the previous profile and token" {
  local context_file token_file stub_bin real_mv output

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  stub_bin="$TMP_HOME/bin"
  real_mv="$(command -v mv)"

  mkdir -p "$stub_bin" "$PROFILE_DATA_DIR"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true \
    core.editor vim
  printf '%s\n' 'old-token' >"$token_file"
  chmod 600 "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"

  cat >"$stub_bin/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail

for arg in "\$@"; do
  case "\$arg" in
  *'.token.tmp.'*)
    exit 31
    ;;
  esac
done

exec "$real_mv" "\$@"
EOF
  chmod +x "$stub_bin/mv"

  if output=$(printf '1\n8\nnano\n10\n2\nnew-token\n11\n' | PATH="$stub_bin:$PATH" "$TOOL" update 2>&1); then
    fail 'update should fail when PAT publication fails'
  fi

  assert_git_config_file_value "$context_file" core.editor vim 'failed PAT write should roll back the previous profile value'
  assert_eq "$(tr -d '\r\n' <"$token_file")" 'old-token' 'failed PAT write should preserve the previous token'
  assert_not_contains "$output" 'new-token' 'failed PAT write should not print the rejected token'
  assert_no_profile_temps "$PROFILE_DIR"
  assert_no_token_temps "$PROFILE_DATA_DIR"
}

@test "update PAT prompt fails promptly on EOF without changing profile or token" {
  local context_file token_file

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"

  mkdir -p "$PROFILE_DATA_DIR"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true \
    core.editor vim
  printf '%s\n' 'old-token' >"$token_file"
  chmod 600 "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"

  run timeout 5 bash -c "printf '1\\n10\\n2\\n' | \"\$1\" update 2>&1" bash "$TOOL"

  [ "$status" -ne 0 ] || fail 'update should fail when required PAT input reaches EOF'
  [ "$status" -ne 124 ] || fail 'update should fail promptly instead of timing out on EOF'
  assert_contains "$output" 'Error: input ended before required value was provided.' 'update should report required PAT EOF without printing a secret'
  assert_git_config_file_value "$context_file" core.editor vim 'failed PAT prompt should preserve the previous profile value'
  assert_eq "$(tr -d '\r\n' <"$token_file")" 'old-token' 'failed PAT prompt should preserve the previous token'
  assert_no_profile_temps "$PROFILE_DIR"
  assert_no_token_temps "$PROFILE_DATA_DIR"
}

@test "set overwrites managed local git config values" {
  local context_file repo

  context_file="$(context_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DIR"
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
    picotools.sshAddOnStart true \
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
  assert_git_local_value "$repo" picotools.sshAddOnStart true 'set should overwrite the local SSH add-on-start value'
  assert_git_local_value "$repo" core.sshCommand 'ssh -i /tmp/work-key -o IdentitiesOnly=yes' 'set should overwrite the local SSH command'
}

@test "set applies accepted non-boolean Git enum values exactly" {
  local context_file repo

  context_file="$(context_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DIR"
  init_repo "$repo"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf input \
    core.fileMode true \
    pull.rebase merges \
    rebase.autoStash false \
    push.default tracking \
    push.autoSetupRemote false \
    core.editor vim \
    picotools.sshAddOnStart false

  run_set_in_repo "$repo"

  assert_git_local_value "$repo" core.autocrlf input 'set should apply accepted core.autocrlf enum values exactly'
  assert_git_local_value "$repo" pull.rebase merges 'set should apply accepted pull.rebase enum values exactly'
  assert_git_local_value "$repo" push.default tracking 'set should apply accepted push.default enum values exactly'
}

@test "set rejects malformed saved profile without changing local config" {
  local context_file repo output

  context_file="$(context_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DIR"
  init_repo "$repo"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf maybe \
    core.fileMode true \
    pull.rebase false \
    push.default simple

  write_local_git_config_values "$repo" \
    user.name 'Old Name' \
    user.email 'old@example.com' \
    core.autocrlf false \
    core.fileMode false \
    pull.rebase true \
    push.default current \
    picotools.gitProfile old-profile

  if output=$(
    cd "$repo" || return 1
    printf '1\n' | run_tool set 2>&1
  ); then
    fail 'set should reject a malformed saved profile'
  fi

  assert_contains "$output" "invalid value 'maybe' for 'core.autocrlf'" 'set should explain which saved value is malformed'
  assert_git_local_value "$repo" user.name 'Old Name' 'failed set should preserve local user.name'
  assert_git_local_value "$repo" user.email 'old@example.com' 'failed set should preserve local user.email'
  assert_git_local_value "$repo" core.autocrlf false 'failed set should preserve local core.autocrlf'
  assert_git_local_value "$repo" core.fileMode false 'failed set should preserve local core.fileMode'
  assert_git_local_value "$repo" pull.rebase true 'failed set should preserve local pull.rebase'
  assert_git_local_value "$repo" push.default current 'failed set should preserve local push.default'
  assert_git_local_value "$repo" picotools.gitProfile old-profile 'failed set should preserve the repository profile marker'
}

@test "set supports older profiles missing defaulted managed fields" {
  local context_file repo

  context_file="$(context_file_path legacy)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DIR"
  init_repo "$repo"

  write_git_config_values "$context_file" \
    user.name 'Legacy Dev' \
    user.email 'legacy@example.com'

  run_set_in_repo "$repo"

  assert_git_local_value "$repo" user.name 'Legacy Dev' 'set should apply legacy profile user.name'
  assert_git_local_value "$repo" user.email 'legacy@example.com' 'set should apply legacy profile user.email'
  assert_git_local_value "$repo" commit.gpgsign false 'set should default missing commit.gpgsign'
  assert_git_local_value "$repo" tag.gpgsign false 'set should default missing tag.gpgsign'
  assert_git_local_value "$repo" core.autocrlf false 'set should default missing core.autocrlf'
  assert_git_local_value "$repo" core.fileMode true 'set should default missing core.fileMode'
  assert_git_local_value "$repo" pull.rebase false 'set should default missing pull.rebase'
  assert_git_local_value "$repo" rebase.autoStash false 'set should default missing rebase.autoStash'
  assert_git_local_value "$repo" push.default simple 'set should default missing push.default'
  assert_git_local_value "$repo" push.autoSetupRemote false 'set should default missing push.autoSetupRemote'
  assert_git_local_value "$repo" core.editor vim 'set should default missing core.editor'
  assert_git_local_value "$repo" picotools.sshAddOnStart false 'set should default missing picotools.sshAddOnStart'
}

@test "set unsets disabled SSH and GPG values" {
  local context_file repo

  context_file="$(context_file_path personal)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DIR"
  init_repo "$repo"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    picotools.sshAddOnStart false \
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
    picotools.sshAddOnStart true \
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
  assert_git_local_value "$repo" picotools.sshAddOnStart false 'set should still apply the stored SSH add-on-start setting'
  assert_git_local_unset "$repo" core.sshCommand 'set should unset the local SSH command when SSH is disabled'
  assert_git_local_unset "$repo" user.signingkey 'set should unset the local signing key when GPG is disabled'
  assert_git_local_unset "$repo" gpg.program 'set should unset the local gpg program when GPG is disabled'
}

@test "set replaces duplicate local values cleanly" {
  local context_file repo

  context_file="$(context_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DIR"
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

@test "read commands prints ssh-add snippet for saved context" {
  local context_file ssh_key_path output

  context_file="$(context_file_path work)"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"

  mkdir -p "$PROFILE_DIR" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path" "$ssh_key_path.pub"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    picotools.sshAddOnStart true \
    core.autocrlf false \
    core.fileMode true \
    core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes"

  output=$(printf '1\n' | run_tool read --commands)

  assert_contains "$output" "if [ -z \"\${SSH_AUTH_SOCK:-}\" ]; then" 'read --commands should start ssh-agent when needed'
  assert_contains "$output" "eval \"\$(ssh-agent -s)\" >/dev/null" 'read --commands should print the ssh-agent startup command'
  assert_contains "$output" "ssh-add -- $ssh_key_path" 'read --commands should print the ssh-add command'
}

@test "commands prints ssh-add commands for enabled saved contexts" {
  local work_file personal_file work_key_path personal_key_path output

  work_file="$(context_file_path work)"
  personal_file="$(context_file_path personal)"
  work_key_path="$TMP_HOME/.ssh/id_ed25519_work"
  personal_key_path="$TMP_HOME/.ssh/id_ed25519_personal"

  mkdir -p "$PROFILE_DIR" "$(dirname "$work_key_path")"
  touch "$work_key_path" "$personal_key_path"

  write_git_config_values "$work_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    picotools.sshAddOnStart true \
    core.autocrlf false \
    core.fileMode true \
    core.sshCommand "ssh -i $work_key_path -o IdentitiesOnly=yes"

  write_git_config_values "$personal_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    picotools.sshAddOnStart true \
    core.autocrlf false \
    core.fileMode true \
    core.sshCommand "ssh -i $personal_key_path -o IdentitiesOnly=yes"

  output=$(run_tool commands)

  assert_contains "$output" "if [ -z \"\${SSH_AUTH_SOCK:-}\" ]; then" 'commands should start ssh-agent when needed'
  assert_contains "$output" "eval \"\$(ssh-agent -s)\" >/dev/null" 'commands should print the ssh-agent startup command'
  assert_contains "$output" "ssh-add -- $work_key_path" 'commands should print the first enabled ssh-add command'
  assert_contains "$output" "ssh-add -- $personal_key_path" 'commands should print the second enabled ssh-add command'
}

@test "new structured SSH profile preserves special key path across read commands clone and delete" {
  local context_file stub_bin git_log git_ssh_log ssh_key_path public_key output real_git

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  git_log="$TMP_HOME/git.log"
  git_ssh_log="$TMP_HOME/git-ssh.log"
  ssh_key_path="$TMP_HOME/.ssh/-work key \$odd;name"
  public_key='ssh-ed25519 AAAASTRUCTURED jane@example.com'

  mkdir -p "$PROFILE_DIR" "$stub_bin" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"
  printf '%s\n' "$public_key" >"$ssh_key_path.pub"

  printf 'work\nJane Dev\njane@example.com\nyes\n%s\nyes\nno\n\n' "$ssh_key_path" |
    run_tool create >/dev/null 2>&1

  assert_git_config_file_value "$context_file" picotools.sshKeyPath "$ssh_key_path" 'create should persist the structured SSH key path exactly'
  assert_git_config_file_value "$context_file" core.sshCommand "$(printf 'ssh -i %q -o IdentitiesOnly=yes' "$ssh_key_path")" 'create should derive the managed SSH command from the structured path'

  output=$(printf '1\nyes\n' | run_tool read 2>&1)
  assert_contains "$output" "$ssh_key_path" 'read should display the structured SSH key path'
  assert_contains "$output" "Public SSH Key ($ssh_key_path.pub):" 'read should use the structured key path for public key display'
  assert_contains "$output" "$public_key" 'read should display the matching public key contents'

  output=$(printf '1\n' | run_tool read --commands)
  assert_contains "$output" "$(printf 'ssh-add -- %q' "$ssh_key_path")" 'read --commands should shell-quote the structured key path after an option terminator'

  output=$(run_tool commands)
  assert_contains "$output" "$(printf 'ssh-add -- %q' "$ssh_key_path")" 'commands should use the same structured key path'

  real_git="$(command -v git)"
  cat >"$stub_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$@" >> "$git_log"
printf '%s\n' "\${GIT_SSH_COMMAND:-}" >> "$git_ssh_log"
if [ "\$1" = "config" ]; then exec "$real_git" "\$@"; fi
mkdir -p "picotools"
EOF
  chmod +x "$stub_bin/git"

  output=$(PATH="$stub_bin:$PATH" "$TOOL" clone work "git@github.com:egose/picotools.git" 2>&1)
  assert_contains "$output" "Cloned 'git@github.com:egose/picotools.git' using profile 'work'." 'clone should complete with the structured profile'
  assert_contains "$(<"$git_ssh_log")" "$(printf 'ssh -i %q -o IdentitiesOnly=yes' "$ssh_key_path")" 'clone should derive GIT_SSH_COMMAND from the structured key path'

  output=$(printf '1\ny\ny\n' | run_tool delete 2>&1)
  assert_contains "$output" 'Deleted profile.' 'delete should complete with an option-like structured SSH key path'
  assert_file_not_exists "$context_file" 'delete should remove the structured profile file'
  assert_file_not_exists "$ssh_key_path" 'delete should remove the structured private key path as an operand'
  assert_file_not_exists "$ssh_key_path.pub" 'delete should remove the structured public key path as an operand'
}

@test "legacy SSH command profile preserves escaped special key path across surfaces" {
  local context_file stub_bin git_log git_ssh_log ssh_key_path public_key output real_git

  context_file="$(context_file_path legacy)"
  stub_bin="$TMP_HOME/bin"
  git_log="$TMP_HOME/git.log"
  git_ssh_log="$TMP_HOME/git-ssh.log"
  ssh_key_path="$TMP_HOME/.ssh/-legacy key \$odd;name"
  public_key='ssh-ed25519 AAAALEGACY jane@example.com'

  mkdir -p "$PROFILE_DIR" "$stub_bin" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"
  printf '%s\n' "$public_key" >"$ssh_key_path.pub"
  write_git_config_values "$context_file" \
    user.name 'Legacy Dev' \
    user.email 'legacy@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    picotools.sshAddOnStart true \
    core.autocrlf false \
    core.fileMode true \
    core.sshCommand "$(printf 'ssh -i %q -o IdentitiesOnly=yes' "$ssh_key_path")"

  output=$(printf '1\nyes\n' | run_tool read 2>&1)
  assert_contains "$output" "$ssh_key_path" 'read should decode a legacy generated SSH command key path'
  assert_contains "$output" "Public SSH Key ($ssh_key_path.pub):" 'read should use the legacy decoded key path for public key display'
  assert_contains "$output" "$public_key" 'read should display the legacy public key contents'

  output=$(printf '1\n' | run_tool read --commands)
  assert_contains "$output" "$(printf 'ssh-add -- %q' "$ssh_key_path")" 'read --commands should use the legacy decoded key path safely'

  output=$(run_tool commands)
  assert_contains "$output" "$(printf 'ssh-add -- %q' "$ssh_key_path")" 'commands should use the legacy decoded key path safely'

  real_git="$(command -v git)"
  cat >"$stub_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$@" >> "$git_log"
printf '%s\n' "\${GIT_SSH_COMMAND:-}" >> "$git_ssh_log"
if [ "\$1" = "config" ]; then exec "$real_git" "\$@"; fi
mkdir -p "picotools"
EOF
  chmod +x "$stub_bin/git"

  output=$(PATH="$stub_bin:$PATH" "$TOOL" clone legacy "git@github.com:egose/picotools.git" 2>&1)
  assert_contains "$output" "Cloned 'git@github.com:egose/picotools.git' using profile 'legacy'." 'clone should complete with a legacy profile'
  assert_contains "$(<"$git_ssh_log")" "$(printf 'ssh -i %q -o IdentitiesOnly=yes' "$ssh_key_path")" 'clone should rebuild GIT_SSH_COMMAND from the legacy decoded key path'

  output=$(printf '1\ny\ny\n' | run_tool delete 2>&1)
  assert_contains "$output" 'Deleted profile.' 'delete should complete with an option-like legacy SSH key path'
  assert_file_not_exists "$context_file" 'delete should remove the legacy profile file'
  assert_file_not_exists "$ssh_key_path" 'delete should remove the legacy private key path as an operand'
  assert_file_not_exists "$ssh_key_path.pub" 'delete should remove the legacy public key path as an operand'
}

@test "set fails outside git repository" {
  local context_file outside_dir

  context_file="$(context_file_path work)"
  outside_dir="$TMP_HOME/outside"

  mkdir -p "$PROFILE_DIR" "$outside_dir"
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

@test "help lists the clone command" {
  local output

  output=$(run_tool --help)
  assert_contains "$output" 'clone [<profile> <url>]' 'help should list the clone command grammar'
}

@test "clone with SSH profile uses the profile key" {
  local context_file stub_bin git_log git_ssh_log ssh_key_path

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  git_log="$TMP_HOME/git.log"
  git_ssh_log="$TMP_HOME/git-ssh.log"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"

  mkdir -p "$PROFILE_DIR" "$stub_bin" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true \
    core.sshCommand "$(printf 'ssh -i %q -o IdentitiesOnly=yes' "$ssh_key_path")"

  real_git="$(command -v git)"

  cat >"$stub_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$@" >> "$git_log"
printf '%s\n' "\${GIT_SSH_COMMAND:-}" >> "$git_ssh_log"
if [ "\$1" = "config" ]; then exec "$real_git" "\$@"; fi
mkdir -p "picotools"
EOF
  chmod +x "$stub_bin/git"

  output=$(PATH="$stub_bin:$PATH" \
    GIT_LOG="$git_log" \
    GIT_SSH_LOG="$git_ssh_log" \
    "$TOOL" clone work "git@github.com:egose/picotools.git" 2>&1)

  assert_contains "$output" "Cloned 'git@github.com:egose/picotools.git' using profile 'work'." 'clone should confirm success'
  assert_contains "$(<"$git_log")" 'clone' 'clone should invoke git clone'
  assert_contains "$(<"$git_log")" 'git@github.com:egose/picotools.git' 'clone should pass the URL to git'
  assert_contains "$(<"$git_log")" '--config' 'clone with SSH should pass --config through git clone'
  assert_contains "$(<"$git_log")" 'picotools.gitProfile=work' 'clone with SSH should pass the marker as one --config value'
  assert_contains "$(<"$git_ssh_log")" "ssh -i $ssh_key_path -o IdentitiesOnly=yes" 'clone should set GIT_SSH_COMMAND with the profile key'
}

@test "clone with SSH profile preserves spaces in the key path" {
  local stub_bin ssh_log ssh_key_path output

  stub_bin="$TMP_HOME/bin"
  ssh_log="$TMP_HOME/ssh.log"
  ssh_key_path="$TMP_HOME/.ssh/work key"

  mkdir -p "$PROFILE_DIR" "$stub_bin" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"

  printf 'work\nJane Dev\njane@example.com\nyes\n%s\nno\nno\n\n' "$ssh_key_path" |
    run_tool create >/dev/null 2>&1

  cat >"$stub_bin/ssh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$@" > "$ssh_log"
exit 1
EOF
  chmod +x "$stub_bin/ssh"

  if output=$(PATH="$stub_bin:$PATH" "$TOOL" clone work "git@github.com:egose/picotools.git" 2>&1); then
    fail 'clone should fail because the SSH command is stubbed to exit non-zero'
  fi

  assert_eq "$(sed -n '1p' "$ssh_log")" '-i' 'clone should pass -i to ssh'
  assert_eq "$(sed -n '2p' "$ssh_log")" "$ssh_key_path" 'clone should preserve the spaced SSH key path as one ssh argument'
}

@test "clone without SSH profile runs plain git clone" {
  local context_file stub_bin git_log git_ssh_log

  context_file="$(context_file_path personal)"
  stub_bin="$TMP_HOME/bin"
  git_log="$TMP_HOME/git.log"
  git_ssh_log="$TMP_HOME/git-ssh.log"

  mkdir -p "$PROFILE_DIR" "$stub_bin"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  real_git="$(command -v git)"

  cat >"$stub_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$@" >> "$git_log"
printf '%s\n' "\${GIT_SSH_COMMAND:-}" >> "$git_ssh_log"
if [ "\$1" = "config" ]; then exec "$real_git" "\$@"; fi
mkdir -p "picotools"
EOF
  chmod +x "$stub_bin/git"

  output=$(PATH="$stub_bin:$PATH" \
    GIT_LOG="$git_log" \
    GIT_SSH_LOG="$git_ssh_log" \
    "$TOOL" clone personal "git@github.com:egose/picotools.git" 2>&1)

  assert_contains "$output" "Cloned 'git@github.com:egose/picotools.git' using profile 'personal'." 'clone should confirm success'
  assert_contains "$(<"$git_log")" 'clone' 'clone should invoke git clone'
  assert_contains "$(<"$git_log")" 'git@github.com:egose/picotools.git' 'clone should pass the URL to git'
  assert_contains "$(<"$git_log")" '--config' 'clone without SSH should pass --config through git clone'
  assert_contains "$(<"$git_log")" 'picotools.gitProfile=personal' 'clone without SSH should pass the marker as one --config value'
  assert_eq "$(<"$git_ssh_log")" '' 'clone should not set GIT_SSH_COMMAND when SSH is disabled'
}

@test "clone separates dash-leading URL operands from git options" {
  local context_file stub_bin git_log output real_git

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  git_log="$TMP_HOME/git.log"

  mkdir -p "$PROFILE_DIR" "$stub_bin"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  real_git="$(command -v git)"
  cat >"$stub_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$@" > "$git_log"
if [ "\$1" = "config" ]; then exec "$real_git" "\$@"; fi
mkdir -p "picotools"
EOF
  chmod +x "$stub_bin/git"

  output=$(PATH="$stub_bin:$PATH" "$TOOL" clone work '-ssh://example.invalid/repo.git' 2>&1)

  assert_contains "$output" "Cloned '-ssh://example.invalid/repo.git' using profile 'work'." 'clone should accept a dash-leading URL as an operand'
  assert_eq "$(sed -n '1p' "$git_log")" 'clone' 'clone should invoke git clone'
  assert_eq "$(sed -n '2p' "$git_log")" '--config' 'clone should pass --config before the marker value'
  assert_eq "$(sed -n '3p' "$git_log")" 'picotools.gitProfile=work' 'clone should pass the marker value as one argument'
  assert_eq "$(sed -n '4p' "$git_log")" '--' 'clone should terminate git option parsing before the URL'
  assert_eq "$(sed -n '5p' "$git_log")" '-ssh://example.invalid/repo.git' 'clone should pass the dash-leading URL as one operand'
}

@test "clone fails with missing profile" {
  local output

  if output=$("$TOOL" clone nonexistent "git@github.com:egose/picotools.git" 2>&1); then
    fail 'clone should fail with a non-zero exit status for missing profile'
  fi

  assert_contains "$output" "Error: profile not found 'nonexistent'" 'clone should report the missing profile'
}

@test "clone fails with missing URL" {
  local output context_file

  context_file="$(context_file_path personal)"
  mkdir -p "$PROFILE_DIR"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  if output=$(printf '\n' | "$TOOL" clone personal 2>&1); then
    fail 'clone should fail with a non-zero exit status when URL is missing'
  fi

  assert_contains "$output" 'Error: git URL is required' 'clone should report that URL is required'
}

@test "set writes the repository profile marker" {
  local context_file repo

  context_file="$(context_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DIR"
  init_repo "$repo"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  run_set_in_repo "$repo"

  assert_git_local_value "$repo" picotools.gitProfile work 'set should persist the active profile name'
  assert_git_local_all_values "$repo" picotools.gitProfile work 'set should persist exactly one marker value'
}

@test "set replaces stale repository profile marker values" {
  local work_file personal_file repo

  work_file="$(context_file_path work)"
  personal_file="$(context_file_path personal)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DIR"
  init_repo "$repo"

  write_git_config_values "$work_file" \
    user.name 'Jane Work' \
    user.email 'jane@work.example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  write_git_config_values "$personal_file" \
    user.name 'Jane Personal' \
    user.email 'jane@personal.example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  append_local_git_config_values "$repo" \
    picotools.gitProfile stale-one \
    picotools.gitProfile stale-two

  (
    cd "$repo" || return 1
    printf '1\n' | run_tool set >/dev/null 2>&1
    printf '2\n' | run_tool set >/dev/null 2>&1
  )

  assert_git_local_value "$repo" picotools.gitProfile work 'set should overwrite stale marker values with the latest selection'
  assert_git_local_all_values "$repo" picotools.gitProfile work 'set should leave exactly one marker value after switching profiles'
}

@test "clone with SSH profile persists the marker via git clone --config" {
  local context_file stub_bin git_log ssh_key_path

  context_file="$(context_file_path work)"
  stub_bin="$TMP_HOME/bin"
  git_log="$TMP_HOME/git.log"
  ssh_key_path="$TMP_HOME/.ssh/id_ed25519_work"

  mkdir -p "$PROFILE_DIR" "$stub_bin" "$(dirname "$ssh_key_path")"
  touch "$ssh_key_path"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true \
    core.sshCommand "ssh -i $ssh_key_path -o IdentitiesOnly=yes"

  real_git="$(command -v git)"

  cat >"$stub_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$@" >> "$git_log"
if [ "\$1" = "config" ]; then exec "$real_git" "\$@"; fi
mkdir -p "picotools"
EOF
  chmod +x "$stub_bin/git"

  output=$(PATH="$stub_bin:$PATH" GIT_LOG="$git_log" \
    "$TOOL" clone work "git@github.com:egose/picotools.git" 2>&1)

  assert_contains "$(<"$git_log")" '--config' \
    'clone with SSH should pass --config through git clone'
  assert_contains "$(<"$git_log")" 'picotools.gitProfile=work' \
    'clone with SSH should pass the profile marker as one --config value'
}

@test "clone without SSH profile persists the marker via git clone --config" {
  local context_file stub_bin git_log

  context_file="$(context_file_path personal)"
  stub_bin="$TMP_HOME/bin"
  git_log="$TMP_HOME/git.log"

  mkdir -p "$PROFILE_DIR" "$stub_bin"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  real_git="$(command -v git)"

  cat >"$stub_bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "\$@" >> "$git_log"
if [ "\$1" = "config" ]; then exec "$real_git" "\$@"; fi
mkdir -p "picotools"
EOF
  chmod +x "$stub_bin/git"

  output=$(PATH="$stub_bin:$PATH" GIT_LOG="$git_log" \
    "$TOOL" clone personal "git@github.com:egose/picotools.git" 2>&1)

  assert_contains "$(<"$git_log")" '--config' \
    'clone without SSH should pass --config through git clone'
  assert_contains "$(<"$git_log")" 'picotools.gitProfile=personal' \
    'clone without SSH should pass the profile marker as one --config value'
}

@test "clone persists the marker inside the cloned repository" {
  local context_file remote_repo clone_parent clone_dir

  context_file="$(context_file_path work)"
  remote_repo="$TMP_HOME/remote.git"
  clone_parent="$TMP_HOME/clones"

  mkdir -p "$PROFILE_DIR" "$clone_parent"
  git init -q --bare "$remote_repo"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  (
    cd "$clone_parent" || return 1
    run_tool clone work "$remote_repo" >/dev/null 2>&1
  )

  clone_dir="$clone_parent/remote"
  assert_git_local_value "$clone_dir" picotools.gitProfile work 'clone should write the profile marker into the cloned repository local config'
  assert_git_local_all_values "$clone_dir" picotools.gitProfile work 'clone should persist exactly one marker value in the cloned repository'
}

@test "create stores PAT in XDG data and does not leak it through config or summaries" {
  local context_file token_file repo output debug_output
  local token='ghp_profile_secret_sentinel'

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  repo="$TMP_HOME/repo"

  init_repo "$repo"

  printf 'work\nJane Dev\njane@example.com\nno\nno\n%s\n' "$token" |
    run_tool create >/dev/null 2>&1

  assert_file_exists "$token_file" 'create should store the PAT in the profile data directory'
  assert_eq "$(tr -d '\r\n' <"$token_file")" "$token" 'create should store the exact PAT bytes in the token file'
  assert_not_contains "$(<"$context_file")" "$token" 'create should not write the PAT into the saved profile config'

  (
    cd "$repo" || return 1
    printf '1\n' | run_tool set >/dev/null 2>&1
  )

  assert_not_contains "$(<"$repo/.git/config")" "$token" 'set should not write the PAT into repository local git config'

  output=$(run_tool list)
  assert_contains "$output" '| PAT' 'list should include a PAT status column'
  assert_contains "$output" ' yes ' 'list should show that the profile PAT is configured'
  assert_not_contains "$output" "$token" 'list should not print the PAT value'

  output=$(printf '1\nno\n' | run_tool read 2>&1)
  assert_contains "$output" '| PAT ' 'read should show the PAT status field'
  assert_contains "$output" 'yes' 'read should show that the PAT is configured'
  assert_not_contains "$output" "$token" 'read should not print the PAT value'

  debug_output=$(run_tool --debug list 2>&1)
  assert_not_contains "$debug_output" "$token" 'debug list output should not print the PAT value'
}

@test "create without PAT leaves no token file and blank overwrite removes stale PAT" {
  local token_file

  token_file="$(token_file_path work)"

  printf 'work\nJane Dev\njane@example.com\nno\nno\nold-token\n' |
    run_tool create >/dev/null 2>&1
  assert_file_exists "$token_file" 'create should store the initial token file when a PAT is provided'

  printf 'work\nyes\nJane Dev\njane@example.com\nno\nno\n\n' |
    run_tool create >/dev/null 2>&1

  assert_file_not_exists "$token_file" 'overwriting with a blank PAT should remove the stale token file'
}

@test "create repairs permissive PAT directory and file modes" {
  local token_file

  token_file="$(token_file_path work)"

  mkdir -p "$PROFILE_DATA_DIR"
  chmod 755 "$PROFILE_DATA_DIR"
  printf '%s\n' 'old-token' >"$token_file"
  chmod 644 "$token_file"

  printf 'work\nJane Dev\njane@example.com\nno\nno\nnew-token\n' |
    run_tool create >/dev/null 2>&1

  assert_mode "$PROFILE_DATA_DIR" 700 'create should enforce mode 0700 on the PAT directory'
  assert_mode "$token_file" 600 'create should enforce mode 0600 on the PAT file'
}

@test "update supports add keep replace and remove PAT actions without exposing the value" {
  local context_file token_file output
  local first_token='ghp_first_update_token'
  local second_token='ghp_second_update_token'

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  output=$(printf '1\n10\n2\n%s\n11\n' "$first_token" | run_tool update 2>&1)
  assert_eq "$(tr -d '\r\n' <"$token_file")" "$first_token" 'update should add a PAT when requested'
  assert_not_contains "$output" "$first_token" 'update should not print an added PAT'

  output=$(printf '1\n10\n1\n11\n' | run_tool update 2>&1)
  assert_eq "$(tr -d '\r\n' <"$token_file")" "$first_token" 'update should keep the PAT when requested'
  assert_not_contains "$output" "$first_token" 'update should not print a kept PAT'

  output=$(printf '1\n10\n2\n%s\n11\n' "$second_token" | run_tool update 2>&1)
  assert_eq "$(tr -d '\r\n' <"$token_file")" "$second_token" 'update should replace the PAT when requested'
  assert_not_contains "$output" "$first_token" 'update should not print the old PAT during replacement'
  assert_not_contains "$output" "$second_token" 'update should not print the replacement PAT'

  output=$(printf '1\n10\n3\n11\n' | run_tool update 2>&1)
  assert_file_not_exists "$token_file" 'update should remove the PAT when requested'
  assert_not_contains "$output" "$second_token" 'update should not print the removed PAT'
}

@test "token prints the active repository profile PAT from the local marker only" {
  local work_file personal_file work_token_file personal_token_file repo output

  work_file="$(context_file_path work)"
  personal_file="$(context_file_path personal)"
  work_token_file="$(token_file_path work)"
  personal_token_file="$(token_file_path personal)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DATA_DIR"
  init_repo "$repo"

  write_git_config_values "$work_file" \
    user.name 'Jane Dev' \
    user.email 'shared@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  write_git_config_values "$personal_file" \
    user.name 'Jane Dev' \
    user.email 'shared@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true

  printf '%s\n' 'work-token' >"$work_token_file"
  printf '%s\n' 'personal-token' >"$personal_token_file"
  chmod 600 "$work_token_file" "$personal_token_file"
  chmod 700 "$PROFILE_DATA_DIR"

  git config --global picotools.gitProfile personal
  git -C "$repo" config --local picotools.gitProfile work

  output=$(bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" --)

  assert_eq "$output" 'work-token' 'token should print only the active repository profile PAT'
}

@test "token rejects extra arguments before printing the active PAT" {
  local context_file token_file repo output
  local token='ghp_token_extra_secret_sentinel'

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DATA_DIR"
  init_repo "$repo"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true
  printf '%s\n' "$token" >"$token_file"
  chmod 600 "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"
  git -C "$repo" config --local picotools.gitProfile work

  if output=$(
    cd "$repo" || return 1
    HOME="$TMP_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" "$TOOL" token --help unexpected 2>&1
  ); then
    fail 'token should reject extra arguments before printing a PAT'
  fi

  assert_contains "$output" 'Error: token does not accept arguments: --help' 'token should reject extra arguments before reading the repository profile'
  assert_not_contains "$output" "$token" 'token should not print the PAT when its arguments are invalid'
}

@test "token fails outside a git repository" {
  assert_command_fails \
    'Error: token must be run inside a Git repository' \
    bash -c "cd \"$TMP_HOME\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" \
    --
}

@test "token fails when the repository marker is missing" {
  local repo

  repo="$TMP_HOME/repo"
  init_repo "$repo"

  assert_command_fails \
    'Error: no git profile is recorded in this repository' \
    bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" \
    --
}

@test "token fails when the repository profile no longer exists" {
  local repo

  repo="$TMP_HOME/repo"
  init_repo "$repo"
  git -C "$repo" config --local picotools.gitProfile missing

  assert_command_fails \
    "Error: repository git profile 'missing' does not exist" \
    bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" \
    --
}

@test "token fails when the active repository profile has no PAT" {
  local context_file repo

  context_file="$(context_file_path work)"
  repo="$TMP_HOME/repo"

  init_repo "$repo"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true
  git -C "$repo" config --local picotools.gitProfile work

  assert_command_fails \
    "Error: PAT not configured for profile 'work'" \
    bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" \
    --
}

@test "blank PAT files are treated as not configured" {
  local context_file token_file repo output

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  repo="$TMP_HOME/repo"

  mkdir -p "$PROFILE_DATA_DIR"
  init_repo "$repo"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true
  : >"$token_file"
  chmod 600 "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"
  git -C "$repo" config --local picotools.gitProfile work

  if output=$(bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" -- 2>&1); then
    fail 'token should fail when the PAT file is blank'
  fi

  assert_contains "$output" "Error: PAT not configured for profile 'work'" 'blank PAT files should be treated the same as a missing PAT'

  output=$(printf '1\nno\n' | run_tool read 2>&1)
  assert_contains "$output" '| PAT ' 'read should show the PAT status field'
  assert_contains "$output" ' no ' 'read should show a blank PAT file as not configured'
}

@test "create rejects a symlink token path on write without changing its target" {
  local context_file token_file target ssh_key_path output
  local token='ghp_symlink_write_token'

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  target="$TMP_HOME/outside-write.token"
  ssh_key_path="$TMP_HOME/existing-ssh-key"

  mkdir -p "$PROFILE_DATA_DIR"
  touch "$ssh_key_path"
  printf '%s\n' 'original-write-target' >"$target"
  ln -s "$target" "$token_file"

  if output=$(printf 'work\nJane Dev\njane@example.com\nyes\n%s\nno\nno\n%s\n' "$ssh_key_path" "$token" | run_tool create 2>&1); then
    fail 'create should fail when the PAT token path is a symlink'
  fi

  assert_contains "$output" "refusing to write PAT for profile 'work'" 'create should explain why the symlink token path was rejected'
  assert_file_not_exists "$context_file" 'failed create should not leave a new profile file'
  assert_file_exists "$ssh_key_path" 'failed create should not delete user-supplied SSH key material'
  assert_eq "$(<"$target")" 'original-write-target' 'create should not modify the symlink target when rejecting a PAT write'
  assert_not_contains "$output" "$token" 'create failure output should not print the rejected PAT'
}

@test "token rejects a symlink token path on read without printing the PAT" {
  local context_file token_file target repo output
  local token='ghp_symlink_read_token'

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  target="$TMP_HOME/outside-read.token"
  repo="$TMP_HOME/repo"

  init_repo "$repo"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true
  mkdir -p "$PROFILE_DATA_DIR"
  printf '%s\n' "$token" >"$target"
  ln -s "$target" "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"
  git -C "$repo" config --local picotools.gitProfile work

  if output=$(bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" -- 2>&1); then
    fail 'token should fail when the PAT token path is a symlink'
  fi

  assert_contains "$output" "refusing to read PAT for profile 'work'" 'token should explain why the symlink token path was rejected'
  assert_eq "$(<"$target")" "$token" 'token should not modify the symlink target when rejecting a PAT read'
  assert_not_contains "$output" "$token" 'token failure output should not print the PAT value'
}

@test "delete rejects a symlink token path without changing its target" {
  local context_file token_file target output
  local token='ghp_symlink_delete_token'

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  target="$TMP_HOME/outside-delete.token"

  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true
  mkdir -p "$PROFILE_DATA_DIR"
  printf '%s\n' "$token" >"$target"
  ln -s "$target" "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"

  if output=$(printf '1\ny\n' | run_tool delete 2>&1); then
    fail 'delete should fail when the PAT token path is a symlink'
  fi

  assert_contains "$output" "refusing to delete PAT for profile 'work'" 'delete should explain why the symlink token path was rejected'
  assert_file_exists "$context_file" 'delete should leave the profile file in place when PAT deletion is unsafe'
  assert_eq "$(<"$target")" "$token" 'delete should not modify the symlink target when rejecting PAT deletion'
  assert_not_contains "$output" "$token" 'delete failure output should not print the PAT value'
}

@test "symlinked PAT data directory is rejected for status read write update and delete" {
  local context_file outside_dir outside_token repo output
  local token='ghp_data_dir_symlink_token'

  context_file="$(context_file_path work)"
  outside_dir="$TMP_HOME/outside-data"
  outside_token="$outside_dir/work.token"
  repo="$TMP_HOME/repo"

  init_repo "$repo"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true
  mkdir -p "$outside_dir" "$(dirname "$PROFILE_DATA_DIR")"
  printf '%s\n' "$token" >"$outside_token"
  chmod 600 "$outside_token"
  chmod 700 "$outside_dir"
  ln -s "$outside_dir" "$PROFILE_DATA_DIR"
  git -C "$repo" config --local picotools.gitProfile work

  if output=$(run_tool list 2>&1); then
    fail 'list should fail closed when the PAT data directory is a symlink'
  fi
  assert_contains "$output" 'data directory is a symbolic link' 'list should explain why PAT status is unavailable'
  assert_not_contains "$output" "$token" 'list should not print a PAT from the symlink target'

  if output=$(printf '1\nno\n' | run_tool read 2>&1); then
    fail 'read should fail closed when the PAT data directory is a symlink'
  fi
  assert_contains "$output" 'data directory is a symbolic link' 'read should explain why PAT status is unavailable'
  assert_not_contains "$output" "$token" 'read should not print a PAT from the symlink target'

  if output=$(bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" -- 2>&1); then
    fail 'token should fail closed when the PAT data directory is a symlink'
  fi
  assert_contains "$output" 'data directory is a symbolic link' 'token should explain why PAT read is unavailable'
  assert_not_contains "$output" "$token" 'token should not print a PAT from the symlink target'

  if output=$(printf 'new\nJane Dev\njane@example.com\nno\nno\nnew-token\n' | run_tool create 2>&1); then
    fail 'create should fail closed when the PAT data directory is a symlink'
  fi
  assert_contains "$output" 'data directory is a symbolic link' 'create should explain why PAT write is unavailable'
  assert_file_not_exists "$outside_dir/new.token" 'create should not write into the symlink target directory'
  assert_not_contains "$output" 'new-token' 'create should not print the rejected PAT'

  if output=$(printf '1\n10\n2\nreplacement-token\n11\n' | run_tool update 2>&1); then
    fail 'update should fail closed when the PAT data directory is a symlink'
  fi
  assert_contains "$output" 'data directory is a symbolic link' 'update should explain why PAT status is unavailable'
  assert_eq "$(<"$outside_token")" "$token" 'update should not modify a token through the symlinked data directory'
  assert_not_contains "$output" 'replacement-token' 'update should not print the rejected PAT'

  if output=$(printf '1\ny\n' | run_tool delete 2>&1); then
    fail 'delete should fail closed when the PAT data directory is a symlink'
  fi
  assert_contains "$output" 'data directory is a symbolic link' 'delete should explain why PAT deletion is unavailable'
  assert_file_exists "$context_file" 'delete should leave the profile file in place when PAT deletion is unsafe'
  assert_eq "$(<"$outside_token")" "$token" 'delete should not remove a token through the symlinked data directory'
  assert_not_contains "$output" "$token" 'delete should not print the PAT value'
}

@test "replacing a hard-linked PAT atomically leaves the other link unchanged" {
  local token_file other_link

  token_file="$(token_file_path work)"
  other_link="$TMP_HOME/other-link.token"

  mkdir -p "$PROFILE_DATA_DIR"
  printf '%s\n' 'old-token' >"$token_file"
  chmod 600 "$token_file"
  ln "$token_file" "$other_link"

  printf 'work\nJane Dev\njane@example.com\nno\nno\nnew-token\n' |
    run_tool create >/dev/null 2>&1

  assert_eq "$(tr -d '\r\n' <"$token_file")" 'new-token' 'create should publish the replacement PAT at the token path'
  assert_eq "$(tr -d '\r\n' <"$other_link")" 'old-token' 'create should not overwrite another hard link to the old token file'
  assert_mode "$token_file" 600 'replacement token should keep mode 0600'
  assert_no_token_temps "$PROFILE_DATA_DIR"
}

@test "create rejects FIFO token destinations without blocking or writing the PAT" {
  local token_file output

  token_file="$(token_file_path work)"
  mkdir -p "$PROFILE_DATA_DIR"
  mkfifo "$token_file"

  if output=$(printf 'work\nJane Dev\njane@example.com\nno\nno\nfifo-token\n' | timeout 5 "$TOOL" create 2>&1); then
    fail 'create should fail when the PAT token path is a FIFO'
  fi

  assert_contains "$output" 'token path is not a regular file' 'create should explain why the FIFO token path was rejected'
  assert_not_contains "$output" 'fifo-token' 'create should not print the rejected PAT'
  [ -p "$token_file" ] || fail 'create should leave the FIFO in place after rejecting it'
  assert_no_token_temps "$PROFILE_DATA_DIR"
}

@test "PAT status and token reads fail closed for permissive modes" {
  local context_file token_file repo output
  local token='mode-token'

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  repo="$TMP_HOME/repo"

  init_repo "$repo"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true
  mkdir -p "$PROFILE_DATA_DIR"
  printf '%s\n' "$token" >"$token_file"
  chmod 600 "$token_file"
  chmod 755 "$PROFILE_DATA_DIR"
  git -C "$repo" config --local picotools.gitProfile work

  if output=$(run_tool list 2>&1); then
    fail 'list should fail closed when the PAT data directory is too permissive'
  fi
  assert_contains "$output" 'data directory must be mode 0700' 'list should explain the PAT data directory mode policy'
  assert_not_contains "$output" "$token" 'list should not print the PAT value'

  chmod 700 "$PROFILE_DATA_DIR"
  chmod 644 "$token_file"

  if output=$(bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" -- 2>&1); then
    fail 'token should fail closed when the PAT file is too permissive'
  fi
  assert_contains "$output" 'token file must be mode 0600' 'token should explain the PAT file mode policy'
  assert_not_contains "$output" "$token" 'token should not print the PAT value'

  if output=$(printf '1\n10\n1\n11\n' | run_tool update 2>&1); then
    fail 'update should fail closed when PAT status sees a permissive token file'
  fi
  assert_contains "$output" 'token file must be mode 0600' 'update should explain the PAT file mode policy'

  if output=$(printf '1\ny\n' | run_tool delete 2>&1); then
    fail 'delete should fail closed when the PAT file is too permissive'
  fi
  assert_contains "$output" 'token file must be mode 0600' 'delete should explain the PAT file mode policy'
  assert_file_exists "$context_file" 'delete should leave the profile file in place when PAT deletion is unsafe'
  assert_eq "$(tr -d '\r\n' <"$token_file")" "$token" 'delete should leave the permissive token file unchanged'
}

@test "multiline PAT files are rejected without concatenating token bytes" {
  local context_file token_file repo output

  context_file="$(context_file_path work)"
  token_file="$(token_file_path work)"
  repo="$TMP_HOME/repo"

  init_repo "$repo"
  write_git_config_values "$context_file" \
    user.name 'Jane Dev' \
    user.email 'jane@example.com' \
    commit.gpgsign false \
    tag.gpgsign false \
    core.autocrlf false \
    core.fileMode true
  mkdir -p "$PROFILE_DATA_DIR"
  printf '%s\n%s\n' 'line-one-token' 'line-two-token' >"$token_file"
  chmod 600 "$token_file"
  chmod 700 "$PROFILE_DATA_DIR"
  git -C "$repo" config --local picotools.gitProfile work

  if output=$(bash -c "cd \"$repo\" && HOME=\"$TMP_HOME\" XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\" XDG_DATA_HOME=\"$XDG_DATA_HOME\" \"$TOOL\" token" -- 2>&1); then
    fail 'token should fail when the PAT file contains multiple lines'
  fi

  assert_contains "$output" 'token file must contain exactly one line' 'token should explain that multiline PAT files are malformed'
  assert_not_contains "$output" 'line-one-token' 'token should not print the first PAT line'
  assert_not_contains "$output" 'line-two-token' 'token should not print the second PAT line'
}
