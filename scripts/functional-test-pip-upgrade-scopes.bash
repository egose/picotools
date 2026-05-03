#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *"/requests/json"*)
    cat <<'JSON'
{"releases":{"2.31.0":[{"yanked":false}],"2.31.1":[{"yanked":false}],"2.32.0":[{"yanked":false}],"3.0.0":[{"yanked":false}],"3.1.0rc1":[{"yanked":false}]}}
JSON
    ;;
  *"/urllib3/json"*)
    cat <<'JSON'
{"releases":{"2.2.0":[{"yanked":false}],"2.2.1":[{"yanked":false}],"2.3.0":[{"yanked":false}],"3.0.0":[{"yanked":false}]}}
JSON
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$tmp_dir/bin/curl"

cat >"$tmp_dir/requirements.txt" <<'EOF'
requests==2.31.0
urllib3==2.2.0 # keep comment
rich>=13.0
EOF

if output=$(printf 'n\n' | PATH="$tmp_dir/bin:$PATH" "$repo_root/tools/bin/pip-upgrade" --scope patch "$tmp_dir/requirements.txt" 2>&1); then
  printf '%s\n' "$output" >&2
  exit 1
fi

case "$output" in
*"Proceed with updating $tmp_dir/requirements.txt? [y/N]:"*"Cancelled."*)
  ;;
*)
  printf '%s\n' "$output" >&2
  exit 1
  ;;
esac

grep -Fx 'requests==2.31.0' "$tmp_dir/requirements.txt"
grep -Fx 'urllib3==2.2.0 # keep comment' "$tmp_dir/requirements.txt"

PATH="$tmp_dir/bin:$PATH" "$repo_root/tools/bin/pip-upgrade" --yes --scope patch "$tmp_dir/requirements.txt"
grep -Fx 'requests==2.31.1' "$tmp_dir/requirements.txt"
grep -Fx 'urllib3==2.2.1 # keep comment' "$tmp_dir/requirements.txt"
grep -Fx 'rich>=13.0' "$tmp_dir/requirements.txt"

cat >"$tmp_dir/requirements.txt" <<'EOF'
requests==2.31.0
urllib3==2.2.0
EOF

PATH="$tmp_dir/bin:$PATH" "$repo_root/tools/bin/pip-upgrade" --yes --scope minor "$tmp_dir/requirements.txt"
grep -Fx 'requests==2.32.0' "$tmp_dir/requirements.txt"
grep -Fx 'urllib3==2.3.0' "$tmp_dir/requirements.txt"

cat >"$tmp_dir/requirements.txt" <<'EOF'
requests==2.31.0
EOF

PATH="$tmp_dir/bin:$PATH" "$repo_root/tools/bin/pip-upgrade" --yes --scope major "$tmp_dir/requirements.txt"
grep -Fx 'requests==3.0.0' "$tmp_dir/requirements.txt"
