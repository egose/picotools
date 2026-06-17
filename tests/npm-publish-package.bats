#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TOOL="$REPO_ROOT/tools/bin/npm-publish-package"

setup() {
  WORKSPACE="$(mktemp -d)" || return 1
  export WORKSPACE
  export STUB_BIN="$WORKSPACE/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
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
    fail "$message (expected '$expected', got '$actual')"
  fi
}

write_jq_stub() {
  cat >"$STUB_BIN/jq" <<'EOF'
#!/usr/bin/python3
import json
import sys


def rewrite_path(value, publish_dir):
    if not isinstance(value, str):
        return value
    if value == publish_dir or value == f"./{publish_dir}":
        return "./"
    if value.startswith(f"./{publish_dir}/"):
        return f"./{value[len(publish_dir) + 3:]}"
    if value.startswith(f"{publish_dir}/"):
        return f"./{value[len(publish_dir) + 1:]}"
    return value


def rewrite_value(value, publish_dir):
    if isinstance(value, str):
        return rewrite_path(value, publish_dir)
    if isinstance(value, list):
        return [rewrite_value(item, publish_dir) for item in value]
    if isinstance(value, dict):
        return {key: rewrite_value(item, publish_dir) for key, item in value.items()}
    return value


def print_value(value):
    if value is True:
        print("true")
    elif value is False:
        print("false")
    elif value is None:
        print("")
    else:
        print(value)

args = sys.argv[1:]
if not args:
    sys.exit(1)

raw_mode = False
if args and args[0] == "-r":
    raw_mode = True
    args = args[1:]

named_args = {}
named_json = {}
index = 0
while index < len(args):
    if args[index] == "--arg":
        named_args[args[index + 1]] = args[index + 2]
        index += 3
        continue
    if args[index] == "--argjson":
        named_json[args[index + 1]] = json.loads(args[index + 2])
        index += 3
        continue
    break

if index >= len(args):
    sys.exit(1)

expr = args[index]
index += 1
file_path = args[index] if index < len(args) else None

if raw_mode:
    with open(file_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    if expr == '.name // empty, (if (.additionalNames | type) == "array" then .additionalNames[] else empty end)':
        name = data.get("name")
        if name:
            print(name)
        additional_names = data.get("additionalNames")
        if isinstance(additional_names, list):
            for item in additional_names:
                print(item)
        sys.exit(0)

    if expr == ".name":
        print_value(data.get("name"))
        sys.exit(0)

    if expr == ".main":
        print_value(data.get("main"))
        sys.exit(0)

    if expr == ".module":
        print_value(data.get("module"))
        sys.exit(0)

    if expr == ".types":
        print_value(data.get("types"))
        sys.exit(0)

    if expr == '.exports["."].import':
        print_value(((data.get("exports") or {}).get(".") or {}).get("import"))
        sys.exit(0)

    if expr == '.exports["."].require':
        print_value(((data.get("exports") or {}).get(".") or {}).get("require"))
        sys.exit(0)

    if expr == '.exports["./feature"]':
        print_value((data.get("exports") or {}).get("./feature"))
        sys.exit(0)

    if expr == '.files | join(",")':
        print(",".join(data.get("files") or []))
        sys.exit(0)

    if expr == 'has("private")':
        print_value("private" in data)
        sys.exit(0)

    if expr == 'if has($key) then .[$key] else empty end':
        key = named_args.get("key")
        if key in data:
            print_value(data.get(key))
        sys.exit(0)

    if expr == '.[$key][]?':
        key = named_args.get("key")
        value = data.get(key)
        if isinstance(value, list):
            for item in value:
                print(item)
        sys.exit(0)

    sys.exit(1)

with open(file_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

publish_name = named_args.get("publish_name")
publish_dir = named_args.get("publish_dir")
package_keys = named_json.get("package_keys", [])

publish = {key: value for key, value in data.items() if key in package_keys}
publish["name"] = publish_name
publish["files"] = ["**/*", "!**/*.map"]
publish["main"] = rewrite_path(publish.get("main"), publish_dir) or "./index.cjs"
publish["module"] = rewrite_path(publish.get("module"), publish_dir) or "./index.js"
publish["types"] = rewrite_path(publish.get("types"), publish_dir) or "./index.d.ts"

if isinstance(publish.get("exports"), dict):
    publish["exports"] = rewrite_value(publish["exports"], publish_dir)
else:
    publish["exports"] = {
        ".": {
            "require": "./index.cjs",
            "import": "./index.js",
            "types": "./index.d.ts",
        }
    }

json.dump(publish, sys.stdout, indent=2)
sys.stdout.write("\n")
EOF
  chmod +x "$STUB_BIN/jq"
}

write_pnpm_stub() {
  cat >"$STUB_BIN/pnpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${PNPM_LOG:-}" ]; then
  printf '%s|%s\n' "$PWD" "$*" >>"$PNPM_LOG"
fi

if [ "$#" -eq 1 ] && [ "$1" = 'bundle' ]; then
  publish_dir="${PUBLISH_DIR:-dist}"
  mkdir -p "$publish_dir"
  printf 'built\n' >"$publish_dir/index.cjs"
  printf 'built\n' >"$publish_dir/index.js"
  printf 'built\n' >"$publish_dir/index.d.ts"
  printf 'built\n' >"$publish_dir/feature.js"
  exit 0
fi

exit 1
EOF
  chmod +x "$STUB_BIN/pnpm"
}

write_npm_stub() {
  cat >"$STUB_BIN/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${NPM_LOG:-}" ]; then
  printf '%s|%s\n' "$PWD" "$*" >>"$NPM_LOG"
fi

if [ "$1" != 'publish' ]; then
  exit 1
fi

count=1
if [ -n "${NPM_COUNT_FILE:-}" ]; then
  if [ -f "$NPM_COUNT_FILE" ]; then
    count=$(( $(<"$NPM_COUNT_FILE") + 1 ))
  fi
  printf '%s\n' "$count" >"$NPM_COUNT_FILE"
fi

if [ -n "${NPM_SNAPSHOT_DIR:-}" ]; then
  cp package.json "$NPM_SNAPSHOT_DIR/package-${count}.json"
fi
EOF
  chmod +x "$STUB_BIN/npm"
}

