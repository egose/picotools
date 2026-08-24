#!/usr/bin/env bash

if [ "${PICOTOOLS_MODEL_PROFILE_PROFILE_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_MODEL_PROFILE_PROFILE_SH_LOADED=1

MODEL_PROFILE_TX_ACTIVE=false
MODEL_PROFILE_TX_NAME=''
MODEL_PROFILE_TX_PROFILE_FILE=''
MODEL_PROFILE_TX_PROFILE_BACKUP=''
MODEL_PROFILE_TX_PROFILE_OLD_EXISTS=false
MODEL_PROFILE_TX_PROFILE_PUBLISHED=false
MODEL_PROFILE_TX_TOKEN_ACTION='keep'
MODEL_PROFILE_TX_TOKEN_FILE=''
MODEL_PROFILE_TX_TOKEN_BACKUP=''
MODEL_PROFILE_TX_TOKEN_OLD_EXISTS=false
MODEL_PROFILE_TX_TOKEN_PUBLISHED=false

config_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/model-profile"
}

ensure_storage_dirs() {
  picotools_require_command git
  ensure_profile_storage_root_for_write >/dev/null || return 1
  ensure_token_storage_root_for_write >/dev/null || return 1
}

profile_file() {
  local name="$1"
  printf '%s/%s.conf\n' "$(config_dir)" "$name"
}

profile_storage_error() {
  local name="${1:-}"

  if [ -n "$name" ]; then
    echo "Error: unsafe profile storage for profile '$name'" >&2
  else
    echo 'Error: unsafe profile storage directory' >&2
  fi
}

ensure_profile_storage_root_for_write() {
  local dir

  dir=$(config_dir)
  if [ -L "$dir" ]; then
    profile_storage_error
    return 2
  fi
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    profile_storage_error
    return 2
  fi

  mkdir -p "$dir"

  if [ -L "$dir" ] || [ ! -d "$dir" ]; then
    profile_storage_error
    return 2
  fi

  printf '%s\n' "$dir"
}

validate_profile_storage_root() {
  local operation="$1"
  local dir

  dir=$(config_dir)

  if [ "$operation" = write ]; then
    ensure_profile_storage_root_for_write
    return $?
  fi

  if [ -L "$dir" ]; then
    profile_storage_error
    return 2
  fi
  if [ ! -e "$dir" ]; then
    return 1
  fi
  if [ ! -d "$dir" ]; then
    profile_storage_error
    return 2
  fi

  printf '%s\n' "$dir"
}

validate_profile_leaf() {
  local name="$1"
  local operation="$2"
  local dir file

  if ! validate_profile_name_value "$name"; then
    return 2
  fi

  if dir=$(validate_profile_storage_root "$operation"); then
    :
  else
    return $?
  fi

  file="$dir/$name.conf"
  if [ -L "$file" ]; then
    profile_storage_error "$name"
    return 2
  fi
  if [ ! -e "$file" ]; then
    printf '%s\n' "$file"
    return 1
  fi
  if [ ! -f "$file" ]; then
    profile_storage_error "$name"
    return 2
  fi

  printf '%s\n' "$file"
}

saved_profile_files() {
  local dir file name
  local -a files=()

  if dir=$(validate_profile_storage_root read); then
    :
  else
    return $?
  fi

  if ! compgen -G "$dir/*.conf" >/dev/null; then
    return 1
  fi

  for file in "$dir"/*.conf; do
    name=$(profile_name_from_file "$file")
    if [ -L "$file" ] || [ ! -f "$file" ]; then
      continue
    fi
    if ! validate_profile_name_value "$name" >/dev/null 2>&1; then
      continue
    fi
    files+=("$file")
  done

  if [ "${#files[@]}" -eq 0 ]; then
    return 1
  fi

  printf '%s\n' "${files[@]}" | sort
}

profile_name_from_file() {
  local file="$1"
  local name

  name=${file##*/}
  printf '%s\n' "${name%.conf}"
}

write_profile_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  picotools_require_command git
  picotools_git_config_set "$file" "$key" "$value"
}

