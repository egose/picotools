#!/usr/bin/env bash

if [ "${PICOTOOLS_GIT_PROFILE_RESOURCES_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_GIT_PROFILE_RESOURCES_SH_LOADED=1

public_ssh_key_path() {
  local ssh_key_path="$1"

  if [ -n "$ssh_key_path" ] && [ -f "$ssh_key_path.pub" ]; then
    printf '%s\n' "$ssh_key_path.pub"
  fi
}

print_public_ssh_key() {
  local public_key_path="$1"

  printf '\nPublic SSH Key (%s):\n' "$public_key_path"
  printf '%s\n' "$(<"$public_key_path")"
}

print_ssh_agent_start_commands() {
  printf '%s\n' "if [ -z \"\${SSH_AUTH_SOCK:-}\" ]; then"
  printf '%s\n' "  eval \"\$(ssh-agent -s)\" >/dev/null"
  printf '%s\n' "fi"
}

print_ssh_add_commands() {
  local ssh_key_path="$1"

  if [ -z "$ssh_key_path" ]; then
    return 0
  fi

  printf 'ssh-add -- %q\n' "$ssh_key_path"
}

build_ssh_command() {
  local ssh_key_path="$1"
  local ssh_command

  printf -v ssh_command 'ssh -i %q -o IdentitiesOnly=yes' "$ssh_key_path"
  printf '%s\n' "$ssh_command"
}

decode_legacy_ssh_key_token() {
  local token="$1"
  local decoded='' char

  case "$token" in
  "\$'"*)
    return 1
    ;;
  esac

  while [ -n "$token" ]; do
    case "$token" in
    \\*)
      if [ "${#token}" -eq 1 ]; then
        return 1
      fi
      char=${token:1:1}
      decoded+="$char"
      token=${token:2}
      ;;
    *)
      char=${token:0:1}
      case "$char" in
      "'" | '"')
        return 1
        ;;
      esac
      decoded+="$char"
      token=${token:1}
      ;;
    esac
  done

  printf '%s\n' "$decoded"
}

legacy_ssh_key_path_from_command() {
  local ssh_command="$1"
  local ssh_key_token

  case "$ssh_command" in
  'ssh -i '*" -o IdentitiesOnly=yes")
    ssh_key_token=${ssh_command#'ssh -i '}
    ssh_key_token=${ssh_key_token%' -o IdentitiesOnly=yes'}
    ;;
  *)
    return 1
    ;;
  esac

  decode_legacy_ssh_key_token "$ssh_key_token"
}

next_generated_ssh_key_path() {
  local context_name="$1"
  local ssh_dir normalized_name base_path ssh_key_path suffix

  ssh_dir="$HOME/.ssh"
  normalized_name=${context_name//[^A-Za-z0-9]/_}
  normalized_name=${normalized_name,,}
  base_path="$ssh_dir/id_ed25519_$normalized_name"
  ssh_key_path="$base_path"
  suffix=1

  while [ -e "$ssh_key_path" ] || [ -e "$ssh_key_path.pub" ]; do
    ssh_key_path="${base_path}_$suffix"
    suffix=$((suffix + 1))
  done

  printf '%s\n' "$ssh_key_path"
}

extract_ssh_key_path() {
  local ssh_command="$1"

  if [ -z "$ssh_command" ]; then
    return 0
  fi

  legacy_ssh_key_path_from_command "$ssh_command" || return 0
}

read_context_ssh_key_path() {
  local file="$1"
  local ssh_key_path ssh_command

  ssh_key_path=$(read_context_value_optional "$file" picotools.sshKeyPath)
  if [ -n "$ssh_key_path" ]; then
    validate_managed_ssh_key_path "profile '$(context_name_from_file "$file")'" "$ssh_key_path" || return 1
    printf '%s\n' "$ssh_key_path"
    return 0
  fi

  ssh_command=$(read_context_value_optional "$file" core.sshCommand)
  extract_ssh_key_path "$ssh_command"
}

read_context_ssh_command() {
  local file="$1"
  local ssh_key_path

  ssh_key_path=$(read_context_ssh_key_path "$file")
  if [ -z "$ssh_key_path" ]; then
    return 0
  fi

  build_ssh_command "$ssh_key_path"
}

require_existing_file() {
  local path="$1"
  local description="$2"

  if [ ! -f "$path" ]; then
    echo "Error: $description does not exist: $path" >&2
    exit 1
  fi
}

resolve_absolute_path() {
  local path="$1"
  local dir base

  case "$path" in
  /*)
    printf '%s\n' "$path"
    return 0
    ;;
  esac

  dir=${path%/*}
  base=${path##*/}
  if [ "$dir" = "$path" ]; then
    dir=.
  fi

  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
}

delete_ssh_key_files() {
  local ssh_key_path="$1"

  if [ -z "$ssh_key_path" ]; then
    return 0
  fi

  rm -f -- "$ssh_key_path" "$ssh_key_path.pub"
}

