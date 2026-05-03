#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

git init --bare "$tmp_dir/remote.git"
git clone "$tmp_dir/remote.git" "$tmp_dir/work"
git clone "$tmp_dir/remote.git" "$tmp_dir/task"

git -C "$tmp_dir/work" checkout -b main
git -C "$tmp_dir/work" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m init
git -C "$tmp_dir/work" push -u origin main

git -C "$tmp_dir/task" fetch origin main
git -C "$tmp_dir/task" checkout -b feat origin/main
git -C "$tmp_dir/task" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m feat

git -C "$tmp_dir/work" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m base
git -C "$tmp_dir/work" push

cat >"$tmp_dir/editor" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod +x "$tmp_dir/editor"

(
  cd "$tmp_dir/task"
  GIT_MERGE_AUTOEDIT=yes \
    GIT_EDITOR="$tmp_dir/editor" \
    GIT_COMMITTER_NAME=Test \
    GIT_COMMITTER_EMAIL=test@example.com \
    GIT_AUTHOR_NAME=Test \
    GIT_AUTHOR_EMAIL=test@example.com \
    bash "$repo_root/tools/bin/git-clean-task-pr" --branch feat-1 main
)

test "$(git -C "$tmp_dir/task" branch --show-current)" = 'feat-1'
test ! -f "$(git -C "$tmp_dir/task" rev-parse --git-path MERGE_HEAD)"
