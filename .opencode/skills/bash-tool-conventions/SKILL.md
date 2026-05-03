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

## Shared Helpers

- Prefer shared `lib/picotools/*.sh` helpers over reimplementing common behavior.
- Use `picotools_require_command` or `picotools_require_commands` from the `commands` module for external tool checks.
- Use prompt helpers from the `prompt` module for interactive selection or confirmation flows.
- Use `picotools_print_version "$SCRIPT_DIR"` from the `version` module for version output.

## Temporary Files

- When using `mktemp` or `mktemp -d`, keep cleanup in a small helper function and register it with `trap ... EXIT`.
- Store the temp path in a script-level variable when cleanup needs to happen across functions.

## Notes

- Keep changes minimal.
- Match existing repo style.
- Keep shellcheck happy when sourcing relative files by including the `shellcheck source=...` comment and disabling `SC1091` for the `load.sh` include.
- If a new tool is added, update `README.md` to list it and note any special dependencies or flags.