validate_gpg_signing_key_for_delete() {
  local signing_key="$1"

  case "$signing_key" in
  -* | *[!A-Za-z0-9._@+-]*)
    echo "Error: refusing to delete GPG signing key with an unsafe identifier: $signing_key" >&2
    return 1
    ;;
  esac
}

delete_gpg_key() {
  local signing_key="$1"
  local gpg_program="${2:-gpg}"

  if [ -z "$signing_key" ]; then
    return 0
  fi

  validate_gpg_signing_key_for_delete "$signing_key" || return 1
  picotools_require_command "$gpg_program"
  "$gpg_program" --batch --yes --delete-secret-and-public-key -- "$signing_key"
}

generate_ssh_key() {
  local email="$1"
  local context_name="$2"
  local ssh_key_path

  picotools_require_command ssh-keygen
  ssh_key_path=$(next_generated_ssh_key_path "$context_name")
  mkdir -p "$(dirname "$ssh_key_path")"

  ssh-keygen -t ed25519 -C "$email" -f "$ssh_key_path" >&2
  require_existing_file "$ssh_key_path" 'Generated SSH private key path'

  printf '%s\n' "$ssh_key_path"
}

resolve_ssh_key_path() {
  local email="$1"
  local context_name="$2"
  local current_path="${3:-}"
  local label ssh_key_path

  label='SSH private key path (leave blank to generate)'
  if [ -n "$current_path" ]; then
    label="$label [current: $current_path]"
  fi

  ssh_key_path=$(picotools_prompt_value "$label")
  if [ -n "$ssh_key_path" ]; then
    require_existing_file "$ssh_key_path" 'SSH private key path'
    ssh_key_path=$(resolve_absolute_path "$ssh_key_path")
  else
    if ! ssh_key_path=$(generate_ssh_key "$email" "$context_name"); then
      return 1
    fi
    GIT_CONTEXT_GENERATED_SSH_KEY_PATHS+=("$ssh_key_path")
  fi

  printf '%s\n' "$ssh_key_path"
}

generate_signing_key() {
  local user_name="$1"
  local email="$2"
  local gpg_program
  local signing_key=''
  local batch_file
  local status_file
  local line
  local status_payload
  local key_created_count=0

  gpg_program=$(default_gpg_program)
  picotools_require_command "$gpg_program"
  batch_file=$(mktemp)
  status_file=$(mktemp)
  register_tmpfile "$batch_file"
  register_tmpfile "$status_file"
  trap 'cleanup_tmpfiles' EXIT
  {
    printf '%s\n' 'Key-Type: RSA'
    printf '%s\n' 'Key-Length: 3072'
    printf '%s\n' 'Key-Usage: sign cert'
    printf '%s\n' 'Subkey-Type: RSA'
    printf '%s\n' 'Subkey-Length: 3072'
    printf '%s\n' 'Subkey-Usage: encrypt'
    printf '%s\n' "Name-Real: $user_name"
    printf '%s\n' "Name-Email: $email"
    printf '%s\n' 'Expire-Date: 0'
    printf '%s\n' '%commit'
  } >"$batch_file"

  exec 3>"$status_file"
  if ! "$gpg_program" --batch --status-fd 3 --generate-key "$batch_file"; then
    exec 3>&-
    return 1
  fi
  exec 3>&-

  while IFS= read -r line; do
    case "$line" in
    '[GNUPG:] KEY_CREATED '*)
      status_payload=${line#'[GNUPG:] KEY_CREATED '}
      # shellcheck disable=SC2086
      set -- $status_payload
      if [ "$#" -eq 2 ] && [ -n "$2" ]; then
        signing_key="$2"
        key_created_count=$((key_created_count + 1))
      fi
      ;;
    esac
  done <"$status_file"
  if [ "$key_created_count" -ne 1 ]; then
    echo 'Error: failed to determine generated GPG signing key from GPG status output' >&2
    return 1
  fi

  printf '%s\n' "$signing_key"
}

resolve_signing_key() {
  local current_key="${1:-}"
  local user_name="$2"
  local email="$3"
  local label signing_key

  label='GPG signing key (leave blank to generate)'
  if [ -n "$current_key" ]; then
    label="$label [current: $current_key]"
  fi

  signing_key=$(picotools_prompt_value "$label")
  if [ -z "$signing_key" ]; then
    if ! signing_key=$(generate_signing_key "$user_name" "$email"); then
      return 1
    fi
    GIT_CONTEXT_GENERATED_GPG_KEYS+=("$signing_key")
  fi

  printf '%s\n' "$signing_key"
}

rollback_generated_create_material() {
  local ssh_key_path gpg_key

  for ssh_key_path in "${GIT_CONTEXT_GENERATED_SSH_KEY_PATHS[@]}"; do
    delete_ssh_key_files "$ssh_key_path"
  done

  for gpg_key in "${GIT_CONTEXT_GENERATED_GPG_KEYS[@]}"; do
    echo "Generated GPG signing key retained after failed create: $gpg_key" >&2
  done
}
