#!/usr/bin/env bash

if [ "${PICOTOOLS_MODEL_PROFILE_PROVIDER_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_MODEL_PROFILE_PROVIDER_SH_LOADED=1

identity_name_error() {
  local kind="$1"

  echo "Error: $kind name may contain letters, numbers, single spaces, dots, underscores, and hyphens" >&2
}

validate_identity_name() {
  local kind="$1"
  local name="$2"

  if [ -z "$name" ] || [ "$name" = '.' ] || [ "$name" = '..' ] || [[ "$name" == .* ]]; then
    identity_name_error "$kind"
    return 1
  fi

  if [[ "$name" =~ [[:cntrl:]/\\|,] ]]; then
    identity_name_error "$kind"
    return 1
  fi

  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+(\ [A-Za-z0-9._-]+)*$ ]]; then
    identity_name_error "$kind"
    return 1
  fi
}

validate_profile_name_value() {
  local name="$1"

  validate_identity_name profile "$name"
}

validate_profile_name() {
  local name="$1"

  if ! validate_profile_name_value "$name"; then
    return 1
  fi
}

validate_model_name_value() {
  local name="$1"

  validate_identity_name model "$name"
}

validate_provider_type_value() {
  local provider_type="$1"

  if ! provider_registry_entry "$provider_type" >/dev/null; then
    echo "Error: provider type must be one of azure-openai, azure-cognitive-services, gemini, custom" >&2
    return 1
  fi
}

provider_registry_rows() {
  printf '%s\001%s\001%s\001%s\001%s\001%s\n' \
    1 azure-openai 'Azure OpenAI' resource 'https://%s.openai.azure.com/' 'https://%s.openai.azure.com/openai/v1/' \
    2 azure-cognitive-services 'Azure Cognitive Services' resource 'https://%s.cognitiveservices.azure.com/' 'https://%s.cognitiveservices.azure.com/openai/v1/' \
    3 gemini Gemini none '' 'https://generativelanguage.googleapis.com/v1beta/openai/' \
    4 custom Custom endpoint '%s' '%s'
}

provider_registry_entry() {
  local provider_type="$1"
  local choice type label location_field display_template base_template

  while IFS=$'\001' read -r choice type label location_field display_template base_template; do
    if [ "$type" = "$provider_type" ]; then
      printf '%s\001%s\001%s\001%s\001%s\001%s\n' "$choice" "$type" "$label" "$location_field" "$display_template" "$base_template"
      return 0
    fi
  done <<EOF
$(provider_registry_rows)
EOF

  return 1
}

provider_registry_field() {
  local provider_type="$1"
  local field="$2"
  local entry choice type label location_field display_template base_template

  entry=$(provider_registry_entry "$provider_type") || return 1
  IFS=$'\001' read -r choice type label location_field display_template base_template <<<"$entry"
  case "$field" in
  choice) printf '%s\n' "$choice" ;;
  type) printf '%s\n' "$type" ;;
  label) printf '%s\n' "$label" ;;
  location) printf '%s\n' "$location_field" ;;
  display-template) printf '%s\n' "$display_template" ;;
  base-template) printf '%s\n' "$base_template" ;;
  *) return 1 ;;
  esac
}

provider_type_label() {
  local provider_type="$1"

  provider_registry_field "$provider_type" label || printf '%s\n' "$provider_type"
}

provider_type_from_selection() {
  local selection="$1"
  local choice type label location_field display_template base_template

  while IFS=$'\001' read -r choice type label location_field display_template base_template; do
    if [ "$choice" = "$selection" ]; then
      printf '%s\n' "$type"
      return 0
    fi
  done <<EOF
$(provider_registry_rows)
EOF

  return 1
}

provider_prompt_labels() {
  local choice type label location_field display_template base_template

  while IFS=$'\001' read -r choice type label location_field display_template base_template; do
    printf '%s\n' "$label"
  done <<EOF
$(provider_registry_rows)
EOF
}

provider_format_template() {
  local template="$1"
  local value="$2"

  printf '%s\n' "${template/\%s/$value}"
}

provider_type_default_selection() {
  local provider_type="${1:-}"

  provider_registry_field "$provider_type" choice || printf '%s\n' '1'
}