read_profile_value() {
  local file="$1"
  local key="$2"

  picotools_require_command git
  picotools_git_config_get "$file" "$key"
}

read_profile_value_optional() {
  local file="$1"
  local key="$2"

  picotools_require_command git
  picotools_git_config_get_optional "$file" "$key"
}

provider_models_value() {
  local file="$1"
  normalize_models_value "$(read_profile_value_optional "$file" provider.models)"
}

provider_resource_name_value() {
  local file="$1"
  trim_spaces "$(read_profile_value_optional "$file" provider.resourceName)"
}

provider_endpoint_url_value() {
  local file="$1"
  normalize_endpoint_url_value "$(read_profile_value_optional "$file" provider.endpointUrl)"
}

profile_schema_error() {
  local name="$1"
  local message="$2"

  echo "Error: invalid profile '$name': $message" >&2
}

profile_config_key_count() {
  local file="$1"
  local key="$2"
  local count

  if count=$(git config -f "$file" --get-all "$key" 2>/dev/null | wc -l); then
    printf '%s\n' "$count"
  else
    printf '%s\n' 0
  fi
}

validate_profile_managed_keys() {
  local name="$1"
  local file="$2"
  local key keys count

  if ! keys=$(git config -f "$file" --name-only --get-regexp '.*' 2>/dev/null); then
    profile_schema_error "$name" 'malformed or empty config'
    return 1
  fi

  while IFS= read -r key; do
    case "$key" in
    provider.type | provider.resourcename | provider.endpointurl | provider.models) ;;
    '') ;;
    *)
      profile_schema_error "$name" "unknown managed key '$key'"
      return 1
      ;;
    esac
  done <<<"$keys"

  for key in provider.type provider.resourceName provider.endpointUrl provider.models; do
    count=$(profile_config_key_count "$file" "$key")
    if [ "$count" -gt 1 ]; then
      profile_schema_error "$name" "duplicate managed key '$key'"
      return 1
    fi
  done
}

validate_profile_schema_values() {
  local name="$1"
  local provider_type="$2"
  local resource_name="$3"
  local endpoint_url="$4"
  local models="$5"
  local location_field

  if ! validate_provider_type_value "$provider_type"; then
    profile_schema_error "$name" 'unknown provider type'
    return 1
  fi

  if ! validate_models_value "$models"; then
    profile_schema_error "$name" 'invalid model list'
    return 1
  fi

  location_field=$(provider_registry_field "$provider_type" location) || return 1
  case "$location_field" in
  resource)
    if [ -z "$resource_name" ]; then
      profile_schema_error "$name" 'missing resource name'
      return 1
    fi
    if ! validate_azure_resource_name_value "$resource_name"; then
      profile_schema_error "$name" 'invalid Azure resource name'
      return 1
    fi
    if [ -n "$endpoint_url" ]; then
      profile_schema_error "$name" 'endpoint URL is only valid for custom profiles'
      return 1
    fi
    ;;
  none)
    if [ -n "$resource_name" ] || [ -n "$endpoint_url" ]; then
      profile_schema_error "$name" 'gemini profiles must not set provider locations'
      return 1
    fi
    ;;
  endpoint)
    if [ -z "$endpoint_url" ]; then
      profile_schema_error "$name" 'missing endpoint URL'
      return 1
    fi
    if ! validate_custom_endpoint_url_value "$endpoint_url" >/dev/null; then
      profile_schema_error "$name" 'invalid custom endpoint URL'
      return 1
    fi
    if [ -n "$resource_name" ]; then
      profile_schema_error "$name" 'resource name is only valid for Azure profiles'
      return 1
    fi
    ;;
  *)
    return 1
    ;;
  esac
}

validate_profile_file_schema() {
  local file="$1"
  local name provider_type resource_name endpoint_url models

  read_valid_profile_record "$file" name provider_type resource_name endpoint_url models
}

