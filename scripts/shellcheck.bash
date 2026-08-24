#!/usr/bin/env bash

files=()

for path in \
  bin/* \
  tools/bin/* \
  lib/picotools/*.sh \
  scripts/*.bash \
  tests/helpers/*.bash \
  tests/*.bats; do
  [ -f "$path" ] || continue
  files+=("$path")
done

exec shellcheck -s bash -x "${files[@]}"
