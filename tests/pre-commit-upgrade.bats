#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/pre-commit-upgrade"

setup() {
  TMP_DIR="$(mktemp -d)" || return 1
  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"
  mkdir -p "$TMP_DIR/bin"

  cat >"$TMP_DIR/bin/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != 'autoupdate' ]; then
  echo "unexpected pre-commit invocation: $*" >&2
  exit 1
fi

shift

freeze_mode=false
repo=''
config_file=''
freeze_suffix=''

while [ "$#" -gt 0 ]; do
  case "$1" in
  --freeze)
    freeze_mode=true
    shift
    ;;
  --repo)
    repo="${2:-}"
    shift 2
    ;;
  --config)
    config_file="${2:-}"
    shift 2
    ;;
  *)
    echo "unexpected pre-commit invocation: autoupdate $*" >&2
    exit 1
    ;;
  esac
done

if [ -z "$config_file" ]; then
  echo 'missing --config argument' >&2
  exit 1
fi

if [ "$freeze_mode" = 'true' ]; then
  freeze_suffix=' --freeze'
fi

if [ -n "${PRE_COMMIT_LOG:-}" ]; then
  if [ -n "$repo" ]; then
    printf 'autoupdate%s --repo %s --config %s\n' "$freeze_suffix" "$repo" "$config_file" >>"$PRE_COMMIT_LOG"
  else
    printf 'autoupdate%s --config %s\n' "$freeze_suffix" "$config_file" >>"$PRE_COMMIT_LOG"
  fi
fi

if [ -n "${PRE_COMMIT_EXPECT_CONFIG:-}" ] && [ "$config_file" != "$PRE_COMMIT_EXPECT_CONFIG" ]; then
  echo "unexpected config file: $config_file" >&2
  exit 1
fi

if [ -n "${PRE_COMMIT_STDOUT:-}" ]; then
  printf '%s\n' "$PRE_COMMIT_STDOUT"
fi

content=$(<"$config_file")

replace_pre_commit_hooks_repo() {
  local value="$1"

  content="${content//rev: v1.0.0/rev: ${value}}"
  content="${content//rev: v1.2.0/rev: ${value}}"
  content="${content//rev: "v1.0.0"/rev: "${value}"}"
  content="${content//rev: "v1.2.0"/rev: "${value}"}"
  content="${content//rev: &hooks_rev v1.0.0/rev: &hooks_rev ${value}}"
  content="${content//rev: &hooks_rev v1.2.0/rev: &hooks_rev ${value}}"
}

replace_black_repo() {
  local value="$1"

  content="${content//rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v22.0.0/rev: ${value}}"
  content="${content//rev: v23.0.0/rev: ${value}}"
  content="${content//rev: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v23.0.0/rev: ${value}}"
  content="${content//rev: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # frozen: v22.0.0/rev: "${value}"}"
  content="${content//rev: "v23.0.0"/rev: "${value}"}"
  content="${content//rev: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" # frozen: v23.0.0/rev: "${value}"}"
  content="${content//rev: &black_rev aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v22.0.0/rev: &black_rev ${value}}"
  content="${content//rev: &black_rev bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v23.0.0/rev: &black_rev ${value}}"
}

if [ -n "${PRE_COMMIT_OLD_REV:-}" ] && [ -n "${PRE_COMMIT_NEW_REV:-}" ]; then
  content="${content//${PRE_COMMIT_OLD_REV}/${PRE_COMMIT_NEW_REV}}"
fi

if [ "$freeze_mode" = 'true' ]; then
  case "$repo" in
  '' | https://github.com/pre-commit/pre-commit-hooks)
    replace_pre_commit_hooks_repo '1111111111111111111111111111111111111111 # frozen: v1.2.0'
    ;;
  esac

  case "$repo" in
  '' | https://github.com/psf/black)
    replace_black_repo 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v23.0.0'
    ;;
  esac
else
  case "$repo" in
  '' | https://github.com/pre-commit/pre-commit-hooks)
    replace_pre_commit_hooks_repo 'v1.2.0'
    ;;
  esac

  case "$repo" in
  '' | https://github.com/psf/black)
    replace_black_repo 'v23.0.0'
    ;;
  esac
fi

printf '%s\n' "$content" >"$config_file"
EOF
  chmod +x "$TMP_DIR/bin/pre-commit"
}