read_valid_profile_record() {
  local file="$1"
  local name_var="$2"
  local provider_type_var="$3"
  local resource_name_var="$4"
  local endpoint_url_var="$5"
  local models_var="$6"
  local record_name config_lines line key value seen=false
  local record_provider_type='' record_resource_name='' record_endpoint_url='' record_models=''
  local -A key_counts=()
  local -n record_name_ref="$name_var"
  local -n record_provider_type_ref="$provider_type_var"
  local -n record_resource_name_ref="$resource_name_var"
  local -n record_endpoint_url_ref="$endpoint_url_var"
  local -n record_models_ref="$models_var"

  picotools_require_command git
  record_name=$(profile_name_from_file "$file")

  if ! config_lines=$(git config -f "$file" --list 2>/dev/null); then
    profile_schema_error "$record_name" 'malformed or empty config'
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    seen=true
    key=${line%%=*}
    value=${line#*=}
    key_counts[$key]=$((${key_counts[$key]:-0} + 1))
    case "$key" in
    provider.type)
      record_provider_type=$value
      ;;
    provider.resourcename)
      record_resource_name=$value
      ;;
    provider.endpointurl)
      record_endpoint_url=$value
      ;;
    provider.models)
      record_models=$value
      ;;
    *)
      profile_schema_error "$record_name" "unknown managed key '$key'"
      return 1
      ;;
    esac
  done <<<"$config_lines"

  if [ "$seen" != true ]; then
    profile_schema_error "$record_name" 'malformed or empty config'
    return 1
  fi

  if [ "${key_counts["provider.type"]:-0}" -gt 1 ]; then
    profile_schema_error "$record_name" "duplicate managed key 'provider.type'"
    return 1
  fi
  if [ "${key_counts["provider.resourcename"]:-0}" -gt 1 ]; then
    profile_schema_error "$record_name" "duplicate managed key 'provider.resourceName'"
    return 1
  fi
  if [ "${key_counts["provider.endpointurl"]:-0}" -gt 1 ]; then
    profile_schema_error "$record_name" "duplicate managed key 'provider.endpointUrl'"
    return 1
  fi
  if [ "${key_counts["provider.models"]:-0}" -gt 1 ]; then
    profile_schema_error "$record_name" "duplicate managed key 'provider.models'"
    return 1
  fi

  record_resource_name=$(trim_spaces "$record_resource_name")
  record_endpoint_url=$(normalize_endpoint_url_value "$record_endpoint_url")
  record_models=$(normalize_models_value "$record_models")

  if ! validate_profile_schema_values "$record_name" "$record_provider_type" "$record_resource_name" "$record_endpoint_url" "$record_models"; then
    return 1
  fi

  # shellcheck disable=SC2034 # Nameref assignments write the caller-owned output variables.
  record_name_ref=$record_name
  # shellcheck disable=SC2034 # Nameref assignments write the caller-owned output variables.
  record_provider_type_ref=$record_provider_type
  # shellcheck disable=SC2034 # Nameref assignments write the caller-owned output variables.
  record_resource_name_ref=$record_resource_name
  # shellcheck disable=SC2034 # Nameref assignments write the caller-owned output variables.
  record_endpoint_url_ref=$record_endpoint_url
  # shellcheck disable=SC2034 # Nameref assignments write the caller-owned output variables.
  record_models_ref=$record_models
}

require_valid_profile_file() {
  local file="$1"

  if ! validate_profile_file_schema "$file"; then
    return 1
  fi
}

require_existing_profile_file() {
  local name="$1"
  local file status

  if file=$(validate_profile_leaf "$name" read); then
    :
  else
    status=$?
    if [ "$status" -eq 1 ]; then
      echo "Error: profile not found: $name" >&2
    fi
    return 1
  fi

  if ! validate_profile_file_schema "$file"; then
    return 1
  fi

  printf '%s\n' "$file"
}

require_writable_profile_file() {
  local name="$1"
  local file status

  if file=$(validate_profile_leaf "$name" write); then
    if ! validate_profile_file_schema "$file"; then
      return 1
    fi
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      return 1
    fi
  fi

  printf '%s\n' "$file"
}

