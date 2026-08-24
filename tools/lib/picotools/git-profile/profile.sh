#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_PROFILE_PROFILE_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_PROFILE_PROFILE_SH_LOADED=1

default_pull_rebase() {
  printf '%s\n' false
}

default_rebase_autostash() {
  printf '%s\n' false
}

default_push_default() {
  printf '%s\n' simple
}

default_push_autosetupremote() {
  printf '%s\n' false
}

default_core_editor() {
  printf '%s\n' vim
}

default_ssh_add_on_start() {
  printf '%s\n' false
}

default_gpg_program() {
  printf '%s\n' gpg
}

context_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/git-profile"
}

data_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/git-profile"
}

validate_context_name() {
  local name="$1"

  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: profile name must match [A-Za-z0-9._-]+" >&2
    exit 1
  fi
}

context_file() {
  local name="$1"
  printf '%s/%s.gitconfig\n' "$(context_dir)" "$name"
}

context_name_from_file() {
  local file="$1"

  basename "$file" .gitconfig
}

ensure_context_dir() {
  mkdir -p "$(context_dir)"
}

write_context_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  picotools_git_config_set "$file" "$key" "$value"
}

read_context_value() {
  local file="$1"
  local key="$2"

  picotools_git_config_get "$file" "$key"
}

read_context_value_optional() {
  local file="$1"
  local key="$2"

  picotools_git_config_get_optional "$file" "$key"
}

read_context_value_presence() {
  local file="$1"
  local key="$2"
  local value_var="$3"
  local present_var="$4"
  local config_value config_status=0

  config_value=$(git config -f "$file" --get "$key" 2>/dev/null) || config_status=$?
  case "$config_status" in
  0)
    printf -v "$value_var" '%s' "$config_value"
    printf -v "$present_var" '%s' yes
    ;;
  1)
    printf -v "$value_var" '%s' ''
    printf -v "$present_var" '%s' no
    ;;
  *)
    return "$config_status"
    ;;
  esac
}

read_profile_required_value() {
  local file="$1"
  local key="$2"
  local value_var="$3"
  local value present

  if ! read_context_value_presence "$file" "$key" value present; then
    return 1
  fi
  if [ "$present" != 'yes' ]; then
    echo "Error: profile '$(context_name_from_file "$file")' is missing required value '$key'" >&2
    return 1
  fi
  printf -v "$value_var" '%s' "$value"
}

read_profile_default_value() {
  local file="$1"
  local key="$2"
  local default_value="$3"
  local value_var="$4"
  local value present

  if ! read_context_value_presence "$file" "$key" value present; then
    return 1
  fi
  if [ "$present" = 'yes' ]; then
    printf -v "$value_var" '%s' "$value"
  else
    printf -v "$value_var" '%s' "$default_value"
  fi
}

profile_value_is_nonblank() {
  [[ "$1" =~ [^[:space:]] ]]
}

validate_nonblank_profile_value() {
  local source="$1"
  local key="$2"
  local value="$3"

  if ! profile_value_is_nonblank "$value"; then
    echo "Error: $source has blank required value '$key'" >&2
    return 1
  fi
}

validate_git_boolean_profile_value() {
  local source="$1"
  local key="$2"
  local value="$3"
  local normalized=${value,,}

  case "$normalized" in
  true | false | yes | no | on | off | 1 | 0)
    return 0
    ;;
  esac

  echo "Error: $source has invalid value '$value' for '$key'; expected true, false, yes, no, on, off, 1, or 0" >&2
  return 1
}

validate_core_autocrlf_profile_value() {
  local source="$1"
  local value="$2"
  local normalized=${value,,}

  case "$normalized" in
  true | false | yes | no | on | off | 1 | 0 | input)
    return 0
    ;;
  esac

  echo "Error: $source has invalid value '$value' for 'core.autocrlf'; expected true, false, yes, no, on, off, 1, 0, or input" >&2
  return 1
}