@test "help documents publish options" {
  write_jq_stub

  run "$TOOL" --help

  [ "$status" -eq 0 ] || fail 'npm-publish-package --help should succeed'
  assert_contains "$output" '--publish-dir DIR' 'help should describe the publish dir option'
  assert_contains "$output" '--workspace-root DIR' 'help should describe the workspace root option'
  assert_contains "$output" '--config PATH' 'help should describe the config path option'
  assert_contains "$output" '--bundle-command CMD' 'help should describe the bundle command option'
  assert_contains "$output" '--ignore-missing-include-file' 'help should describe missing include handling'
  assert_contains "$output" '--no-default-files' 'help should describe default file suppression'
  assert_contains "$output" '--tolerate-existing-package-json' 'help should describe existing package.json handling'
  assert_contains "$output" '--registry URL' 'help should describe the registry option'
  assert_contains "$output" '--otp CODE' 'help should describe the otp option'
  assert_contains "$output" '--provenance' 'help should describe the provenance option'
  assert_contains "$output" '--dry-run' 'help should describe dry-run mode'
}

@test "exits without bundling when package.json has no name" {
  local pnpm_log

  pnpm_log="$WORKSPACE/pnpm.log"
  write_jq_stub
  write_pnpm_stub

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "version": "1.2.3"
}
EOF

  run bash -c 'cd "$1" && PNPM_LOG="$2" "$3"' bash "$WORKSPACE" "$pnpm_log" "$TOOL"

  [ "$status" -eq 0 ] || fail 'npm-publish-package should no-op successfully when no package name is present'
  [ ! -f "$pnpm_log" ] || fail 'npm-publish-package should not run the bundle step when no package name is present'
  [ ! -d "$WORKSPACE/dist" ] || fail 'npm-publish-package should not create the publish dir when no package name is present'
}

@test "rejects absolute publish directories" {
  write_jq_stub

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3"
}
EOF

  run bash -c 'cd "$1" && "$2" --publish-dir /tmp/publish --skip-bundle --dry-run' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 1 ] || fail 'npm-publish-package should reject absolute publish dirs'
  assert_contains "$output" 'Error: --publish-dir must be a relative path: /tmp/publish' 'tool should explain that publish-dir must stay relative'
}