validate_azure_resource_name_value() {
  local resource_name="$1"

  if [ -z "$resource_name" ]; then
    echo 'Error: Azure resource name is required' >&2
    return 1
  fi

  if [ "${#resource_name}" -gt 63 ]; then
    echo 'Error: Azure resource name must be 1-63 lowercase letters, numbers, or hyphens and start/end with a letter or number' >&2
    return 1
  fi

  if [[ ! "$resource_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo 'Error: Azure resource name must be 1-63 lowercase letters, numbers, or hyphens and start/end with a letter or number' >&2
    return 1
  fi
}

display_value() {
  picotools_display_value_or_dash "$1"
}

trim_spaces() {
  local value="$1"

  while [[ "$value" == ' '* ]]; do
    value=${value# }
  done
  while [[ "$value" == *' ' ]]; do
    value=${value% }
  done

  printf '%s\n' "$value"
}

normalize_models_value() {
  local value="$1"
  local -a parts=()
  local -a normalized_parts=()
  local part normalized_part joined=''

  IFS=',' read -r -a parts <<<"$value"

  for part in "${parts[@]}"; do
    normalized_part=$(trim_spaces "$part")

    if [ -n "$normalized_part" ]; then
      normalized_parts+=("$normalized_part")
    fi
  done

  for part in "${normalized_parts[@]}"; do
    if [ -n "$joined" ]; then
      joined+=','
    fi
    joined+="$part"
  done

  printf '%s\n' "$joined"
}

validate_models_value() {
  local models="$1"
  local model_item
  local -a model_items=()

  if [ -z "$models" ]; then
    echo 'Error: profile must configure at least one model' >&2
    return 1
  fi

  IFS=',' read -r -a model_items <<<"$models"

  for model_item in "${model_items[@]}"; do
    if [ -z "$model_item" ] || ! validate_model_name_value "$model_item"; then
      return 1
    fi
  done
}

provider_has_resource_name() {
  local provider_type="$1"

  [ "$(provider_registry_field "$provider_type" location 2>/dev/null || true)" = resource ]
}

provider_has_endpoint_url() {
  local provider_type="$1"

  [ "$(provider_registry_field "$provider_type" location 2>/dev/null || true)" = endpoint ]
}

normalize_endpoint_url_value() {
  local value="$1"

  value=$(trim_spaces "$value")

  if [ -n "$value" ] && [[ "$value" != */ ]]; then
    value+='/'
  fi

  printf '%s\n' "$value"
}

url_error() {
  echo "Error: invalid custom endpoint URL: $1" >&2
}

validate_port_value() {
  local port="$1"

  if [ -z "$port" ] || [[ ! "$port" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    return 1
  fi
}

validate_dns_hostname_value() {
  local host="$1"
  local label
  local -a labels=()

  if [ -z "$host" ] || [ "${#host}" -gt 253 ]; then
    return 1
  fi

  host=${host%.}
  if [ -z "$host" ]; then
    return 1
  fi

  IFS='.' read -r -a labels <<<"$host"
  for label in "${labels[@]}"; do
    if [ -z "$label" ] || [ "${#label}" -gt 63 ]; then
      return 1
    fi
    if [[ ! "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
      return 1
    fi
  done
}

validate_ipv4_literal_value() {
  local host="$1"
  local octet
  local -a octets=()

  if [[ ! "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi

  IFS='.' read -r -a octets <<<"$host"
  for octet in "${octets[@]}"; do
    if [ -z "$octet" ] || [ "$octet" -gt 255 ]; then
      return 1
    fi
  done
}

is_risky_ipv4_literal() {
  local host="$1"
  local a b
  local -a octets=()

  IFS='.' read -r -a octets <<<"$host"
  a=${octets[0]}
  b=${octets[1]}

  if [ "$a" -eq 0 ] || [ "$a" -eq 10 ] || [ "$a" -eq 127 ]; then
    return 0
  fi
  if [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; then
    return 0
  fi
  if [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; then
    return 0
  fi
  if [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; then
    return 0
  fi

  return 1
}

validate_endpoint_host_value() {
  local host="$1"
  local lower_host

  lower_host=${host,,}
  if [ "$lower_host" = localhost ] || [[ "$lower_host" == *.localhost ]]; then
    url_error 'localhost destinations are not supported'
    return 1
  fi

  if validate_ipv4_literal_value "$host"; then
    if is_risky_ipv4_literal "$host"; then
      url_error 'loopback, private, and link-local address literals are not supported'
      return 1
    fi
    return 0
  fi

  if [[ "$host" == *:* ]]; then
    url_error 'IPv6 address literals are not supported'
    return 1
  fi

  if ! validate_dns_hostname_value "$host"; then
    url_error 'host must be a valid DNS hostname or public IPv4 literal'
    return 1
  fi
}

url_scheme_authority() {
  local url="$1"
  local rest authority scheme

  scheme=${url%%://*}
  rest=${url#*://}
  authority=${rest%%[/?#]*}
  printf '%s://%s\n' "$scheme" "$authority"
}

validate_custom_endpoint_url_value() {
  local endpoint_url="$1"
  local scheme rest authority host port after_bracket

  if [ -z "$endpoint_url" ]; then
    url_error 'value is required'
    return 1
  fi
  if [[ "$endpoint_url" == -* ]]; then
    url_error 'value must not look like an option'
    return 1
  fi
  if [[ "$endpoint_url" =~ [[:cntrl:]] ]]; then
    url_error 'control characters are not allowed'
    return 1
  fi
  if [[ "$endpoint_url" =~ [[:space:]] ]]; then
    url_error 'whitespace is not allowed'
    return 1
  fi
  if [[ ! "$endpoint_url" =~ ^([A-Za-z][A-Za-z0-9+.-]*):// ]]; then
    url_error 'explicit https:// scheme is required'
    return 1
  fi

  scheme=${BASH_REMATCH[1],,}
  if [ "$scheme" != https ]; then
    url_error 'only https:// endpoints are supported'
    return 1
  fi

  rest=${endpoint_url#*://}
  authority=${rest%%[/?#]*}
  if [ -z "$authority" ]; then
    url_error 'authority is required'
    return 1
  fi
  if [[ "$authority" == *@* ]]; then
    url_error 'userinfo is not allowed'
    return 1
  fi
  if [[ "$rest" == *'#'* ]]; then
    url_error 'fragments are not allowed'
    return 1
  fi
  if [[ "$rest" == *'?'* ]]; then
    url_error 'query strings are not supported'
    return 1
  fi

  if [[ "$authority" == \[* ]]; then
    if [[ ! "$authority" =~ ^\[[^]]+\](:[0-9]*)?$ ]]; then
      url_error 'malformed authority'
      return 1
    fi
    host=${authority#\[}
    host=${host%%\]*}
    after_bracket=${authority#*\]}
    port=${after_bracket#:}
    if [ -n "$after_bracket" ] && ! validate_port_value "$port"; then
      url_error 'malformed port'
      return 1
    fi
  else
    if [[ "$authority" == *'['* || "$authority" == *']'* ]]; then
      url_error 'malformed authority'
      return 1
    fi
    if [[ "$authority" == *:* ]]; then
      host=${authority%%:*}
      port=${authority#*:}
      if [[ "$port" == *:* ]] || ! validate_port_value "$port"; then
        url_error 'malformed port'
        return 1
      fi
    else
      host=$authority
    fi
  fi

  if [ -z "$host" ]; then
    url_error 'host is required'
    return 1
  fi
  if ! validate_endpoint_host_value "$host"; then
    return 1
  fi

  printf '%s\n' "$endpoint_url"
}

provider_chat_completions_url() {
  local base_url="$1"
  local base_origin request_url request_origin

  if ! validate_custom_endpoint_url_value "$base_url" >/dev/null; then
    return 1
  fi

  base_origin=$(url_scheme_authority "$base_url")
  request_url="${base_url}chat/completions"
  if ! validate_custom_endpoint_url_value "$request_url" >/dev/null; then
    return 1
  fi
  request_origin=$(url_scheme_authority "$request_url")
  if [ "$request_origin" != "$base_origin" ]; then
    echo 'Error: resolved request URL changed endpoint authority' >&2
    return 1
  fi

  printf '%s\n' "$request_url"
}

provider_endpoint() {
  local provider_type="$1"
  local resource_name="$2"
  local endpoint_url="${3:-}"
  local location_field template location_value

  location_field=$(provider_registry_field "$provider_type" location) || return 1
  template=$(provider_registry_field "$provider_type" display-template) || return 1
  case "$location_field" in
  resource) location_value="$resource_name" ;;
  endpoint) location_value="$endpoint_url" ;;
  none) return 0 ;;
  *) return 1 ;;
  esac
  if [ -z "$location_value" ]; then
    return 0
  fi
  provider_format_template "$template" "$location_value"
}

provider_openai_base_url() {
  local provider_type="$1"
  local resource_name="$2"
  local endpoint_url="${3:-}"
  local location_field template location_value

  location_field=$(provider_registry_field "$provider_type" location) || {
    echo "Error: unsupported provider type '$provider_type'" >&2
    return 1
  }
  template=$(provider_registry_field "$provider_type" base-template) || return 1
  case "$location_field" in
  resource) location_value="$resource_name" ;;
  endpoint) location_value="$endpoint_url" ;;
  none)
    printf '%s\n' "$template"
    return 0
    ;;
  *) return 1 ;;
  esac
  provider_format_template "$template" "$location_value"
}