validate_pull_rebase_profile_value() {
  local source="$1"
  local value="$2"
  local normalized=${value,,}

  case "$normalized" in
  true | false | yes | no | on | off | 1 | 0 | merges | interactive | preserve)
    return 0
    ;;
  esac

  echo "Error: $source has invalid value '$value' for 'pull.rebase'; expected true, false, merges, interactive, preserve, or a Git boolean" >&2
  return 1
}

validate_managed_ssh_key_path() {
  local source="$1"
  local value="$2"

  validate_nonblank_profile_value "$source" picotools.sshKeyPath "$value" || return 1
  case "$value" in
  /*)
    return 0
    ;;
  esac

  echo "Error: $source has non-absolute managed SSH key path 'picotools.sshKeyPath'" >&2
  return 1
}

validate_push_default_profile_value() {
  local source="$1"
  local value="$2"
  local normalized=${value,,}

  case "$normalized" in
  nothing | matching | simple | upstream | tracking | current)
    return 0
    ;;
  esac

  echo "Error: $source has invalid value '$value' for 'push.default'; expected nothing, matching, simple, upstream, tracking, or current" >&2
  return 1
}

# shellcheck disable=SC2034 # values are written through a caller-provided nameref
git_profile_state_defaults() {
  local state_name="$1"
  local -n profile_defaults_ref="$state_name"

  profile_defaults_ref["user_name"]=''
  profile_defaults_ref["email"]=''
  profile_defaults_ref["use_ssh"]=no
  profile_defaults_ref["ssh_key_path"]=''
  profile_defaults_ref["use_gpg"]=no
  profile_defaults_ref["signing_key"]=''
  profile_defaults_ref["gpg_program"]=''
  profile_defaults_ref["autocrlf"]=false
  profile_defaults_ref["file_mode"]=true
  profile_defaults_ref["pull_rebase"]=$(default_pull_rebase)
  profile_defaults_ref["rebase_autostash"]=$(default_rebase_autostash)
  profile_defaults_ref["push_default"]=$(default_push_default)
  profile_defaults_ref["push_autosetupremote"]=$(default_push_autosetupremote)
  profile_defaults_ref["core_editor"]=$(default_core_editor)
  profile_defaults_ref["ssh_add_on_start"]=$(default_ssh_add_on_start)
}

git_profile_state_validate_managed_values() {
  local source="$1"
  local state_name="$2"
  local commit_gpgsign="$3"
  local tag_gpgsign="$4"
  local -n profile_managed_ref="$state_name"

  validate_nonblank_profile_value "$source" user.name "${profile_managed_ref["user_name"]}" || return 1
  validate_nonblank_profile_value "$source" user.email "${profile_managed_ref["email"]}" || return 1
  validate_git_boolean_profile_value "$source" commit.gpgsign "$commit_gpgsign" || return 1
  validate_git_boolean_profile_value "$source" tag.gpgsign "$tag_gpgsign" || return 1
  validate_core_autocrlf_profile_value "$source" "${profile_managed_ref["autocrlf"]}" || return 1
  validate_git_boolean_profile_value "$source" core.fileMode "${profile_managed_ref["file_mode"]}" || return 1
  validate_pull_rebase_profile_value "$source" "${profile_managed_ref["pull_rebase"]}" || return 1
  validate_git_boolean_profile_value "$source" rebase.autoStash "${profile_managed_ref["rebase_autostash"]}" || return 1
  validate_push_default_profile_value "$source" "${profile_managed_ref["push_default"]}" || return 1
  validate_git_boolean_profile_value "$source" push.autoSetupRemote "${profile_managed_ref["push_autosetupremote"]}" || return 1
  validate_nonblank_profile_value "$source" core.editor "${profile_managed_ref["core_editor"]}" || return 1
  validate_git_boolean_profile_value "$source" picotools.sshAddOnStart "${profile_managed_ref["ssh_add_on_start"]}" || return 1
}

git_profile_state_validate_candidate() {
  local source="$1"
  local state_name="$2"
  local -n profile_candidate_ref="$state_name"
  local commit_gpgsign=false tag_gpgsign=false

  case "${profile_candidate_ref["use_ssh"]}" in
  yes)
    validate_managed_ssh_key_path "$source" "${profile_candidate_ref["ssh_key_path"]}" || return 1
    ;;
  no) ;;
  *)
    echo "Error: $source has invalid internal SSH enabled state '${profile_candidate_ref["use_ssh"]}'" >&2
    return 1
    ;;
  esac

  case "${profile_candidate_ref["use_gpg"]}" in
  yes)
    commit_gpgsign=true
    tag_gpgsign=true
    validate_nonblank_profile_value "$source" gpg.program "${profile_candidate_ref["gpg_program"]}" || return 1
    ;;
  no) ;;
  *)
    echo "Error: $source has invalid internal GPG enabled state '${profile_candidate_ref["use_gpg"]}'" >&2
    return 1
    ;;
  esac

  git_profile_state_validate_managed_values "$source" "$state_name" "$commit_gpgsign" "$tag_gpgsign"
}

validate_profile_file_schema() {
  local file="$1"
  local source
  local user_name email ssh_key_path ssh_key_path_present ssh_command ssh_command_present
  local signing_key signing_key_present
  local gpg_program gpg_program_present commit_gpgsign tag_gpgsign
  local -A profile=()

  source="profile '$(context_name_from_file "$file")'"
  git_profile_state_defaults profile

  read_profile_required_value "$file" user.name user_name || return 1
  read_profile_required_value "$file" user.email email || return 1
  read_context_value_presence "$file" picotools.sshKeyPath ssh_key_path ssh_key_path_present || return 1
  read_context_value_presence "$file" core.sshCommand ssh_command ssh_command_present || return 1
  read_context_value_presence "$file" user.signingkey signing_key signing_key_present || return 1
  read_context_value_presence "$file" gpg.program gpg_program gpg_program_present || return 1
  read_profile_default_value "$file" commit.gpgsign false commit_gpgsign || return 1
  read_profile_default_value "$file" tag.gpgsign false tag_gpgsign || return 1
  read_profile_default_value "$file" core.autocrlf false 'profile[autocrlf]' || return 1
  read_profile_default_value "$file" core.fileMode true 'profile[file_mode]' || return 1
  read_profile_default_value "$file" pull.rebase "$(default_pull_rebase)" 'profile[pull_rebase]' || return 1
  read_profile_default_value "$file" rebase.autoStash "$(default_rebase_autostash)" 'profile[rebase_autostash]' || return 1
  read_profile_default_value "$file" push.default "$(default_push_default)" 'profile[push_default]' || return 1
  read_profile_default_value "$file" push.autoSetupRemote "$(default_push_autosetupremote)" 'profile[push_autosetupremote]' || return 1
  read_profile_default_value "$file" core.editor "$(default_core_editor)" 'profile[core_editor]' || return 1
  read_profile_default_value "$file" picotools.sshAddOnStart "$(default_ssh_add_on_start)" 'profile[ssh_add_on_start]' || return 1
  # shellcheck disable=SC2034 # read through nameref in git_profile_state_validate_managed_values
  profile["user_name"]="$user_name"
  # shellcheck disable=SC2034 # read through nameref in git_profile_state_validate_managed_values
  profile["email"]="$email"

  if [ "$ssh_key_path_present" = 'yes' ]; then
    validate_managed_ssh_key_path "$source" "$ssh_key_path" || return 1
  fi
  if [ "$ssh_command_present" = 'yes' ]; then
    validate_nonblank_profile_value "$source" core.sshCommand "$ssh_command" || return 1
    if [ "$ssh_key_path_present" != 'yes' ] && ! extract_ssh_key_path "$ssh_command" >/dev/null; then
      echo "Error: $source has unsupported legacy SSH command; expected command emitted by git-profile" >&2
      return 1
    fi
  fi
  if [ "$signing_key_present" = 'yes' ]; then
    validate_nonblank_profile_value "$source" user.signingkey "$signing_key" || return 1
  fi
  if [ "$gpg_program_present" = 'yes' ]; then
    validate_nonblank_profile_value "$source" gpg.program "$gpg_program" || return 1
  fi

  git_profile_state_validate_managed_values "$source" profile "$commit_gpgsign" "$tag_gpgsign"
}

read_context_value_with_default() {
  local file="$1"
  local key="$2"
  local default_value="$3"

  picotools_git_config_get_default "$file" "$key" "$default_value"
}

read_managed_context_value() {
  local file="$1"
  local key="$2"

  case "$key" in
  commit.gpgsign | tag.gpgsign)
    read_context_value_with_default "$file" "$key" false
    ;;
  core.autocrlf)
    read_context_value_with_default "$file" "$key" false
    ;;
  core.fileMode)
    read_context_value_with_default "$file" "$key" true
    ;;
  pull.rebase)
    read_context_value_with_default "$file" "$key" "$(default_pull_rebase)"
    ;;
  rebase.autoStash)
    read_context_value_with_default "$file" "$key" "$(default_rebase_autostash)"
    ;;
  push.default)
    read_context_value_with_default "$file" "$key" "$(default_push_default)"
    ;;
  push.autoSetupRemote)
    read_context_value_with_default "$file" "$key" "$(default_push_autosetupremote)"
    ;;
  core.editor)
    read_context_value_with_default "$file" "$key" "$(default_core_editor)"
    ;;
  picotools.sshAddOnStart)
    read_context_value_with_default "$file" "$key" "$(default_ssh_add_on_start)"
    ;;
  *)
    read_context_value "$file" "$key"
    ;;
  esac
}

context_uses_gpg() {
  local file="$1"

  [ "$(read_managed_context_value "$file" commit.gpgsign)" = 'true' ]
}

saved_context_files() {
  local dir

  dir=$(context_dir)
  if [ ! -d "$dir" ] || ! compgen -G "$dir/*.gitconfig" >/dev/null; then
    return 1
  fi

  printf '%s\n' "$dir"/*.gitconfig | sort
}

save_context() {
  local file="$1"
  local state_name="$2"
  local -n profile_save_ref="$state_name"
  local dir base tmp

  if ! git_profile_state_validate_candidate "candidate profile '${file##*/}'" "$state_name"; then
    return 1
  fi

  dir=${file%/*}
  base=${file##*/}
  mkdir -p "$dir"
  umask 077
  if ! tmp=$(mktemp "$dir/.${base}.tmp.XXXXXX"); then
    return 1
  fi
  register_tmpfile "$tmp"
  debug_log "Saving profile file '$file'"

  if ! write_context_value "$tmp" user.name "${profile_save_ref["user_name"]}"; then
    rm -f "$tmp"
    return 1
  fi
  if ! write_context_value "$tmp" user.email "${profile_save_ref["email"]}"; then
    rm -f "$tmp"
    return 1
  fi

  if [ "${profile_save_ref["use_ssh"]}" = 'yes' ]; then
    if ! write_context_value "$tmp" picotools.sshKeyPath "${profile_save_ref["ssh_key_path"]}"; then
      rm -f "$tmp"
      return 1
    fi
    if ! write_context_value "$tmp" core.sshCommand "$(build_ssh_command "${profile_save_ref["ssh_key_path"]}")"; then
      rm -f "$tmp"
      return 1
    fi
  fi

  if [ "${profile_save_ref["use_gpg"]}" = 'yes' ]; then
    if [ -n "${profile_save_ref["signing_key"]}" ]; then
      if ! write_context_value "$tmp" user.signingkey "${profile_save_ref["signing_key"]}"; then
        rm -f "$tmp"
        return 1
      fi
    fi
    if ! write_context_value "$tmp" commit.gpgsign true; then
      rm -f "$tmp"
      return 1
    fi
    if ! write_context_value "$tmp" tag.gpgsign true; then
      rm -f "$tmp"
      return 1
    fi
    if ! write_context_value "$tmp" gpg.program "${profile_save_ref["gpg_program"]}"; then
      rm -f "$tmp"
      return 1
    fi
  else
    if ! write_context_value "$tmp" commit.gpgsign false; then
      rm -f "$tmp"
      return 1
    fi
    if ! write_context_value "$tmp" tag.gpgsign false; then
      rm -f "$tmp"
      return 1
    fi
  fi

  if ! write_context_value "$tmp" core.autocrlf "${profile_save_ref["autocrlf"]}"; then
    rm -f "$tmp"
    return 1
  fi
  if ! write_context_value "$tmp" core.fileMode "${profile_save_ref["file_mode"]}"; then
    rm -f "$tmp"
    return 1
  fi
  if ! write_context_value "$tmp" pull.rebase "${profile_save_ref["pull_rebase"]}"; then
    rm -f "$tmp"
    return 1
  fi
  if ! write_context_value "$tmp" rebase.autoStash "${profile_save_ref["rebase_autostash"]}"; then
    rm -f "$tmp"
    return 1
  fi
  if ! write_context_value "$tmp" push.default "${profile_save_ref["push_default"]}"; then
    rm -f "$tmp"
    return 1
  fi
  if ! write_context_value "$tmp" push.autoSetupRemote "${profile_save_ref["push_autosetupremote"]}"; then
    rm -f "$tmp"
    return 1
  fi
  if ! write_context_value "$tmp" core.editor "${profile_save_ref["core_editor"]}"; then
    rm -f "$tmp"
    return 1
  fi
  if ! write_context_value "$tmp" picotools.sshAddOnStart "${profile_save_ref["ssh_add_on_start"]}"; then
    rm -f "$tmp"
    return 1
  fi

  if ! validate_profile_file_schema "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