select_profile_model() {
  local file="$1"
  local selection
  local model_list
  local -a model_items=()

  require_valid_profile_file "$file" || return 1
  model_list=$(provider_models_value "$file")
  IFS=',' read -r -a model_items <<<"$model_list"

  if [ "${#model_items[@]}" -eq 0 ]; then
    echo 'Error: no models configured for the selected profile' >&2
    return 1
  fi

  if ! selection=$(picotools_prompt_select_index 'Models' 'Select model' 1 false "${model_items[@]}"); then
    return 1
  fi

  printf '%s\n' "${model_items[$((selection - 1))]}"
}

default_profile_model() {
  local file="$1"
  local model_list
  local -a model_items=()

  require_valid_profile_file "$file" || return 1
  model_list=$(provider_models_value "$file")
  IFS=',' read -r -a model_items <<<"$model_list"

  if [ "${#model_items[@]}" -eq 0 ] || [ -z "${model_items[0]}" ]; then
    echo 'Error: no models configured for the selected profile' >&2
    return 1
  fi

  printf '%s\n' "${model_items[0]}"
}

profile_has_model() {
  local file="$1"
  local requested_model="$2"
  local model_list
  local model_item
  local -a model_items=()

  require_valid_profile_file "$file" || return 1
  if ! validate_model_name_value "$requested_model"; then
    return 1
  fi

  model_list=$(provider_models_value "$file")
  IFS=',' read -r -a model_items <<<"$model_list"

  for model_item in "${model_items[@]}"; do
    if [ "$model_item" = "$requested_model" ]; then
      return 0
    fi
  done

  return 1
}

transaction_maybe_fail() {
  local step="$1"

  if [ "${MODEL_PROFILE_FAIL_TRANSACTION_STEP:-}" = "$step" ]; then
    echo "Error: injected transaction failure after $step" >&2
    return 1
  fi
  if [ "${MODEL_PROFILE_FAIL_TRANSACTION_STEP:-}" = "signal:$step" ]; then
    kill -TERM "$$"
    sleep 1
  fi
}

write_token_candidate() {
  local name="$1"
  local token="$2"
  local candidate_file="$3"
  local mode

  if ! validate_token_content "$name" "$token"; then
    return 1
  fi

  chmod 600 "$candidate_file" || return 1
  printf '%s\n' "$token" >"$candidate_file" || return 1
  mode=$(path_mode "$candidate_file")
  if [ "$mode" != 600 ]; then
    echo 'Error: failed to secure staged API key' >&2
    return 1
  fi

  transaction_maybe_fail token-candidate
}

transaction_begin() {
  MODEL_PROFILE_TX_ACTIVE=true
  MODEL_PROFILE_TX_NAME="$1"
  MODEL_PROFILE_TX_PROFILE_FILE="$2"
  MODEL_PROFILE_TX_PROFILE_BACKUP="$3"
  MODEL_PROFILE_TX_PROFILE_OLD_EXISTS="$4"
  MODEL_PROFILE_TX_PROFILE_PUBLISHED=false
  MODEL_PROFILE_TX_TOKEN_ACTION="$5"
  MODEL_PROFILE_TX_TOKEN_FILE="$6"
  MODEL_PROFILE_TX_TOKEN_BACKUP="$7"
  MODEL_PROFILE_TX_TOKEN_OLD_EXISTS="$8"
  MODEL_PROFILE_TX_TOKEN_PUBLISHED=false
}

transaction_end() {
  MODEL_PROFILE_TX_ACTIVE=false
  MODEL_PROFILE_TX_NAME=''
  MODEL_PROFILE_TX_PROFILE_FILE=''
  MODEL_PROFILE_TX_PROFILE_BACKUP=''
  MODEL_PROFILE_TX_PROFILE_OLD_EXISTS=false
  MODEL_PROFILE_TX_PROFILE_PUBLISHED=false
  MODEL_PROFILE_TX_TOKEN_ACTION='keep'
  MODEL_PROFILE_TX_TOKEN_FILE=''
  MODEL_PROFILE_TX_TOKEN_BACKUP=''
  MODEL_PROFILE_TX_TOKEN_OLD_EXISTS=false
  MODEL_PROFILE_TX_TOKEN_PUBLISHED=false
}

