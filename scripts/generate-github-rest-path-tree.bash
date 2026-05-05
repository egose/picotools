#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_ROOT="${REPO_ROOT}/tools/lib/picotools/git-api"
OUTPUT_DIR="${OUTPUT_ROOT}/github-rest-path-tree"
INDEX_FILE="${OUTPUT_ROOT}/operation-id-index.json"
SPEC_FILE="${OUTPUT_ROOT}/api.github.com.json"
METADATA_FILE="${OUTPUT_ROOT}/metadata.json"
SOURCE_URL='https://api.github.com/repos/github/rest-api-description/contents/descriptions/api.github.com?ref=main'
LATEST_NAME=''
DOWNLOAD_URL=''

usage() {
  cat <<'EOF'
Usage: scripts/generate-github-rest-path-tree.bash [--output-root DIR]

Fetches the latest dated api.github.com JSON description from the GitHub
rest-api-description repository, stores it under tools/lib/picotools/git-api,
and generates a nested path tree with one JSON file per HTTP method.

Examples:
  scripts/generate-github-rest-path-tree.bash
  scripts/generate-github-rest-path-tree.bash --output-root tools/lib/picotools/git-api
EOF
}

require_commands() {
  local command_name

  for command_name in base64 curl jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Error: ${command_name} is required but not installed" >&2
      exit 1
    fi
  done
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --output-root)
      [ "$#" -ge 2 ] || {
        echo 'Error: --output-root requires a directory path' >&2
        exit 1
      }
      OUTPUT_ROOT="$2"
      OUTPUT_DIR="${OUTPUT_ROOT}/github-rest-path-tree"
      INDEX_FILE="${OUTPUT_ROOT}/operation-id-index.json"
      SPEC_FILE="${OUTPUT_ROOT}/api.github.com.json"
      METADATA_FILE="${OUTPUT_ROOT}/metadata.json"
      shift 2
      ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
    esac
  done
}

github_auth_header() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s\n' "Authorization: Bearer ${GH_TOKEN}"
    return 0
  fi

  if [ -n "${GITHUB_PAT:-}" ]; then
    printf '%s\n' "Authorization: Bearer ${GITHUB_PAT}"
    return 0
  fi

  printf '%s\n' ''
}

fetch_latest_spec() {
  local auth_header
  local listing_file
  local -a curl_args=()

  auth_header=$(github_auth_header)
  listing_file=$(mktemp)

  curl_args=(-fsSL -H 'Accept: application/vnd.github+json')
  if [ -n "$auth_header" ]; then
    curl_args+=(-H "$auth_header")
  fi

  curl "${curl_args[@]}" "$SOURCE_URL" >"$listing_file"

  LATEST_NAME=$(jq -r '
    [
      .[]
      | select(.type == "file")
      | select(.name | test("^api\\.github\\.com\\.[0-9]{4}-[0-9]{2}-[0-9]{2}\\.json$"))
      | .name
    ]
    | sort
    | last // empty
  ' "$listing_file")

  if [ -z "$LATEST_NAME" ]; then
    rm -f "$listing_file"
    echo 'Error: could not determine the latest dated api.github.com JSON file' >&2
    exit 1
  fi

  DOWNLOAD_URL=$(jq -r --arg latest_name "$LATEST_NAME" '
    .[]
    | select(.name == $latest_name)
    | .download_url // empty
  ' "$listing_file")
  rm -f "$listing_file"

  if [ -z "$DOWNLOAD_URL" ]; then
    echo "Error: could not determine the download URL for $LATEST_NAME" >&2
    exit 1
  fi

  mkdir -p "$OUTPUT_ROOT"
  curl "${curl_args[@]}" "$DOWNLOAD_URL" >"$SPEC_FILE"
  printf 'Downloaded %s to %s\n' "$LATEST_NAME" "$SPEC_FILE"
}

write_metadata() {
  jq -n \
    --arg source_api_url "$SOURCE_URL" \
    --arg source_download_url "$DOWNLOAD_URL" \
    --arg source_file_name "$LATEST_NAME" \
    --arg spec_file "$SPEC_FILE" \
    --arg index_file "$INDEX_FILE" \
    --arg path_tree_dir "$OUTPUT_DIR" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      sourceApiUrl: $source_api_url,
      sourceDownloadUrl: $source_download_url,
      sourceFileName: $source_file_name,
      specFile: $spec_file,
      indexFile: $index_file,
      pathTreeDir: $path_tree_dir,
      generatedAt: $generated_at
    }' >"$METADATA_FILE"

  printf 'Generated metadata %s\n' "$METADATA_FILE"
}

generate_tree() {
  local operation_file
  local operation_count=0
  local operation_json_base64
  local path_dir
  local tmp_index_file

  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"

  while IFS=$'\t' read -r rest_path method operation_json_base64; do
    [ -n "$rest_path" ] || continue
    path_dir="${OUTPUT_DIR}${rest_path}"
    mkdir -p "$path_dir"
    operation_file="${path_dir}/${method}.json"
    printf '%s' "$operation_json_base64" | base64 --decode | jq '.' >"$operation_file"
    operation_count=$((operation_count + 1))
  done < <(
    jq -r '
      .paths
      | to_entries[]
      | .key as $path
      | .value
      | to_entries[]
      | select(.key | IN("get", "post", "put", "patch", "delete", "head", "options", "trace"))
      | [$path, .key, (.value | @base64)]
      | @tsv
    ' "$SPEC_FILE"
  )

  tmp_index_file=$(mktemp)
  while IFS= read -r operation_file; do
    printf '%s\t%s\n' \
      "$(jq -r '.operationId // empty' "$operation_file")" \
      "${operation_file#"$OUTPUT_DIR/"}"
  done < <(find "$OUTPUT_DIR" -type f -name '*.json' | sort) |
    jq -Rn '
      reduce inputs as $line ({};
        ($line | split("\t")) as $parts |
        if ($parts | length) == 2 and ($parts[0] | length) > 0 then
          . + {($parts[0]): $parts[1]}
        else
          .
        end
      )
    ' >"$tmp_index_file"

  mv "$tmp_index_file" "$INDEX_FILE"

  printf 'Generated %s operation files in %s\n' "$operation_count" "$OUTPUT_DIR"
  printf 'Generated operation index %s\n' "$INDEX_FILE"
}

main() {
  require_commands
  parse_args "$@"
  fetch_latest_spec
  generate_tree
  write_metadata
}

main "$@"
