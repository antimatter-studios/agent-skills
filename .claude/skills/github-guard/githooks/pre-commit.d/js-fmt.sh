#!/usr/bin/env bash
# guard: js-fmt
# Auto-format staged JavaScript, TypeScript, CSS, HTML and JSON with the
# project's own prettier and re-stage it. Skips silently when nothing of that
# kind is staged or prettier is not installed. NEVER blocks.
#
# The project's OWN prettier, from the nearest node_modules/.bin: prettier's
# defaults change between majors, and a globally-installed one reformats a repo
# to a shape its CI then rejects. Walking up from each file also handles the
# common layout where the web project is a subdirectory (frontend/, web/, app/)
# with its own package.json and config — running prettier from the repo root
# there picks up no config at all.
#
# ESLint deliberately stays OUT of the hook: a type-aware config has to build
# the TypeScript program, seconds per run, and belongs in CI.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

staged=$(git diff --cached --name-only --diff-filter=ACM \
  -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.css' '*.scss' '*.html' '*.json' '*.md')
[ -n "$staged" ] || exit 0
unstaged=$(git diff --name-only --diff-filter=ACMD)

# Nearest ancestor of <file> (inside the repo) holding an executable prettier.
prettier_for() {
  local d="$1"
  while :; do
    [ -x "$root/$d/node_modules/.bin/prettier" ] && { printf '%s\n' "$d"; return 0; }
    [ "$d" = "." ] && return 1
    d=$(dirname "$d")
  done
}

found=0
printf '%s\n' "$staged" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$root/$f" ] || continue
  base=$(prettier_for "$(dirname "$f")") || continue
  found=1

  if printf '%s\n' "$unstaged" | grep -qxF -- "$f"; then
    gg_partial_notice js-fmt "$f" "run prettier + 'git add'"
    continue
  fi

  # Invoked from the package directory so prettier resolves that package's
  # config, and handed the path relative to it for the same reason.
  rel=${f#"$base"/}
  ( cd "$root/$base" && ./node_modules/.bin/prettier --write --log-level warn -- "$rel" ) || continue
  git add -- "$root/$f" 2>/dev/null || true
done
# `found` is set inside a pipeline subshell, so it is deliberately not read
# here: "prettier is not installed" is silence, matching every other guard that
# skips for a missing tool.
exit 0
