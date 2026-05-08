#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
PROMPT_SH="$REPO_ROOT/lib/picotools/prompt.sh"

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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  case "$haystack" in
  *"$needle"*)
    fail "$message (unexpected '$needle')"
    ;;
  esac
}

assert_eq_either() {
  local actual="$1"
  local expected_a="$2"
  local expected_b="$3"
  local message="$4"

  if [ "$actual" != "$expected_a" ] && [ "$actual" != "$expected_b" ]; then
    fail "$message (expected '$expected_a' or '$expected_b', got '$actual')"
  fi
}

strip_first_line() {
  local value="$1"

  printf '%s' "${value#*$'\n'}"
}

run_prompt_script() {
  local input_bytes="$1"
  local prompt_call="$2"

  INPUT_BYTES="$input_bytes" PROMPT_CALL="$prompt_call" bash -lc '
    script -qec "bash -lc '\''stty -echo; . \"\$1\"; eval \"\$PROMPT_CALL\"'\'' bash \"$1\"" /dev/null \
      < <(printf "%b" "$INPUT_BYTES") \
      | perl -pe "s/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\r//g"
  ' bash "$PROMPT_SH"
}

@test "interactive value prompt uses line editing for arrow keys" {
  run run_prompt_script 'ab\033[DZ\n' 'picotools_prompt_value "Label"'

  [ "$status" -eq 0 ] || fail "interactive prompt command should succeed"

  assert_eq_either "$output" "ab^[[DZ
Label:
aZb" "ab^[[DZ
Label: aZb" 'prompt should preserve the edited answer across readline prompt rendering differences'
}

@test "interactive value prompt preserves question text during repeated left-arrow editing" {
  run run_prompt_script 'abcd\033[D\033[DXY\n' "picotools_prompt_value 'Models (comma-separated)'"

  [ "$status" -eq 0 ] || fail "interactive repeated-left-arrow prompt command should succeed"

  assert_eq_either "$output" "abcd^[[D^[[DXY
Models (comma-separated):
abXYcd" "abcd^[[D^[[DXY
Models (comma-separated): abXYcd" 'left-arrow editing should preserve the edited answer across readline prompt rendering differences'
}

@test "interactive secret prompt masks typed characters with asterisks" {
  run run_prompt_script 'secret123\n' 'picotools_prompt_secret_value "API key"'

  [ "$status" -eq 0 ] || fail "interactive secret prompt command should succeed"

  assert_eq "$output" "secret123
API key: *********
secret123" 'secret prompt should display one asterisk per typed character while returning the original value'
}

@test "interactive secret prompt handles backspace while updating mask" {
  local expected_output

  run run_prompt_script 'secretx\177\n' 'picotools_prompt_secret_value "API key"'

  [ "$status" -eq 0 ] || fail "interactive secret prompt with backspace should succeed"

  expected_output=$'secretx\b \b\nAPI key: ******\nsecret'
  assert_eq "$output" "$expected_output" 'secret prompt should erase the last mask character when backspace is pressed'
}

@test "single-select prompt ignores left and right arrows without corrupting output" {
  local cleaned_output

  run run_prompt_script '\033[D\033[C\n' 'picotools_prompt_select_index "Header" "Prompt" 2 false "One" "Two" "Three"'

  [ "$status" -eq 0 ] || fail "single-select prompt command should succeed"

  cleaned_output=$(strip_first_line "$output")

  assert_eq "$cleaned_output" "Header
Use up/down to choose, Enter to confirm, Esc or q to cancel.
  One
> Two
  Three
  One
> Two
  Three
  One
> Two
  Three

2" 'left and right arrows should be ignored without altering the selected option or screen output'
}

@test "multi-select prompt ignores left and right arrows without corrupting output" {
  local cleaned_output

  run run_prompt_script '\033[D\033[C\n' 'picotools_prompt_select_multiple_indexes "Header" "Prompt" true "One" "Two" "Three"'

  [ "$status" -eq 0 ] || fail "multi-select prompt command should succeed"

  cleaned_output=$(strip_first_line "$output")

  assert_eq "$cleaned_output" "Header
Use up/down to choose, Space to toggle, Enter to confirm, Esc or q to cancel.
> [ ] One
  [ ] Two
  [ ] Three
> [ ] One
  [ ] Two
  [ ] Three
> [ ] One
  [ ] Two
  [ ] Three" 'left and right arrows should be ignored without leaving control-sequence artifacts in multi-select output'
}

@test "single-select prompt consumes SS3 left-arrow escape sequences" {
  local cleaned_output

  run run_prompt_script '\033OD\n' 'picotools_prompt_select_index "Header" "Prompt" 2 false "One" "Two" "Three"'

  [ "$status" -eq 0 ] || fail "single-select SS3 left-arrow command should succeed"

  cleaned_output=$(strip_first_line "$output")

  assert_not_contains "$cleaned_output" 'D' 'SS3 left-arrow should not leak trailing bytes into selector output'
  assert_eq "$cleaned_output" "Header
Use up/down to choose, Enter to confirm, Esc or q to cancel.
  One
> Two
  Three
  One
> Two
  Three

2" 'SS3 left-arrow bytes should leave the selector state and final output intact'
}