restore_transaction_file() {
  local old_exists="$1"
  local backup_file="$2"
  local live_file="$3"
  local label="$4"

  if [ "$old_exists" = true ]; then
    if ! mv -f -- "$backup_file" "$live_file"; then
      echo "Error: failed to restore previous $label for profile '$MODEL_PROFILE_TX_NAME'" >&2
      return 1
    fi
  else
    if ! rm -f -- "$live_file"; then
      echo "Error: failed to remove partially published $label for profile '$MODEL_PROFILE_TX_NAME'" >&2
      return 1
    fi
  fi
}

transaction_rollback_active() {
  local rollback_status=0
  local transaction_name="$MODEL_PROFILE_TX_NAME"

  if [ "$MODEL_PROFILE_TX_ACTIVE" != true ]; then
    return 0
  fi

  if [ "$MODEL_PROFILE_TX_PROFILE_PUBLISHED" = true ]; then
    restore_transaction_file \
      "$MODEL_PROFILE_TX_PROFILE_OLD_EXISTS" \
      "$MODEL_PROFILE_TX_PROFILE_BACKUP" \
      "$MODEL_PROFILE_TX_PROFILE_FILE" \
      profile || rollback_status=1
  fi

  if [ "$MODEL_PROFILE_TX_TOKEN_ACTION" != keep ] && [ "$MODEL_PROFILE_TX_TOKEN_PUBLISHED" = true ]; then
    restore_transaction_file \
      "$MODEL_PROFILE_TX_TOKEN_OLD_EXISTS" \
      "$MODEL_PROFILE_TX_TOKEN_BACKUP" \
      "$MODEL_PROFILE_TX_TOKEN_FILE" \
      'API key' || rollback_status=1
  fi

  transaction_end
  if [ "$rollback_status" -ne 0 ]; then
    echo "Error: profile '$transaction_name' may be partially updated after rollback failure" >&2
    return 1
  fi
}

