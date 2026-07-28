#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/gh-repo-sync"
REAL_JQ_BIN="$(asdf which jq 2>/dev/null || command -v jq)"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export HOME="$TMP_DIR/home"
  export XDG_DATA_HOME="$TMP_DIR/data"
  export PATH="$TMP_DIR/bin:$PATH"

  mkdir -p "$HOME" "$XDG_DATA_HOME" "$TMP_DIR/bin" "$TMP_DIR/workspace"

  cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=''
url=''

while [ "$#" -gt 0 ]; do
  case "$1" in
  -o)
    output_file="$2"
    shift 2
    ;;
  -H | -w | --retry | --retry-delay)
    shift 2
    ;;
  -s | -S | -L | --retry-all-errors)
    shift
    ;;
  *)
    url="$1"
    shift
    ;;
  esac
done

if [[ "$url" =~ /orgs/([^/]+)/repos\?per_page=100\&page=([0-9]+)$ ]] || [[ "$url" =~ /users/([^/]+)/repos\?per_page=100\&page=([0-9]+)$ ]]; then
  owner="${BASH_REMATCH[1]}"
  page="${BASH_REMATCH[2]}"
  fixture="${GH_REPO_SYNC_FIXTURES_DIR}/api-${owner}-page-${page}.json"
  if [ -f "$fixture" ]; then
    cp "$fixture" "$output_file"
  else
    printf '[]' >"$output_file"
  fi
  printf '200'
  exit 0
fi

if [[ "$url" =~ /repos/([^/]+)/([^/]+)/zipball/([^/?]+)$ ]]; then
  owner="${BASH_REMATCH[1]}"
  repo="${BASH_REMATCH[2]}"
  branch="${BASH_REMATCH[3]}"
  if [ "${GH_REPO_SYNC_FAIL_ARCHIVE_FOR:-}" = "${owner}/${repo}" ]; then
    printf '{"message":"archive unavailable"}' >"$output_file"
    printf '503'
    exit 0
  fi

  fixture="${GH_REPO_SYNC_FIXTURES_DIR}/archive-${owner}-${repo}-${branch}.txt"
  if [ -f "$fixture" ]; then
    cp "$fixture" "$output_file"
    printf '200'
    exit 0
  fi
fi

printf '{"message":"not found"}' >"$output_file"
printf '404'
EOF
  chmod +x "$TMP_DIR/bin/curl"

  cat >"$TMP_DIR/bin/unzip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = '-tq' ]; then
  archive_path="$2"
  if grep -q '^invalid_archive=true$' "$archive_path"; then
    exit 1
  fi
  exit 0
fi

archive_path=''
destination=''

while [ "$#" -gt 0 ]; do
  case "$1" in
  -d)
    destination="$2"
    shift 2
    ;;
  -q | -o | -qo)
    shift
    ;;
  *)
    archive_path="$1"
    shift
    ;;
  esac
done

top_dir=''
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
  top_dir=*)
    top_dir="${line#top_dir=}"
    mkdir -p "$destination/$top_dir"
    ;;
  file=*)
    payload="${line#file=}"
    relative_path="${payload%%|*}"
    content="${payload#*|}"
    mkdir -p "$(dirname "$destination/$top_dir/$relative_path")"
    printf '%s\n' "$content" >"$destination/$top_dir/$relative_path"
    ;;
  esac
done <"$archive_path"
EOF
  chmod +x "$TMP_DIR/bin/unzip"

  ln -s "$REAL_JQ_BIN" "$TMP_DIR/bin/jq"

  export GH_REPO_SYNC_FIXTURES_DIR="$TMP_DIR/fixtures"
  mkdir -p "$GH_REPO_SYNC_FIXTURES_DIR"
}