teardown() {
  rm -rf "$TMP_DIR"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
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

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [ "$actual" != "$expected" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

run_in_dir() {
  local dir="$1"

  shift
  (
    cd "$dir" || exit 1
    "$@"
  )
}

@test "uses .pre-commit-config.yaml by default" {
  local work_dir config_file log_file

  work_dir="$TMP_DIR/work"
  config_file="$work_dir/.pre-commit-config.yaml"
  log_file="$TMP_DIR/pre-commit.log"
  mkdir -p "$work_dir"

  cat >"$config_file" <<'EOF'
repos:
- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v1.0.0
  hooks:
  - id: trailing-whitespace
EOF

  PRE_COMMIT_LOG="$log_file" \
    PRE_COMMIT_EXPECT_CONFIG='.pre-commit-config.yaml' \
    PRE_COMMIT_OLD_REV='v1.0.0' \
    PRE_COMMIT_NEW_REV='v1.2.0' \
    run run_in_dir "$work_dir" "$TOOL" --debug

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade should succeed for the default config file'
  assert_contains "$output" "[pre-commit-upgrade] Running pre-commit autoupdate for '.pre-commit-config.yaml'" 'debug mode should log the selected config path'
  assert_contains "$output" 'Updated pre-commit hook versions in .pre-commit-config.yaml.' 'tool should report when the default config changed'
  assert_contains "$(<"$log_file")" 'autoupdate --config .pre-commit-config.yaml' 'tool should call pre-commit autoupdate with the default config path'
  assert_eq "$(<"$config_file")" $'repos:\n- repo: https://github.com/pre-commit/pre-commit-hooks\n  rev: v1.2.0\n  hooks:\n  - id: trailing-whitespace' 'tool should rewrite the default config file in place'
}

@test "preserves each repo ref style by default" {
  local config_file log_file expected_log

  config_file="$TMP_DIR/.pre-commit-config.yaml"
  log_file="$TMP_DIR/pre-commit.log"

  cat >"$config_file" <<'EOF'
repos:
- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v1.0.0
  hooks:
  - id: trailing-whitespace
- repo: https://github.com/psf/black
  rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v22.0.0
  hooks:
  - id: black
EOF

  run env PRE_COMMIT_LOG="$log_file" "$TOOL" --config "$config_file" --debug

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade should preserve mixed ref styles by default'
  assert_contains "$output" "Running pre-commit autoupdate for '$config_file' using tag refs" 'tool should update all repos to tags first in default mode'
  assert_contains "$output" "Running pre-commit autoupdate for '$config_file' using hash refs for repo 'https://github.com/psf/black'" 'tool should re-freeze repos that were already hash-pinned'
  expected_log=$(printf 'autoupdate --config %s\nautoupdate --freeze --repo https://github.com/psf/black --config %s' "$config_file" "$config_file")
  assert_eq "$(<"$log_file")" "$expected_log" 'tool should rerun pre-commit with --freeze only for repos that previously used hashes'
  assert_eq "$(<"$config_file")" $'repos:\n- repo: https://github.com/pre-commit/pre-commit-hooks\n  rev: v1.2.0\n  hooks:\n  - id: trailing-whitespace\n- repo: https://github.com/psf/black\n  rev: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v23.0.0\n  hooks:\n  - id: black' 'default mode should keep tag refs as tags and hash refs as hashes'
}

@test "supports --config for a custom config path" {
  local config_file log_file

  config_file="$TMP_DIR/custom/pre-commit.yaml"
  log_file="$TMP_DIR/pre-commit.log"
  mkdir -p "${config_file%/*}"

  cat >"$config_file" <<'EOF'
repos:
- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v2.0.0
  hooks:
  - id: end-of-file-fixer
EOF

  run env \
    PRE_COMMIT_LOG="$log_file" \
    PRE_COMMIT_EXPECT_CONFIG="$config_file" \
    PRE_COMMIT_OLD_REV='v2.0.0' \
    PRE_COMMIT_NEW_REV='v2.1.0' \
    "$TOOL" --config "$config_file"

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade should succeed for an explicit config file'
  assert_contains "$output" "Updated pre-commit hook versions in $config_file." 'tool should report the custom config path that changed'
  assert_contains "$(<"$log_file")" "autoupdate --config $config_file" 'tool should pass the explicit config path to pre-commit'
  assert_eq "$(<"$config_file")" $'repos:\n- repo: https://github.com/pre-commit/pre-commit-hooks\n  rev: v2.1.0\n  hooks:\n  - id: end-of-file-fixer' 'tool should update the explicit config file in place'
}

@test "can force all hook refs to tags" {
  local config_file log_file expected_log

  config_file="$TMP_DIR/.pre-commit-config.yaml"
  log_file="$TMP_DIR/pre-commit.log"

  cat >"$config_file" <<'EOF'
repos:
- repo: https://github.com/psf/black
  rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v22.0.0
  hooks:
  - id: black
EOF

  run env PRE_COMMIT_LOG="$log_file" "$TOOL" --ref-type tag --config "$config_file"

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade should succeed when forcing tag refs'
  expected_log=$(printf 'autoupdate --config %s' "$config_file")
  assert_eq "$(<"$log_file")" "$expected_log" 'forced tag mode should only run the tag-based autoupdate pass'
  assert_eq "$(<"$config_file")" $'repos:\n- repo: https://github.com/psf/black\n  rev: v23.0.0\n  hooks:\n  - id: black' 'forced tag mode should rewrite hash refs to tags'
}

@test "can force all hook refs to hashes" {
  local config_file log_file expected_log

  config_file="$TMP_DIR/.pre-commit-config.yaml"
  log_file="$TMP_DIR/pre-commit.log"

  cat >"$config_file" <<'EOF'
repos:
- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v1.0.0
  hooks:
  - id: trailing-whitespace
EOF

  run env PRE_COMMIT_LOG="$log_file" "$TOOL" --ref-type hash --config "$config_file"

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade should succeed when forcing hash refs'
  expected_log=$(printf 'autoupdate --freeze --config %s' "$config_file")
  assert_eq "$(<"$log_file")" "$expected_log" 'forced hash mode should run pre-commit with --freeze'
  assert_eq "$(<"$config_file")" $'repos:\n- repo: https://github.com/pre-commit/pre-commit-hooks\n  rev: 1111111111111111111111111111111111111111 # frozen: v1.2.0\n  hooks:\n  - id: trailing-whitespace' 'forced hash mode should rewrite tag refs to frozen hashes'
}

@test "fails fast for an invalid ref type" {
  local config_file

  config_file="$TMP_DIR/.pre-commit-config.yaml"

  cat >"$config_file" <<'EOF'
repos:
- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v1.0.0
  hooks:
  - id: trailing-whitespace
EOF

  run "$TOOL" --ref-type invalid --config "$config_file"

  [ "$status" -eq 1 ] || fail 'pre-commit-upgrade should fail for an unsupported ref type'
  assert_contains "$output" "Error: invalid --ref-type 'invalid'" 'tool should explain the invalid ref type value'
}

@test "reports when no updates were applied" {
  local config_file

  config_file="$TMP_DIR/.pre-commit-config.yaml"

  cat >"$config_file" <<'EOF'
repos:
- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v3.0.0
  hooks:
  - id: check-yaml
EOF

  run "$TOOL" --config "$config_file"

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade should succeed when there are no changes'
  assert_contains "$output" 'No updates found.' 'tool should report when pre-commit did not change the config'
}

@test "preserves hash-style detection for quoted repo and rev values with inline comments" {
  local config_file log_file expected_log

  config_file="$TMP_DIR/.pre-commit-config.yaml"
  log_file="$TMP_DIR/pre-commit.log"

  cat >"$config_file" <<'EOF'
repos:
- repo: "https://github.com/pre-commit/pre-commit-hooks"
  rev: "v1.0.0"
  hooks:
  - id: trailing-whitespace
- repo: "https://github.com/psf/black" # formatter
  rev: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # frozen: v22.0.0
  hooks:
  - id: black
EOF

  run env PRE_COMMIT_LOG="$log_file" "$TOOL" --config "$config_file" --debug

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade should succeed for quoted repo and rev values'
  assert_contains "$output" "Running pre-commit autoupdate for '$config_file' using hash refs for repo 'https://github.com/psf/black'" 'tool should still detect quoted frozen hash repos for the second pass'
  expected_log=$(printf 'autoupdate --config %s\nautoupdate --freeze --repo https://github.com/psf/black --config %s' "$config_file" "$config_file")
  assert_eq "$(<"$log_file")" "$expected_log" 'tool should preserve hash-style repos even when the YAML uses quoted values'
}

@test "preserves hash-style detection for anchored repo and rev values" {
  local config_file log_file expected_log

  config_file="$TMP_DIR/.pre-commit-config.yaml"
  log_file="$TMP_DIR/pre-commit.log"

  cat >"$config_file" <<'EOF'
repos:
- repo: &hooks_repo https://github.com/pre-commit/pre-commit-hooks
  rev: &hooks_rev v1.0.0
  hooks:
  - id: trailing-whitespace
- repo: &black_repo https://github.com/psf/black
  rev: &black_rev aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v22.0.0
  hooks:
  - id: black
EOF

  run env PRE_COMMIT_LOG="$log_file" "$TOOL" --config "$config_file" --debug

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade should succeed for anchored repo and rev values'
  assert_contains "$output" "Running pre-commit autoupdate for '$config_file' using hash refs for repo 'https://github.com/psf/black'" 'tool should detect anchored frozen hash repos for the second pass'
  expected_log=$(printf 'autoupdate --config %s\nautoupdate --freeze --repo https://github.com/psf/black --config %s' "$config_file" "$config_file")
  assert_eq "$(<"$log_file")" "$expected_log" 'tool should preserve hash-style repos even when the YAML uses anchors'
}

@test "help documents the config override" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'pre-commit-upgrade --help should succeed'
  assert_contains "$output" '--config PATH' 'help should list the config override option'
  assert_contains "$output" '--ref-type TYPE' 'help should list the ref type override option'
}