publish_profile_transaction() {
  local name="$1"
  local file="$2"
  local provider_type="$3"
  local resource_name="$4"
  local endpoint_url="$5"
  local models="$6"
  local token_action="$7"
  local token="${8:-}"
  local profile_candidate profile_backup token_candidate='' token_backup='' token_path=''
  local old_profile_exists=false old_token_exists=false token_status

  if ! validate_profile_schema_values "$name" "$provider_type" "$resource_name" "$endpoint_url" "$models"; then
    return 1
  fi

  profile_candidate=$(mktemp "$(dirname "$file")/.${name}.conf.tmp.XXXXXX") || return 1
  register_tmpfile "$profile_candidate"
  chmod 600 "$profile_candidate" || return 1
  write_profile_value "$profile_candidate" provider.type "$provider_type" || return 1
  if [ -n "$resource_name" ]; then
    write_profile_value "$profile_candidate" provider.resourceName "$resource_name" || return 1
  fi
  if [ -n "$endpoint_url" ]; then
    write_profile_value "$profile_candidate" provider.endpointUrl "$endpoint_url" || return 1
  fi
  if [ -n "$models" ]; then
    write_profile_value "$profile_candidate" provider.models "$models" || return 1
  fi
  validate_profile_file_schema "$profile_candidate" || return 1
  transaction_maybe_fail profile-candidate || return 1

  if [ "$token_action" = write ]; then
    if token_path=$(validate_token_storage "$name" write); then
      old_token_exists=true
    else
      token_status=$?
      if [ "$token_status" -ne 1 ]; then
        return 1
      fi
      token_path=$(token_file "$name")
    fi
    token_candidate=$(mktemp "$(dirname "$token_path")/.${name}.token.tmp.XXXXXX") || return 1
    register_tmpfile "$token_candidate"
    write_token_candidate "$name" "$token" "$token_candidate" || return 1
  fi

  if [ -f "$file" ]; then
    old_profile_exists=true
    profile_backup=$(mktemp "$(dirname "$file")/.${name}.conf.backup.XXXXXX") || return 1
    register_tmpfile "$profile_backup"
    cp -p -- "$file" "$profile_backup" || return 1
  else
    profile_backup=''
  fi

  if [ "$token_action" = write ] && [ "$old_token_exists" = true ]; then
    token_backup=$(mktemp "$(dirname "$token_path")/.${name}.token.backup.XXXXXX") || return 1
    register_tmpfile "$token_backup"
    cp -p -- "$token_path" "$token_backup" || return 1
  fi

  transaction_begin "$name" "$file" "$profile_backup" "$old_profile_exists" "$token_action" "$token_path" "$token_backup" "$old_token_exists"

  if [ "$token_action" = write ]; then
    if ! mv -f -- "$token_candidate" "$token_path"; then
      transaction_rollback_active || true
      return 1
    fi
    MODEL_PROFILE_TX_TOKEN_PUBLISHED=true
    rm -f "$token_candidate"
    chmod 600 "$token_path" || {
      transaction_rollback_active || true
      return 1
    }
    if ! transaction_maybe_fail token-publish; then
      transaction_rollback_active || true
      return 1
    fi
  fi

  if ! mv -f -- "$profile_candidate" "$file"; then
    transaction_rollback_active || true
    return 1
  fi
  MODEL_PROFILE_TX_PROFILE_PUBLISHED=true
  rm -f "$profile_candidate"
  if ! transaction_maybe_fail profile-publish; then
    transaction_rollback_active || true
    return 1
  fi

  transaction_end
  rm -f -- "$profile_backup" "$token_backup"
}

delete_profile_transaction() {
  local name="$1"
  local file="$2"
  local checked_profile_file token_path='' token_backup='' profile_backup
  local old_token_exists=false token_status

  if checked_profile_file=$(validate_profile_leaf "$name" delete); then
    :
  else
    token_status=$?
    if [ "$token_status" -eq 1 ]; then
      echo "Error: profile not found: $name" >&2
    fi
    return 1
  fi
  if [ "$checked_profile_file" != "$file" ]; then
    echo "Error: profile path changed during delete: $name" >&2
    return 1
  fi
  validate_profile_file_schema "$file" || return 1

  if token_path=$(validate_token_storage "$name" delete); then
    old_token_exists=true
  else
    token_status=$?
    if [ "$token_status" -ne 1 ]; then
      return 1
    fi
    token_path=$(token_file "$name")
  fi

  profile_backup=$(mktemp "$(dirname "$file")/.${name}.conf.backup.XXXXXX") || return 1
  register_tmpfile "$profile_backup"
  cp -p -- "$file" "$profile_backup" || return 1

  if [ "$old_token_exists" = true ]; then
    token_backup=$(mktemp "$(dirname "$token_path")/.${name}.token.backup.XXXXXX") || return 1
    register_tmpfile "$token_backup"
    cp -p -- "$token_path" "$token_backup" || return 1
  fi

  transaction_begin "$name" "$file" "$profile_backup" true delete "$token_path" "$token_backup" "$old_token_exists"

  if ! rm -f -- "$file"; then
    transaction_rollback_active || true
    return 1
  fi
  MODEL_PROFILE_TX_PROFILE_PUBLISHED=true
  if ! transaction_maybe_fail delete-profile; then
    transaction_rollback_active || true
    return 1
  fi

  if [ "$old_token_exists" = true ]; then
    if ! rm -f -- "$token_path"; then
      transaction_rollback_active || true
      return 1
    fi
    MODEL_PROFILE_TX_TOKEN_PUBLISHED=true
    if ! transaction_maybe_fail delete-token; then
      transaction_rollback_active || true
      return 1
    fi
  fi

  transaction_end
  rm -f -- "$profile_backup" "$token_backup"
}