teardown() {
  rm -rf "$TMP_DIR"
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

assert_file_not_exists() {
  local path="$1"
  local message="$2"

  if [ -e "$path" ]; then
    fail "$message ($path)"
  fi
}

assert_file_exists() {
  local path="$1"
  local message="$2"

  if [ ! -e "$path" ]; then
    fail "$message ($path)"
  fi
}

workspace_dir() {
  printf '%s/workspace\n' "$TMP_DIR"
}

write_api_fixture() {
  local owner="$1"
  local page="$2"
  local content="$3"

  printf '%s\n' "$content" >"$GH_REPO_SYNC_FIXTURES_DIR/api-${owner}-page-${page}.json"
}

write_archive_fixture() {
  local owner="$1"
  local repo="$2"
  local branch="$3"
  local top_dir="$4"
  local relative_path="$5"
  local file_content="$6"

  printf 'top_dir=%s\nfile=%s|%s\n' "$top_dir" "$relative_path" "$file_content" >"$GH_REPO_SYNC_FIXTURES_DIR/archive-${owner}-${repo}-${branch}.txt"
}

run_sync() {
  local workspace="$1"
  local owner_input="$2"

  run bash -c 'cd "$1" && printf "\n%s\n" "$2" | "$3"' _ "$workspace" "$owner_input" "$TOOL"
}

@test "shows help text" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'gh-repo-sync --help should succeed'
  assert_contains "$output" 'Usage: gh-repo-sync [--reset-pat]' 'help should describe the entrypoint'
  assert_contains "$output" '--reset-pat' 'help should document PAT reset support'
  assert_contains "$output" '--debug' 'help should document debug support'
}

@test "resets the stored PAT file" {
  local pat_file

  pat_file="$XDG_DATA_HOME/gh-repo-sync/pat"
  mkdir -p "$(dirname "$pat_file")"
  printf '%s\n' 'secret-token' >"$pat_file"

  run "$TOOL" --reset-pat

  [ "$status" -eq 0 ] || fail 'gh-repo-sync --reset-pat should succeed'
  assert_contains "$output" 'PAT has been reset.' 'should confirm the reset'
  assert_file_not_exists "$pat_file" 'should remove the stored PAT file'
}

@test "fails when the repository owner name is left blank" {
  run bash -c 'cd "$1" && printf "\n\n" | "$2"' _ "$TMP_DIR" "$TOOL"

  [ "$status" -eq 1 ] || fail 'gh-repo-sync should fail when no owner name is provided'
  assert_contains "$output" 'Continuing without authentication' 'should allow running without a PAT'
  assert_contains "$output" 'Error: name cannot be empty' 'should explain why execution stopped'
}

@test "syncs repos into stable owner-scoped directories and owner-qualified cache keys" {
  local workspace repo_file cache_value

  workspace="$(workspace_dir)"
  write_api_fixture octo 1 '[{"name":"demo","owner":{"login":"octo"},"default_branch":"main","updated_at":"2026-07-01T00:00:00Z"}]'
  write_api_fixture octo 2 '[]'
  write_archive_fixture octo demo main octo-demo-a1b2c3 README.md first-sync

  run_sync "$workspace" octo

  [ "$status" -eq 0 ] || fail 'gh-repo-sync should sync a repo successfully'
  repo_file="$workspace/repos/octo/demo/README.md"
  assert_file_exists "$repo_file" 'should place the repo under repos/<owner>/<repo>'
  assert_eq "$(<"$repo_file")" 'first-sync' 'should extract the synced repo contents'
  cache_value="$(jq -r '.["octo/demo"]' "$workspace/repo-updates.json")"
  assert_eq "$cache_value" '2026-07-01T00:00:00Z' 'should cache the update timestamp under owner/repo'
  assert_file_not_exists "$workspace/repos/demo-main" 'should not rely on branch-named repo directories'
  assert_file_not_exists "$workspace/repos/octo-demo-a1b2c3" 'should not leave extracted top-level dirs behind'
}

@test "skips unchanged repos based on owner-qualified cache entries" {
  local workspace repo_file

  workspace="$(workspace_dir)"
  write_api_fixture octo 1 '[{"name":"demo","owner":{"login":"octo"},"default_branch":"main","updated_at":"2026-07-01T00:00:00Z"}]'
  write_api_fixture octo 2 '[]'
  write_archive_fixture octo demo main octo-demo-a1b2c3 README.md first-sync

  run_sync "$workspace" octo
  [ "$status" -eq 0 ] || fail 'first sync should succeed'

  repo_file="$workspace/repos/octo/demo/README.md"
  printf '%s\n' 'manually-kept' >"$repo_file"

  run_sync "$workspace" octo

  [ "$status" -eq 0 ] || fail 'second sync should succeed'
  assert_contains "$output" 'Skipping octo/demo (no updates since last run)' 'should skip unchanged repos using the owner-qualified cache key'
  assert_eq "$(<"$repo_file")" 'manually-kept' 'should leave unchanged repos untouched when the cache matches'
}