@test "rejects using the workspace root as publish directory" {
  write_jq_stub

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3"
}
EOF

  run bash -c 'cd "$1" && "$2" --publish-dir . --skip-bundle --dry-run' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 1 ] || fail 'npm-publish-package should reject publishing from the workspace root'
  assert_contains "$output" 'Error: --publish-dir must not be the workspace root' 'tool should explain why the workspace root is not a valid publish dir'
}

@test "fails when an explicit include file is missing" {
  write_jq_stub
  mkdir -p "$WORKSPACE/build"

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3"
}
EOF

  run bash -c 'cd "$1" && "$2" --publish-dir build --skip-bundle --dry-run --no-default-files --include-file NOTICE.md' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 1 ] || fail 'npm-publish-package should fail when an explicit include file is missing'
  assert_contains "$output" 'Error: include file not found: NOTICE.md' 'tool should explain the missing explicit include file'
}

@test "fails when publish-dir package.json already exists by default" {
  write_jq_stub
  mkdir -p "$WORKSPACE/build"

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3"
}
EOF
  printf '%s\n' '{}' >"$WORKSPACE/build/package.json"

  run bash -c 'cd "$1" && "$2" --publish-dir build --skip-bundle --dry-run' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 1 ] || fail 'npm-publish-package should fail when the publish-dir package.json already exists'
  assert_contains "$output" 'Error: publish-dir package.json already exists: build/package.json' 'tool should explain the preexisting publish-dir package.json'
  assert_contains "$output" 'Pass --tolerate-existing-package-json to overwrite it.' 'tool should explain how to override the protection'
}

@test "can overwrite an existing publish-dir package.json when allowed" {
  write_jq_stub
  mkdir -p "$WORKSPACE/build"

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3",
  "main": "build/index.cjs",
  "module": "build/index.js",
  "types": "build/index.d.ts"
}
EOF
  printf '%s\n' 'old' >"$WORKSPACE/build/package.json"

  run bash -c 'cd "$1" && "$2" --publish-dir build --skip-bundle --dry-run --tolerate-existing-package-json' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'npm-publish-package should allow overwriting the publish-dir package.json when explicitly requested'
  assert_contains "$output" 'Prepared package demo-package in build (dry run).' 'tool should continue after tolerating an existing publish-dir package.json'
  assert_eq "$(jq -r '.name' "$WORKSPACE/build/package.json")" 'demo-package' 'tool should overwrite the existing publish-dir package.json with the generated manifest'
}

@test "fails when the bundle command does not create the publish directory" {
  write_jq_stub

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3"
}
EOF

  run bash -c 'cd "$1" && "$2" --bundle-command true' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 1 ] || fail 'npm-publish-package should fail when the bundle command does not create the publish dir'
  assert_contains "$output" "Error: bundle command did not create publish directory 'dist'" 'tool should explain the missing publish directory after bundling'
}

