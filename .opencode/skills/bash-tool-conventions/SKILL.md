---
name: bash-tool-conventions
description: Conventions for creating and updating bash scripts in tools/bin.
---

# Bash Tool Conventions

Use this skill when creating or updating scripts in `tools/bin` for this repository.

## Required Structure

Each script should:

1. Start with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

2. Resolve and source `load.sh` relative to the script, supporting both repo and installed layouts:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_SH="${SCRIPT_DIR}/../lib/picotools/load.sh"
if [ ! -f "$LOAD_SH" ]; then
  LOAD_SH="${SCRIPT_DIR}/../../lib/picotools/load.sh"
fi

# shellcheck source=../../lib/picotools/load.sh
# shellcheck disable=SC1091
. "$LOAD_SH"
```

3. Source shared helper modules with `picotools_source_modules`, including `version` and only the additional modules the script actually uses:

```bash
picotools_source_modules "$SCRIPT_DIR" commands prompt version
```

Common modules in this repo include `commands`, `git`, `github`, `openshift`, `prompt`, `string`, `table`, and `version`.

Some modules source their own dependencies, but scripts in this repo still list directly used modules explicitly. For example, a tool that calls `picotools_require_command` and `picotools_require_git_repo` should source both `commands` and `git`.

4. Define a `usage()` function. Match repo style by using a single-quoted heredoc:

```bash
usage() {
  cat <<'EOF'
Usage: my-tool [options]

...
EOF
}
```

5. Define a `print_version()` function using the shared helper instead of reading `VERSION` inline:

```bash
print_version() {
  picotools_print_version "$SCRIPT_DIR"
}
```

6. Wrap executable logic in `main()`.

7. End with:

```bash
main "$@"
```

## Required Flags

Every script should support at minimum:

- `-h`, `--help`, `help`
- `-v`, `--version`, `version`
- `--debug`

Typical argument handling inside `main()`:

```bash
case "${1:-}" in
  -h | --help | help)
    usage
    exit 0
    ;;
  -v | --version | version)
    print_version
    exit 0
    ;;
esac
```

For `--debug`, match the existing repo style:

```bash
debug_mode=false

debug_enabled() {
  [ "$debug_mode" = 'true' ]
}

debug_log() {
  if debug_enabled; then
    printf '[my-tool] %s\n' "$1" >&2
  fi
}
```

Parse `--debug` before running the work, document it in `usage()`, and print progress details to stderr. If a tool delegates to another picotool, pass `--debug` through when useful.

## Shared Helpers

- Prefer shared `lib/picotools/*.sh` helpers over reimplementing common behavior.
- Use `picotools_require_command` or `picotools_require_commands` from the `commands` module for external tool checks.
- Use `picotools_require_git_repo` and `picotools_git_default_branch` from the `git` module for git repository/default-branch handling.
- Use `picotools_require_oc`, `picotools_oc`, and `picotools_oc_adm_top_pods` from the `openshift` module for OpenShift command wrappers.
- Use prompt helpers from the `prompt` module for interactive selection or confirmation flows.
- Use `picotools_print_table` or `picotools_print_two_column_table` from the `table` module for aligned tabular output.
- Use `picotools_print_version "$SCRIPT_DIR"` from the `version` module for version output.

If a helper is missing and multiple tools need the same behavior, add it under `lib/picotools/<module>.sh` with an idempotent load guard. Keep tool-specific assets under `tools/lib/picotools/<tool-name>/`; release archives preserve that layout as installed `lib/picotools/<tool-name>/`.

## Temporary Files

- When using `mktemp` or `mktemp -d`, keep cleanup in a small helper function and register it with `trap ... EXIT`.
- Store the temp path in a script-level variable when cleanup needs to happen across functions.
- Prefer `mktemp -d` for groups of temporary files so one cleanup trap removes the whole directory.

## Tests and Validation

- Add or update the matching Bats test in `tests/<tool>.bats` for new behavior.
- For new tools, add a smoke check to `.github/workflows/test.yml` install-test so the installed-layout `--help` and `--version` paths are covered.
- Validate scripts with `bash -n bin/* tools/bin/* scripts/*.bash`, `bats tests/*.bats`, and pre-commit when the change warrants it.
- Formatting is enforced by `scripts/shfmt.bash` using `shfmt --write --indent 2 .`; preserve the existing two-space case indentation style.

## Notes

- Keep changes minimal.
- Match existing repo style.
- Keep shellcheck happy when sourcing relative files by including the `shellcheck source=...` comment and disabling `SC1091` for the `load.sh` include.
- If a new tool is added, update `README.md` to list it, document noteworthy dependencies or flags, include it in the installed-tools list, and ensure release/install workflows package any required `tools/lib` assets.
