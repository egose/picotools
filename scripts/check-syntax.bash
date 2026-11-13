#!/usr/bin/env bash
set -euo pipefail

# bash -n accepts only one script; additional filenames become its arguments.
for path in \
  bin/* \
  tools/bin/* \
  lib/picotools/*.sh \
  tools/lib/picotools/k8s-profile/*.sh \
  scripts/*.bash \
  tests/helpers/*.bash; do
  [ -f "$path" ] || continue
  bash -n "$path"
done

# Bats syntax is not plain Bash. Its runner preprocesses/parses every test file
# while counting definitions, without running the tests or their setup hooks.
bats --count tests/*.bats >/dev/null
