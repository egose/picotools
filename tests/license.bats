#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/license"

setup() {
  WORKSPACE="$(mktemp -d)" || return 1
  export WORKSPACE
}

teardown() {
  rm -rf "$WORKSPACE"
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
    fail "$message"
  fi
}

@test "prompts for MIT copyright owner and updates package.json license field" {
  printf '%s\n' '{' '  "name": "demo",' '  "author": "Junmin Dev",' '  "license": "Apache-2.0"' '}' >"$WORKSPACE/package.json"

  run bash -c 'cd "$1" && printf "\n" | "$2" --type mit --yes' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should prompt for MIT copyright owner successfully'
  assert_contains "$output" 'Copyright owner [Junmin Dev]:' 'should prompt with the package author as default'
  assert_contains "$output" "Updated 'package.json' license field to 'MIT'." 'should update package.json license field'
  assert_contains "$output" "Wrote MIT License to 'LICENSE'." 'should confirm the written file'
  assert_contains "$(<"$WORKSPACE/LICENSE")" 'MIT License' 'should write MIT content'
  assert_contains "$(<"$WORKSPACE/LICENSE")" 'Copyright (c) Junmin Dev' 'should use the prompted default owner'
  assert_contains "$(<"$WORKSPACE/package.json")" '"license": "MIT"' 'should rewrite package.json license'
}

@test "supports non-interactive MIT copyright owner flag" {
  printf '%s\n' '{' '  "name": "demo",' '  "license": "Apache-2.0"' '}' >"$WORKSPACE/package.json"

  run bash -c 'cd "$1" && "$2" --type mit --copyright-owner "Example Org" --yes' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should support non-interactive MIT copyright owner flag'
  assert_contains "$output" "Wrote MIT License to 'LICENSE'." 'should confirm the written file'
  assert_contains "$(<"$WORKSPACE/LICENSE")" 'Copyright (c) Example Org' 'should write the provided MIT copyright owner'
  assert_contains "$(<"$WORKSPACE/package.json")" '"license": "MIT"' 'should update package.json to MIT'
}

@test "inserts license under description and preserves field order" {
  printf '%s\n' '{' '  "name": "demo",' '  "description": "Demo package",' '  "version": "1.0.0"' '}' >"$WORKSPACE/package.json"

  run bash -c 'cd "$1" && "$2" --type mit --owner "Example Org" --yes' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should preserve package.json field order'
  assert_contains "$(<"$WORKSPACE/package.json")" '"description": "Demo package",' 'should keep the existing description line'
  assert_contains "$(<"$WORKSPACE/package.json")" '"description": "Demo package",'$'\n''  "license": "MIT",'$'\n''  "version": "1.0.0"' 'should insert license directly under description'
}

@test "creates description under name before inserting license when missing" {
  printf '%s\n' '{' '  "name": "demo",' '  "version": "1.0.0"' '}' >"$WORKSPACE/package.json"

  run bash -c 'cd "$1" && "$2" --type mit --owner "Example Org" --yes' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should add description before license when missing'
  assert_contains "$(<"$WORKSPACE/package.json")" '"name": "demo",'$'\n''  "description": "",'$'\n''  "license": "MIT",'$'\n''  "version": "1.0.0"' 'should create description under name and place license under it'
}

@test "rejects copyright years for MIT" {
  printf '%s\n' '{' '  "name": "demo",' '  "license": "Apache-2.0"' '}' >"$WORKSPACE/package.json"

  run bash -c 'cd "$1" && "$2" --type mit --owner "Example Org" --years 2001-2026 --yes' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 1 ] || fail 'license should reject copyright years for MIT'
  assert_contains "$output" '--copyright-years and --years are only supported for Apache License 2.0' 'should explain the invalid years usage'
}

@test "writes Apache 2.0 license to a custom path without years when declined" {
  mkdir -p "$WORKSPACE/NOTICES"
  run bash -c 'cd "$1" && printf "Example Org\n1\n" | "$2" --type apache-2.0 --yes NOTICES/LICENSE.txt' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should write Apache content successfully'
  assert_contains "$output" "Wrote Apache License 2.0 to 'NOTICES/LICENSE.txt'." 'should confirm the custom path'
  assert_contains "$output" 'Copyright owner:' 'should require a copyright owner'
  assert_contains "$output" 'Copyright Years:' 'should show the years selection menu'
  assert_contains "$output" 'Select years source [1]:' 'should prompt for the years source'
  assert_contains "$(<"$WORKSPACE/NOTICES/LICENSE.txt")" 'Apache License' 'should include the Apache header'
  assert_contains "$(<"$WORKSPACE/NOTICES/LICENSE.txt")" 'Copyright Example Org' 'should write the owner without years'
}

