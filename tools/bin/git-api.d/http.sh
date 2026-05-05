#!/usr/bin/env bash

git_api_build_query_string() {
  local query joined='' pair key value

  for query in "$@"; do
    [ "$query" = '--headers' ] && break
    key=${query%%=*}
    value=${query#*=}
    if [ -n "$joined" ]; then
      joined+='&'
    fi
    joined+="$(git_api_urlencode "$key")=$(git_api_urlencode "$value")"
  done

  printf '%s\n' "$joined"
}

git_api_json_body_from_fields() {
  local pair key value
  local -a jq_args=()

  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    jq_args+=(--arg "$key" "$value")
  done

  jq -cn "${jq_args[@]}" '$ARGS.named'
}

git_api_print_response() {
  local body="$1"

  if [ -z "$body" ]; then
    return 0
  fi

  if printf '%s' "$body" | jq -e '.' >/dev/null 2>&1; then
    printf '%s' "$body" | jq '.'
  else
    printf '%s\n' "$body"
  fi
}

git_api_request() {
  local method="$1"
  local api_root="$2"
  local api_version="$3"
  local path="$4"
  local body_file="$5"
  shift 5
  local -a query_args=()
  local -a header_args=()
  local -a field_args=()
  local pair key value token query_string url tmpfile http_code body
  local section='queries'
  local response_message=''

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --headers)
      section='headers'
      shift
      continue
      ;;
    --fields)
      section='fields'
      shift
      continue
      ;;
    esac

    case "$section" in
    queries)
      query_args+=("$1")
      ;;
    headers)
      header_args+=("$1")
      ;;
    fields)
      field_args+=("$1")
      ;;
    esac
    shift
  done

  query_string=$(git_api_build_query_string "${query_args[@]}")
  url="${api_root}${path}"
  if [ -n "$query_string" ]; then
    url+="?${query_string}"
  fi

  token=$(git_api_token)
  tmpfile=$(mktemp)

  if [ -n "$body_file" ] && [ "${#field_args[@]}" -gt 0 ]; then
    echo 'Error: use either --field or --body-file, not both' >&2
    rm -f "$tmpfile"
    exit 1
  fi

  set -- curl -sS -X "${method^^}" -w '%{http_code}' -o "$tmpfile" \
    -H 'Accept: application/vnd.github+json' \
    -H "X-GitHub-Api-Version: $api_version"

  if [ -n "$token" ]; then
    set -- "$@" -H "Authorization: Bearer $token"
  fi

  for pair in "${header_args[@]}"; do
    key=${pair%%=*}
    value=${pair#*=}
    set -- "$@" -H "$key: $value"
  done

  if [ -n "$body_file" ]; then
    set -- "$@" -H 'Content-Type: application/json' --data-binary "@$body_file"
  elif [ "${#field_args[@]}" -gt 0 ]; then
    response_message=$(git_api_json_body_from_fields "${field_args[@]}")
    set -- "$@" -H 'Content-Type: application/json' --data "$response_message"
  fi

  http_code=$("$@" "$url")
  body=$(<"$tmpfile")
  rm -f "$tmpfile"

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    git_api_print_response "$body"
    return 0
  fi

  response_message=$(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null || true)
  echo "API error (HTTP ${http_code}): ${response_message:-$body}" >&2
  exit 1
}
