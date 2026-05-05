#!/usr/bin/env bash

git_api_operation_relative_path() {
  local script_dir="$1"
  local operation_id="$2"
  local index_file relative_path

  index_file=$(git_api_operation_index_file "$script_dir")
  if [ ! -f "$index_file" ]; then
    echo "Error: git-api operation index is missing: $index_file" >&2
    exit 1
  fi

  relative_path=$(jq -r --arg operation_id "$operation_id" '.[$operation_id] // empty' "$index_file")
  if [ -z "$relative_path" ]; then
    echo "Error: unsupported operation '$operation_id'" >&2
    exit 1
  fi

  printf '%s\n' "$relative_path"
}

git_api_operation_file() {
  local script_dir="$1"
  local operation_id="$2"
  local file

  file="$(git_api_path_tree_dir "$script_dir")/$(git_api_operation_relative_path "$script_dir" "$operation_id")"
  if [ ! -f "$file" ]; then
    echo "Error: operation file is missing for '$operation_id'" >&2
    exit 1
  fi

  printf '%s\n' "$file"
}

git_api_operation_method() {
  local relative_path="$1"
  basename "$relative_path" .json
}

git_api_operation_rest_path() {
  local relative_path="$1"
  local path_dir

  path_dir=$(dirname "$relative_path")
  printf '/%s\n' "$path_dir"
}

git_api_list_operations() {
  local script_dir="$1"
  local prefix="${2:-}"
  local operation_id relative_path file method rest_path summary

  while IFS= read -r operation_id; do
    if [ -n "$prefix" ]; then
      case "$operation_id" in
      "$prefix"*) ;;
      *) continue ;;
      esac
    fi
    relative_path=$(git_api_operation_relative_path "$script_dir" "$operation_id")
    file="$(git_api_path_tree_dir "$script_dir")/$relative_path"
    method=$(git_api_operation_method "$relative_path")
    rest_path=$(git_api_operation_rest_path "$relative_path")
    summary=$(jq -r '.summary // empty' "$file")
    printf '%s\t%s\t%s\t%s\n' "$operation_id" "$method" "$rest_path" "$summary"
  done < <(jq -r 'keys[]' "$(git_api_operation_index_file "$script_dir")")
}

git_api_operation_docs_url() {
  local file="$1"
  jq -r '.externalDocs.url // empty' "$file"
}

git_api_operation_summary() {
  local file="$1"
  jq -r '.summary // empty' "$file"
}

git_api_operation_description() {
  local file="$1"
  jq -r '.description // empty' "$file"
}

git_api_operation_query_parameters() {
  local script_dir="$1"
  local file="$2"
  local spec_file

  spec_file=$(git_api_spec_file "$script_dir")
  jq -r --slurpfile spec "$spec_file" '
    [
      .parameters[]? |
      if has("$ref") then
        ($spec[0].components.parameters[(.["$ref"] | split("/")[-1])])
      else
        .
      end |
      select(.in == "query") |
      [.name, ((.required // false) | tostring), (.description // "")]
    ] | .[] | @tsv
  ' "$file"
}

git_api_operation_body_fields() {
  local file="$1"

  jq -r '
    .requestBody.content["application/json"].schema as $schema |
    if ($schema.properties // null) == null then
      empty
    else
      ($schema.required // []) as $required |
      $schema.properties | to_entries[] |
      [.key, (if ($required | index(.key)) then "true" else "false" end), (.value.description // "")]
    end | @tsv
  ' "$file" 2>/dev/null || true
}