@test "prompts for Apache copyright details and uses package author default" {
  mkdir -p "$WORKSPACE/bin"
  printf '%s\n' '{' '  "name": "demo",' '  "author": "Junmin Dev",' '  "license": "MIT"' '}' >"$WORKSPACE/package.json"
  mkdir -p "$WORKSPACE/.git"
  cat >"$WORKSPACE/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = 'rev-parse' ]; then
  printf '%s\n' 'true'
  exit 0
fi

if [ "$1" = 'log' ] && [ "$2" = '--reverse' ]; then
  printf '%s\n' '2000'
  exit 0
fi

if [ "$1" = 'log' ] && [ "$2" = '-1' ]; then
  printf '%s\n' '2026'
  exit 0
fi

printf 'unsupported git stub invocation\n' >&2
exit 1
EOF
  chmod +x "$WORKSPACE/bin/git"

  run bash -c 'cd "$1" && PATH="$1/bin:$PATH" bash -c '\''printf "\n2\n" | "$1" --type apache-2.0 --yes'\'' bash "$2"' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should support interactive Apache copyright population'
  assert_contains "$output" 'Copyright owner [Junmin Dev]:' 'should prompt with the package author as default'
  assert_contains "$output" 'Copyright Years:' 'should show the years selection menu'
  assert_contains "$(<"$WORKSPACE/LICENSE")" 'Copyright 2000-2026 Junmin Dev' 'should write the populated copyright line'
  assert_contains "$(<"$WORKSPACE/package.json")" '"license": "Apache-2.0"' 'should update package.json to Apache-2.0'
}

@test "supports interactive Apache custom years input" {
  printf '%s\n' '{' '  "name": "demo",' '  "license": "MIT"' '}' >"$WORKSPACE/package.json"

  run bash -c 'cd "$1" && printf "Example Org\n3\n2010-2024\n" | "$2" --type apache-2.0 --yes' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should support custom Apache years input'
  assert_contains "$output" 'Copyright Years:' 'should show the years selection menu'
  assert_contains "$output" 'Copyright years:' 'should prompt for manual years input'
  assert_contains "$(<"$WORKSPACE/LICENSE")" 'Copyright 2010-2024 Example Org' 'should write the custom years block'
}

@test "supports non-interactive Apache copyright flags" {
  printf '%s\n' '{' '  "name": "demo",' '  "license": "MIT"' '}' >"$WORKSPACE/package.json"

  run bash -c 'cd "$1" && "$2" --type apache-2.0 --copyright-years 2001-2026 --copyright-owner "Example Org" --yes' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should support non-interactive Apache copyright flags'
  assert_contains "$output" "Wrote Apache License 2.0 to 'LICENSE'." 'should confirm the written file'
  assert_contains "$(<"$WORKSPACE/LICENSE")" 'Copyright 2001-2026 Example Org' 'should write the provided copyright line'
  assert_contains "$(<"$WORKSPACE/package.json")" '"license": "Apache-2.0"' 'should update package.json to Apache-2.0'
}

@test "supports owner and years aliases" {
  printf '%s\n' '{' '  "name": "demo",' '  "license": "MIT"' '}' >"$WORKSPACE/package.json"

  run bash -c 'cd "$1" && "$2" --type apache-2.0 --owner "Example Org" --years 2001-2026 --yes' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should support owner and years aliases'
  assert_contains "$output" "Wrote Apache License 2.0 to 'LICENSE'." 'should confirm the written file'
  assert_contains "$(<"$WORKSPACE/LICENSE")" 'Copyright 2001-2026 Example Org' 'should write the provided copyright line'
}

@test "prompts for license selection and overwrite confirmation" {
  printf '%s\n' 'previous license' >"$WORKSPACE/LICENSE"

  run bash -c 'cd "$1" && printf "1\nExample Org\ny\n" | "$2"' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'license should support interactive selection and overwrite'
  assert_contains "$output" 'Licenses:' 'should display the license choices'
  assert_contains "$output" 'Copyright owner:' 'should ask for the MIT copyright owner'
  assert_contains "$output" "Overwrite existing file 'LICENSE'? [y/N]:" 'should ask before overwriting'
  assert_contains "$(<"$WORKSPACE/LICENSE")" 'MIT License' 'should write the selected MIT template'
}

@test "declining overwrite leaves the existing file unchanged" {
  printf '%s\n' 'keep me' >"$WORKSPACE/LICENSE"

  run bash -c 'cd "$1" && printf "n\n" | "$2" --type mit' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 1 ] || fail 'license should exit non-zero when overwrite is declined'
  assert_contains "$output" 'Cancelled.' 'should report cancellation'
  assert_eq "$(<"$WORKSPACE/LICENSE")" 'keep me' 'should preserve the existing LICENSE content'
}

@test "help documents type and overwrite flags" {
  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'license --help should succeed'
  assert_contains "$output" '--type' 'help should list license selection'
  assert_contains "$output" '--copyright-owner' 'help should list copyright owner flag'
  assert_contains "$output" '--owner' 'help should list owner alias'
  assert_contains "$output" '--copyright-years' 'help should list copyright years flag'
  assert_contains "$output" '--years' 'help should list years alias'
  assert_contains "$output" '--yes' 'help should list overwrite confirmation bypass'
  assert_contains "$output" '--debug' 'help should list debug mode'
}