@test "bundles rewrites package metadata and publishes each configured name" {
  local pnpm_log npm_log npm_count snapshots

  pnpm_log="$WORKSPACE/pnpm.log"
  npm_log="$WORKSPACE/npm.log"
  npm_count="$WORKSPACE/npm.count"
  snapshots="$WORKSPACE/snapshots"

  mkdir -p "$snapshots"
  write_jq_stub
  write_pnpm_stub
  write_npm_stub

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "additionalNames": ["demo-compat"],
  "version": "1.2.3",
  "description": "Demo package",
  "keywords": ["demo"],
  "private": true,
  "repository": {
    "type": "git",
    "url": "https://github.com/octo/demo"
  },
  "dependencies": {
    "react": "^19.0.0"
  },
  "main": "dist/index.cjs",
  "module": "./dist/index.js",
  "types": "dist/index.d.ts",
  "exports": {
    ".": {
      "require": "./dist/index.cjs",
      "import": "dist/index.js",
      "types": "./dist/index.d.ts"
    },
    "./feature": "dist/feature.js"
  }
}
EOF
  printf '%s\n' 'Read me' >"$WORKSPACE/README.md"
  printf '%s\n' 'MIT License' >"$WORKSPACE/LICENSE"

  run bash -c 'cd "$1" && PUBLISH_DIR=dist PNPM_LOG="$2" NPM_LOG="$3" NPM_COUNT_FILE="$4" NPM_SNAPSHOT_DIR="$5" "$6"' bash "$WORKSPACE" "$pnpm_log" "$npm_log" "$npm_count" "$snapshots" "$TOOL"

  [ "$status" -eq 0 ] || fail 'npm-publish-package should publish successfully'
  assert_contains "$output" 'Published package demo-package from dist.' 'tool should report publishing the primary package name'
  assert_contains "$output" 'Published package demo-compat from dist.' 'tool should report publishing the additional package name'
  assert_contains "$(<"$pnpm_log")" 'bundle' 'tool should run the default pnpm bundle command'
  assert_contains "$(<"$npm_log")" '/dist|publish --access public' 'tool should publish from the dist directory with public access'
  assert_eq "$(wc -l <"$npm_log")" '2' 'tool should publish once per configured package name'
  [ -f "$WORKSPACE/dist/README.md" ] || fail 'tool should copy README.md into the publish dir'
  [ -f "$WORKSPACE/dist/LICENSE" ] || fail 'tool should copy LICENSE into the publish dir'
  [ ! -f "$WORKSPACE/dist/CHANGELOG.md" ] || fail 'tool should skip missing default files silently'

  assert_eq "$(jq -r '.name' "$snapshots/package-1.json")" 'demo-package' 'first publish should use the primary package name'
  assert_eq "$(jq -r '.name' "$snapshots/package-2.json")" 'demo-compat' 'second publish should use the additional package name'
  assert_eq "$(jq -r '.main' "$snapshots/package-1.json")" './index.cjs' 'main should be rewritten relative to the publish dir'
  assert_eq "$(jq -r '.module' "$snapshots/package-1.json")" './index.js' 'module should be rewritten relative to the publish dir'
  assert_eq "$(jq -r '.types' "$snapshots/package-1.json")" './index.d.ts' 'types should be rewritten relative to the publish dir'
  assert_eq "$(jq -r '.exports["."].import' "$snapshots/package-1.json")" './index.js' 'exports import path should be rewritten relative to the publish dir'
  assert_eq "$(jq -r '.exports["./feature"]' "$snapshots/package-1.json")" './feature.js' 'string export paths should be rewritten relative to the publish dir'
  assert_eq "$(jq -r '.files | join(",")' "$snapshots/package-1.json")" '**/*,!**/*.map' 'files should be reset to the publish bundle defaults'
  assert_eq "$(jq -r 'has("private")' "$snapshots/package-1.json")" 'false' 'non-whitelisted package.json keys should be omitted from the published manifest'
}

@test "forwards registry otp and provenance to npm publish" {
  local npm_log snapshots

  npm_log="$WORKSPACE/npm.log"
  snapshots="$WORKSPACE/snapshots"

  mkdir -p "$WORKSPACE/build" "$snapshots"
  printf 'built\n' >"$WORKSPACE/build/index.cjs"
  printf 'built\n' >"$WORKSPACE/build/index.js"
  printf 'built\n' >"$WORKSPACE/build/index.d.ts"
  write_jq_stub
  write_npm_stub

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3",
  "main": "build/index.cjs",
  "module": "build/index.js",
  "types": "build/index.d.ts"
}
EOF

  run bash -c 'cd "$1" && NPM_LOG="$2" NPM_SNAPSHOT_DIR="$3" "$4" --publish-dir build --skip-bundle --access restricted --tag next --registry https://registry.example.test --otp 123456 --provenance' bash "$WORKSPACE" "$npm_log" "$snapshots" "$TOOL"

  [ "$status" -eq 0 ] || fail 'npm-publish-package should support additional npm publish flags'
  assert_contains "$output" 'Published package demo-package from build.' 'tool should still report successful publishing with extra npm flags'
  assert_contains "$(<"$npm_log")" 'publish --access restricted --tag next --registry https://registry.example.test --otp 123456 --provenance' 'tool should forward registry otp and provenance to npm publish'
}

