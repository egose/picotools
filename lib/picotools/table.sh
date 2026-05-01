#!/usr/bin/env bash

if [ "${PICOTOOLS_TABLE_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
PICOTOOLS_TABLE_SH_LOADED=1

picotools_print_table_separator() {
  local -n widths_ref="$1"
  local index
  local padding

  for index in "${!widths_ref[@]}"; do
    padding=$(printf '%*s' "$((widths_ref[index] + 2))" '')
    printf '+%s' "${padding// /-}"
  done
  printf '+\n'
}

picotools_visible_text_length() {
  local value="$1"

  awk -v value="$value" 'BEGIN {
    gsub(/\033\[[0-9;]*m/, "", value)
    print length(value)
  }'
}

picotools_print_padded_cell() {
  local width="$1"
  local value="$2"
  local visible_length
  local padding_width

  visible_length=$(picotools_visible_text_length "$value")
  padding_width=$((width - visible_length))
  if [ "$padding_width" -lt 0 ]; then
    padding_width=0
  fi

  printf '| %s' "$value"
  printf '%*s ' "$padding_width" ''
}

picotools_print_table_row() {
  local -n widths_ref="$1"
  shift
  local index
  local -a fields=("$@")

  for index in "${!fields[@]}"; do
    picotools_print_padded_cell "${widths_ref[$index]}" "${fields[$index]}"
  done
  printf '|\n'
}

picotools_print_table() {
  local header_row="$1"
  shift
  local -a rows=("$@")
  local -a headers=()
  local -a widths=()
  local -a fields=()
  local row
  local index
  local field_value

  IFS=$'\t' read -r -a headers <<<"$header_row"

  for index in "${!headers[@]}"; do
    widths[index]="$(picotools_visible_text_length "${headers[index]}")"
  done

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r -a fields <<<"$row"

    for index in "${!headers[@]}"; do
      field_value="${fields[index]:-}"
      field_value="$(picotools_visible_text_length "$field_value")"
      if [ "$field_value" -gt "${widths[index]}" ]; then
        widths[index]="$field_value"
      fi
    done
  done

  picotools_print_table_separator widths
  picotools_print_table_row widths "${headers[@]}"
  picotools_print_table_separator widths

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r -a fields <<<"$row"

    for index in "${!headers[@]}"; do
      fields[index]="${fields[index]:-}"
    done

    picotools_print_table_row widths "${fields[@]}"
  done

  picotools_print_table_separator widths
}

picotools_print_two_column_table() {
  picotools_print_table $'Field\tValue' "$@"
}
