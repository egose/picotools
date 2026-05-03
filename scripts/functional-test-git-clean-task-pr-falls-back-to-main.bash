#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

real_git=$(command -v git)

git init --bare "$tmp_dir/remote.git"
git clone "$tmp_dir/remote.git" "$tmp_dir/work"
git clone "$tmp_dir/remote.git" "$tmp_dir/task"

git -C "$tmp_dir/work" checkout -b main
git -C "$tmp_dir/work" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m init
git -C "$tmp_dir/work" push -u origin main
git -C "$tmp_dir/task" fetch origin main
git -C "$tmp_dir/task" checkout -b feat origin/main

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ge 4 ] && [ "$1" = remote ] && [ "$2" = set-head ] && [ "$3" = origin ] && [ "$4" = --auto ]; then
  exit 1
fi

if [ "$#" -ge 4 ] && [ "$1" = symbolic-ref ] && [ "$2" = --quiet ] && [ "$3" = --short ] && [ "$4" = refs/remotes/origin/HEAD ]; then
  exit 1
fi

if [ "$#" -ge 4 ] && [ "$1" = remote ] && [ "$2" = show ] && [ "$3" = -n ] && [ "$4" = origin ]; then
  printf '%s\n' '* remote origin' '  HEAD branch: (not queried)'
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = remote ] && [ "$2" = show ] && [ "$3" = origin ]; then
  echo 'unexpected networked git remote show invocation' >&2
  exit 88
fi

exec "$REAL_GIT" "$@"
EOF
chmod +x "$tmp_dir/bin/git"

(
  cd "$tmp_dir/task"
  PATH="$tmp_dir/bin:$PATH" \
    REAL_GIT="$real_git" \
    bash "$repo_root/tools/bin/git-clean-task-pr" --branch feat-1
)

test "$(git -C "$tmp_dir/task" branch --show-current)" = 'feat-1'