@test "refreshes updated repos by replacing the stable target directory" {
  local workspace repo_file obsolete_file

  workspace="$(workspace_dir)"
  write_api_fixture octo 1 '[{"name":"demo","owner":{"login":"octo"},"default_branch":"main","updated_at":"2026-07-01T00:00:00Z"}]'
  write_api_fixture octo 2 '[]'
  write_archive_fixture octo demo main octo-demo-a1b2c3 README.md first-sync

  run_sync "$workspace" octo
  [ "$status" -eq 0 ] || fail 'initial sync should succeed'

  repo_file="$workspace/repos/octo/demo/README.md"
  obsolete_file="$workspace/repos/octo/demo/obsolete.txt"
  printf '%s\n' 'obsolete' >"$obsolete_file"

  write_api_fixture octo 1 '[{"name":"demo","owner":{"login":"octo"},"default_branch":"main","updated_at":"2026-07-02T00:00:00Z"}]'
  write_archive_fixture octo demo main octo-demo-d4e5f6 README.md refreshed-sync

  run_sync "$workspace" octo

  [ "$status" -eq 0 ] || fail 'updated sync should succeed'
  assert_eq "$(<"$repo_file")" 'refreshed-sync' 'should replace the repo contents when the repo is updated'
  assert_file_not_exists "$obsolete_file" 'should replace the stable target directory instead of merging extracted contents'
  assert_file_not_exists "$workspace/repos/octo-demo-d4e5f6" 'should clean up transient extracted directories after refresh'
}

@test "keeps owners with same repo names isolated in both filesystem state and cache" {
  local workspace alice_file bob_file alice_cache bob_cache

  workspace="$(workspace_dir)"
  write_api_fixture alice 1 '[{"name":"demo","owner":{"login":"alice"},"default_branch":"main","updated_at":"2026-07-01T00:00:00Z"}]'
  write_api_fixture alice 2 '[]'
  write_api_fixture bob 1 '[{"name":"demo","owner":{"login":"bob"},"default_branch":"main","updated_at":"2026-07-03T00:00:00Z"}]'
  write_api_fixture bob 2 '[]'
  write_archive_fixture alice demo main alice-demo-a1 README.md alice-sync
  write_archive_fixture bob demo main bob-demo-b2 README.md bob-sync

  run_sync "$workspace" alice
  [ "$status" -eq 0 ] || fail 'alice sync should succeed'

  run_sync "$workspace" bob
  [ "$status" -eq 0 ] || fail 'bob sync should succeed'

  alice_file="$workspace/repos/alice/demo/README.md"
  bob_file="$workspace/repos/bob/demo/README.md"
  assert_eq "$(<"$alice_file")" 'alice-sync' 'should keep alice repo contents isolated'
  assert_eq "$(<"$bob_file")" 'bob-sync' 'should keep bob repo contents isolated'
  alice_cache="$(jq -r '.["alice/demo"]' "$workspace/repo-updates.json")"
  bob_cache="$(jq -r '.["bob/demo"]' "$workspace/repo-updates.json")"
  assert_eq "$alice_cache" '2026-07-01T00:00:00Z' 'should store alice cache entry separately'
  assert_eq "$bob_cache" '2026-07-03T00:00:00Z' 'should store bob cache entry separately'
}

@test "keeps the previous repo contents when an updated archive download fails" {
  local workspace repo_file cache_value

  workspace="$(workspace_dir)"
  write_api_fixture octo 1 '[{"name":"demo","owner":{"login":"octo"},"default_branch":"main","updated_at":"2026-07-01T00:00:00Z"}]'
  write_api_fixture octo 2 '[]'
  write_archive_fixture octo demo main octo-demo-a1b2c3 README.md first-sync

  run_sync "$workspace" octo
  [ "$status" -eq 0 ] || fail 'initial sync should succeed'

  repo_file="$workspace/repos/octo/demo/README.md"
  write_api_fixture octo 1 '[{"name":"demo","owner":{"login":"octo"},"default_branch":"main","updated_at":"2026-07-04T00:00:00Z"}]'

  # shellcheck disable=SC2016
  run env GH_REPO_SYNC_FAIL_ARCHIVE_FOR='octo/demo' bash -c 'cd "$1" && printf "\n%s\n" "$2" | "$3"' _ "$workspace" octo "$TOOL"

  [ "$status" -eq 0 ] || fail 'sync should continue even when one download fails'
  assert_contains "$output" 'Failed to download octo/demo' 'should report the failed archive download'
  assert_eq "$(<"$repo_file")" 'first-sync' 'should leave the previous repo contents intact after a failed refresh'
  cache_value="$(jq -r '.["octo/demo"]' "$workspace/repo-updates.json")"
  assert_eq "$cache_value" '2026-07-01T00:00:00Z' 'should keep the previous cache value when the refresh fails'
}