snapshot_context_file_state() {
  local file="$1"
  local backup_var="$2"
  local existed_var="$3"
  local backup_file=''

  printf -v "$existed_var" '%s' no
  if [ -f "$file" ]; then
    if ! backup_file=$(mktemp "${file}.backup.XXXXXX"); then
      return 1
    fi
    register_tmpfile "$backup_file"
    if ! cp -p -- "$file" "$backup_file"; then
      rm -f "$backup_file"
      return 1
    fi
    printf -v "$backup_var" '%s' "$backup_file"
    printf -v "$existed_var" '%s' yes
  else
    printf -v "$backup_var" '%s' ''
  fi
}

restore_context_file_state() {
  local file="$1"
  local backup="$2"
  local existed="$3"

  if [ "$existed" = 'yes' ]; then
    mv -f -- "$backup" "$file"
  else
    rm -f -- "$file"
  fi
}

preflight_delete_context_profile() {
  local file="$1"
  local name="$2"
  local expected_file

  validate_context_name "$name"
  expected_file=$(context_file "$name")
  if [ "$file" != "$expected_file" ]; then
    echo "Error: refusing to delete profile from an unexpected path: $file" >&2
    return 1
  fi
  if [ -L "$file" ]; then
    echo "Error: refusing to delete profile because its path is a symbolic link: $file" >&2
    return 1
  fi
  if [ ! -f "$file" ]; then
    echo "Error: profile not found '$name'" >&2
    return 1
  fi
}

require_existing_profile_file() {
  local profile_name="$1"
  local file

  validate_context_name "$profile_name"
  file=$(context_file "$profile_name")
  if [ ! -f "$file" ]; then
    echo "Error: profile not found '$profile_name'" >&2
    exit 1
  fi

  printf '%s\n' "$file"
}
