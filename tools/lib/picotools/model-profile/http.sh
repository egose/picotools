#!/usr/bin/env bash

if [ "${PICOTOOLS_MODEL_PROFILE_HTTP_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_MODEL_PROFILE_HTTP_SH_LOADED=1

model_profile_http_cleanup_request() {
  local request_tmpdir="$1"

  if [ -n "$request_tmpdir" ]; then
    rm -rf -- "$request_tmpdir"
  fi
}

request_limit_value() {
  local env_name="$1"
  local default_value="$2"
  local max_value="$3"
  local label="$4"
  local value="${!env_name:-$default_value}"

  if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" =~ ^0+$ ]]; then
    echo "Error: $env_name must be a positive integer for $label" >&2
    return 1
  fi
  if [ "${#value}" -gt 10 ] || [ "$value" -gt "$max_value" ]; then
    echo "Error: $env_name must be at most $max_value for $label" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

request_connect_timeout() {
  request_limit_value MODEL_PROFILE_CURL_CONNECT_TIMEOUT 10 120 'connect timeout seconds'
}

request_total_timeout() {
  request_limit_value MODEL_PROFILE_CURL_MAX_TIME 60 600 'total timeout seconds'
}

request_payload_max_bytes() {
  request_limit_value MODEL_PROFILE_MAX_PAYLOAD_BYTES 1048576 10485760 'request payload bytes'
}

request_response_max_bytes() {
  request_limit_value MODEL_PROFILE_MAX_RESPONSE_BYTES 1048576 10485760 'response body bytes'
}

request_diagnostic_max_bytes() {
  request_limit_value MODEL_PROFILE_MAX_DIAGNOSTIC_BYTES 4096 65536 'error diagnostic bytes'
}

require_ask_tools() {
  picotools_require_commands curl jq
}

write_curl_auth_config() {
  local name="$1"
  local token="$2"
  local config_file="$3"
  local mode

  if ! validate_token_content "$name" "$token"; then
    return 1
  fi

  : >"$config_file" || return 1
  chmod 600 "$config_file"
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$config_file"
  mode=$(path_mode "$config_file")
  if [ "$mode" != 600 ]; then
    echo 'Error: failed to secure temporary request authentication' >&2
    return 1
  fi
}

message_file_size() {
  stat -c '%s' "$1"
}

inline_message_size() {
  LC_ALL=C printf '%s' "$1" | wc -c
}

require_safe_message_file() {
  local path="$1"
  local label="$2"

  if [ -L "$path" ]; then
    echo "Error: $label file must be a regular file, not a symlink: $path" >&2
    return 1
  fi
  if [ ! -e "$path" ]; then
    echo "Error: cannot read $label file: $path" >&2
    return 1
  fi
  if [ ! -f "$path" ]; then
    echo "Error: $label file must be a readable regular file: $path" >&2
    return 1
  fi
  if [ ! -r "$path" ]; then
    echo "Error: cannot read $label file: $path" >&2
    return 1
  fi
}

check_message_source_size() {
  local label="$1"
  local value="$2"
  local path="$3"
  local max_bytes="$4"
  local size

  if [ -n "$path" ]; then
    require_safe_message_file "$path" "$label"
    size=$(message_file_size "$path")
  else
    size=$(inline_message_size "$value")
  fi

  if [ "$size" -gt "$max_bytes" ]; then
    echo "Error: $label message exceeds request payload limit of $max_bytes bytes" >&2
    return 1
  fi
}

check_payload_size() {
  local file="$1"
  local max_bytes="$2"
  local size

  size=$(message_file_size "$file")
  if [ "$size" -gt "$max_bytes" ]; then
    echo "Error: request payload exceeds limit of $max_bytes bytes" >&2
    return 1
  fi
}

stop_limited_response_reader() {
  local pid="$1"

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

response_exceeded_limit() {
  local file="$1"
  local max_bytes="$2"
  local size

  size=$(message_file_size "$file")
  [ "$size" -gt "$max_bytes" ]
}

sanitize_diagnostic_value() {
  local value="$1"
  local max_bytes="$2"

  LC_ALL=C printf '%s' "$value" |
    tr '\r\n\t' '   ' |
    tr -d '\000-\010\013\014\016-\037\177' |
    head -c "$max_bytes" || true
}

provider_chat_completion() {
  local file="$1"
  local model="$2"
  local system_message="$3"
  local user_message="$4"
  local system_message_path="${5:-}"
  local user_message_path="${6:-}"
  local name provider_type resource_name endpoint_url base_url request_url token auth_config_file payload_file tmpfile system_message_file user_message_file response_fifo response_reader_pid http_code response_text error_message payload_size response_size connect_timeout total_timeout payload_max_bytes response_max_bytes diagnostic_max_bytes request_tmpdir=
  local -a curl_args=()

  require_valid_profile_file "$file" || return 1
  name=$(profile_name_from_file "$file")
  provider_type=$(read_profile_value "$file" provider.type)
  resource_name=$(provider_resource_name_value "$file")
  endpoint_url=$(provider_endpoint_url_value "$file")
  base_url=$(provider_openai_base_url "$provider_type" "$resource_name" "$endpoint_url") || return 1
  if ! request_url=$(provider_chat_completions_url "$base_url"); then
    return 1
  fi
  connect_timeout=$(request_connect_timeout) || return 1
  total_timeout=$(request_total_timeout) || return 1
  payload_max_bytes=$(request_payload_max_bytes) || return 1
  response_max_bytes=$(request_response_max_bytes) || return 1
  diagnostic_max_bytes=$(request_diagnostic_max_bytes) || return 1
  check_message_source_size system "$system_message" "$system_message_path" "$payload_max_bytes" || return 1
  check_message_source_size user "$user_message" "$user_message_path" "$payload_max_bytes" || return 1
  token=$(read_token "$name") || return 1
  request_tmpdir=$(mktemp -d) || return 1
  register_tmpfile "$request_tmpdir"
  auth_config_file="$request_tmpdir/auth.config"
  write_curl_auth_config "$name" "$token" "$auth_config_file" || {
    model_profile_http_cleanup_request "$request_tmpdir"
    return 1
  }
  printf '\033[1;34m[model-profile]\033[0m Sending request to %s model %s\n' "$name" "$model" >&2
  debug_log "Preparing chat completion request for profile '$name' model '$model'"
  debug_log "Provider type: $provider_type"
  debug_log "Request URL: ${request_url}"
  payload_file="$request_tmpdir/payload.json"
  if [ -n "$system_message_path" ]; then
    system_message_file=$system_message_path
  else
    system_message_file="$request_tmpdir/system-message.txt"
    printf '%s' "$system_message" >"$system_message_file"
  fi
  if [ -n "$user_message_path" ]; then
    user_message_file=$user_message_path
  else
    user_message_file="$request_tmpdir/user-message.txt"
    printf '%s' "$user_message" >"$user_message_file"
  fi
  jq -n \
    --arg model "$model" \
    --rawfile system_message "$system_message_file" \
    --rawfile user_message "$user_message_file" \
    '{model: $model, messages: [{role: "system", content: $system_message}, {role: "user", content: $user_message}]}' >"$payload_file"
  if [ -z "$system_message_path" ]; then
    rm -f "$system_message_file"
  fi
  if [ -z "$user_message_path" ]; then
    rm -f "$user_message_file"
  fi
  tmpfile="$request_tmpdir/response.json"
  response_fifo="$request_tmpdir/response.fifo"
  mkfifo "$response_fifo"
  payload_size=$(wc -c <"$payload_file")
  check_payload_size "$payload_file" "$payload_max_bytes" || {
    model_profile_http_cleanup_request "$request_tmpdir"
    return 1
  }
  debug_log "Payload size: ${payload_size} bytes"
  debug_log "Request limits: connect=${connect_timeout}s total=${total_timeout}s payload=${payload_max_bytes}B response=${response_max_bytes}B diagnostic=${diagnostic_max_bytes}B"

  curl_args=(
    -q
    -sS
    --proxy ''
    --noproxy '*'
    --max-redirs 0
    --proto '=https'
    --proto-redir '=https'
    --connect-timeout "$connect_timeout"
    --max-time "$total_timeout"
    -o "$response_fifo"
    -w '%{http_code}'
    --config "$auth_config_file"
    -H 'Content-Type: application/json'
    --data-binary "@$payload_file"
  )

  debug_log 'Starting HTTP request'

  head -c "$((response_max_bytes + 1))" <"$response_fifo" >"$tmpfile" &
  response_reader_pid=$!
  if http_code=$(picotools_ui_run_with_progress "Requesting model response from ${name}" curl "${curl_args[@]}" -- "$request_url"); then
    wait "$response_reader_pid" 2>/dev/null || true
  else
    stop_limited_response_reader "$response_reader_pid"
    rm -f "$response_fifo"
    if response_exceeded_limit "$tmpfile" "$response_max_bytes"; then
      echo "Error: response exceeded limit of $response_max_bytes bytes" >&2
      model_profile_http_cleanup_request "$request_tmpdir"
      return 1
    fi
    model_profile_http_cleanup_request "$request_tmpdir"
    return 1
  fi

  rm -f "$payload_file" "$response_fifo"
  debug_log "HTTP request completed with status $http_code"
  if response_exceeded_limit "$tmpfile" "$response_max_bytes"; then
    rm -f "$tmpfile"
    echo "Error: response exceeded limit of $response_max_bytes bytes" >&2
    model_profile_http_cleanup_request "$request_tmpdir"
    return 1
  fi

  if [[ "$http_code" != 2* ]]; then
    error_message=$(jq -r '.error.message // .message // empty' <"$tmpfile" 2>/dev/null || true)
    rm -f "$tmpfile"
    if [ -n "$error_message" ]; then
      error_message=$(sanitize_diagnostic_value "$error_message" "$diagnostic_max_bytes")
      echo "Error: $error_message" >&2
    else
      echo "Error: request failed with HTTP $http_code" >&2
    fi
    model_profile_http_cleanup_request "$request_tmpdir"
    return 1
  fi

  response_text=$(jq -r '.choices[0].message.content // empty' <"$tmpfile")
  response_size=$(wc -c <"$tmpfile")
  rm -f "$tmpfile"
  debug_log "Response size: ${response_size} bytes"

  if [ -z "$response_text" ]; then
    echo 'Error: response did not contain message content' >&2
    model_profile_http_cleanup_request "$request_tmpdir"
    return 1
  fi

  printf '%s\n' "$response_text"
  model_profile_http_cleanup_request "$request_tmpdir"
}
