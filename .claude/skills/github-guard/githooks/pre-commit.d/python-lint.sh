#!/usr/bin/env bash
# guard: python-lint
# `ruff check` the staged Python and BLOCK on a finding — unlike python-fmt,
# because a lint finding says the code is wrong (an unused name, a mutable
# default, a zip() that silently truncates), not that it is untidy. ruff is
# fast enough that deferring this to CI buys nothing.
#
# Only the STAGED files are checked, so a pre-existing finding somewhere else
# cannot block a commit that has nothing to do with it. The heavier gates
# (type checking, the test suite) stay in CI.
set -u
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

staged=$(git diff --cached --name-only --diff-filter=ACM -- '*.py')
[ -n "$staged" ] || exit 0

ruff="$root/.venv/bin/ruff"
[ -x "$ruff" ] || ruff=$(command -v ruff) || {
  echo "github-guard: ruff not found — python-lint skipped (not blocking)" >&2
  exit 0
}

# An array, not `xargs`: a path with a space in it is one argument here and two
# through xargs, and the guard must not lint a file nobody staged.
files=()
while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<EOF
$staged
EOF

if ! ( cd "$root" && "$ruff" check --force-exclude -- "${files[@]}" ); then
  echo "" >&2
  echo "github-guard: python-lint BLOCKED this commit — ruff found problems in the" >&2
  echo "             staged files above. Fix them, or 'ruff check --fix' the" >&2
  echo "             autofixable ones. Bypass (last resort): git commit --no-verify" >&2
  exit 1
fi
exit 0
