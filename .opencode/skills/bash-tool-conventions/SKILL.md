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

2. Resolve the version file relative to the script, supporting both repo and installed layouts:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="${SCRIPT_DIR}/../VERSION"
if [ ! -f "$VERSION_FILE" ]; then
  VERSION_FILE="${SCRIPT_DIR}/../../VERSION"
fi
```

3. Define a `usage()` function.

4. Define a `print_version()` function that reads from `VERSION_FILE`:

```bash
print_version() {
  if [ -f "$VERSION_FILE" ]; then
    tr -d '[:space:]' < "$VERSION_FILE"
    printf '\n'
  else
    echo "unknown"
  fi
}
```

5. Wrap executable logic in `main()`.

6. End with:

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
  -h|--help|help)
    usage
    exit 0
    ;;
  -v|--version|version)
    print_version
    exit 0
    ;;
esac
```

## Notes

- Keep changes minimal.
- Match existing repo style.
- If a new tool is added, update `README.md` to list it and note any special dependencies or flags.