@test "loads config from the workspace root and lets CLI override it" {
  mkdir -p "$WORKSPACE/project/build" "$WORKSPACE/project/subdir"
  write_jq_stub

  cat >"$WORKSPACE/project/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3",
  "main": "build/index.cjs",
  "module": "build/index.js",
  "types": "build/index.d.ts"
}
EOF
  cat >"$WORKSPACE/project/.npm-publish-package.json" <<'EOF'
{
  "publishDir": "build",
  "skipBundle": true,
  "defaultFiles": false,
  "dryRun": true,
  "ignoreMissingIncludeFile": true,
  "includeFiles": ["NOTICE.md", "MISSING.md"]
}
EOF
  printf '%s\n' 'notice' >"$WORKSPACE/project/NOTICE.md"

  run bash -c 'cd "$1/project/subdir" && "$2" --workspace-root "$1/project" --include-file EXTRA.md --ignore-missing-include-file' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'npm-publish-package should load defaults from a workspace-root config file'
  assert_contains "$output" 'Prepared package demo-package in build (dry run).' 'tool should use the configured publish dir and dry-run setting'
  [ -f "$WORKSPACE/project/build/NOTICE.md" ] || fail 'tool should copy include files configured in the config file'
  [ ! -f "$WORKSPACE/project/build/README.md" ] || fail 'tool should honor configured defaultFiles=false'
  assert_eq "$(jq -r '.name' "$WORKSPACE/project/build/package.json")" 'demo-package' 'tool should generate the manifest inside the configured publish dir'
}

@test "resolves explicit config paths relative to the caller directory" {
  mkdir -p "$WORKSPACE/project/build" "$WORKSPACE/caller"
  write_jq_stub

  cat >"$WORKSPACE/project/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3",
  "main": "build/index.cjs",
  "module": "build/index.js",
  "types": "build/index.d.ts"
}
EOF
  cat >"$WORKSPACE/caller/publish-config.json" <<'EOF'
{
  "publishDir": "build",
  "skipBundle": true,
  "defaultFiles": false,
  "dryRun": true
}
EOF

  run bash -c 'cd "$1/caller" && "$2" --workspace-root "$1/project" --config publish-config.json' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'npm-publish-package should resolve explicit config paths from the caller directory'
  assert_contains "$output" 'Prepared package demo-package in build (dry run).' 'tool should use the explicitly provided config file'
  assert_eq "$(jq -r '.name' "$WORKSPACE/project/build/package.json")" 'demo-package' 'tool should generate the manifest using the explicit config path'
}

@test "supports custom publish options in dry-run mode" {
  write_jq_stub
  mkdir -p "$WORKSPACE/build"

  cat >"$WORKSPACE/package.json" <<'EOF'
{
  "name": "demo-package",
  "version": "1.2.3",
  "main": "build/index.cjs",
  "module": "./build/index.js",
  "types": "build/index.d.ts"
}
EOF
  printf '%s\n' 'Notice' >"$WORKSPACE/NOTICE.md"

  run bash -c 'cd "$1" && "$2" --publish-dir build --skip-bundle --no-default-files --include-file NOTICE.md --access restricted --tag next --dry-run' bash "$WORKSPACE" "$TOOL"

  [ "$status" -eq 0 ] || fail 'npm-publish-package dry-run should succeed without npm'
  assert_contains "$output" 'Prepared package demo-package in build (dry run).' 'tool should report prepared packages in dry-run mode'
  [ -f "$WORKSPACE/build/NOTICE.md" ] || fail 'tool should copy explicitly included files into the custom publish dir'
  [ ! -f "$WORKSPACE/build/README.md" ] || fail 'tool should omit default files when --no-default-files is used'
  assert_eq "$(jq -r '.main' "$WORKSPACE/build/package.json")" './index.cjs' 'main should be rewritten for a custom publish dir'
  assert_eq "$(jq -r '.module' "$WORKSPACE/build/package.json")" './index.js' 'module should be rewritten for a custom publish dir'
  assert_eq "$(jq -r '.types' "$WORKSPACE/build/package.json")" './index.d.ts' 'types should be rewritten for a custom publish dir'
  assert_eq "$(jq -r '.exports["."].require' "$WORKSPACE/build/package.json")" './index.cjs' 'default exports should be added when exports are missing'
}
