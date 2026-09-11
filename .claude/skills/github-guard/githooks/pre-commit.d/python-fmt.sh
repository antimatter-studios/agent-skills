#!/usr/bin/env bash
# guard: python-fmt
# Auto-format staged Python with `ruff format` and re-stage it, so CI's
# `ruff format --check` is never where a layout problem is discovered. Skips
# silently with no staged Python or no ruff. NEVER blocks.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

staged=$(git diff --cached --name-only --diff-filter=ACM -- '*.py')
[ -n "$staged" ] || exit 0
unstaged=$(git diff --name-only --diff-filter=ACMD -- '*.py')

# The project's own venv first: it holds the version pinned in the project's
# dev requirements, and a different ruff on PATH formats differently enough
# that the two fight over the same file on alternate commits.
ruff="$root/.venv/bin/ruff"
[ -x "$ruff" ] || ruff=$(command -v ruff) || {
  echo "github-guard: ruff not found — python-fmt skipped (not blocking)" >&2
  exit 0
}

printf '%s\n' "$staged" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$root/$f" ] || continue
  if printf '%s\n' "$unstaged" | grep -qxF -- "$f"; then
    gg_partial_notice python-fmt "$f" "run 'ruff format' + 'git add'"
    continue
  fi
  ( cd "$root" && "$ruff" format -q -- "$f" ) || continue
  git add -- "$root/$f" 2>/dev/null || true
done
exit 0
