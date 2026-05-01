#!/bin/bash

editmsg="$(git rev-parse --git-path COMMIT_EDITMSG)"

# shellcheck disable=SC2086
npx commitlint --config .commitlintrc.mjs --edit "$editmsg" --verbose
