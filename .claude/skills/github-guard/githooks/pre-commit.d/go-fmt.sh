#!/usr/bin/env bash
# guard: go-fmt
# Auto-format staged Go code and re-stage it, so the commit goes in formatted.
# Skips silently with no staged Go or no formatter. NEVER blocks — it fixes
# layout, so there is nothing to argue about.
#
# gofumpt when it is installed, gofmt otherwise: gofumpt is a strict superset,
# and projects whose .golangci.yml enables it will fail CI on code that plain
# gofmt considers finished. Formatting to the weaker standard and then being
# told off by the linter is the one outcome worth avoiding.
#
# golangci-lint deliberately stays OUT of the hook: it builds every package,
# which is seconds to tens of seconds, and belongs in CI.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Captured BEFORE formatting: the intersection of staged and unstaged is the
# partially-staged danger set, and formatting would destroy the evidence.
staged=$(git diff --cached --name-only --diff-filter=ACM -- '*.go')
[ -n "$staged" ] || exit 0
unstaged=$(git diff --name-only --diff-filter=ACMD -- '*.go')

fmt=$(command -v gofumpt) || fmt=$(command -v gofmt) || {
  echo "github-guard: no gofumpt or gofmt on PATH — go-fmt skipped (not blocking)" >&2
  exit 0
}

printf '%s\n' "$staged" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$root/$f" ] || continue

  if printf '%s\n' "$unstaged" | grep -qxF -- "$f"; then
    # Only worth a notice when formatting would actually change the file;
    # otherwise every commit that touches a work-in-progress file prints a
    # warning about nothing, and warnings nobody needs get tuned out.
    [ -n "$("$fmt" -l -- "$root/$f" 2>/dev/null)" ] || continue
    gg_partial_notice go-fmt "$f" "run '$(basename "$fmt") -w' + 'git add'"
    continue
  fi

  [ -n "$("$fmt" -l -- "$root/$f" 2>/dev/null)" ] || continue
  "$fmt" -w -- "$root/$f" 2>/dev/null && git add -- "$root/$f" 2>/dev/null || true
done
exit 0
