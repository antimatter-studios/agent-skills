#!/usr/bin/env bash
# guard: generated-normalise
# Strips trailing whitespace from staged files under a declared GENERATED path
# and re-stages them. NEVER blocks — it tidies machine output, and there is
# nobody to argue with.
#
# Named to sort before git-no-trailing-whitespace, which would otherwise block
# the commit over whitespace nobody typed: code generators emit trailing spaces
# in doc comments, so every regeneration would need --no-verify — and that flag
# disables every other guard too, which is a far worse outcome than a stray
# space.
#
# Only declared paths are touched (see gg_declared_paths; per-clone config wins):
#
#   .github-guard                       .git/config (git config --add ...)
#   [paths]                             github-guard.paths.generated frontend/bindings
#   	generated = frontend/bindings
#
# Hand-written code is deliberately left to the blocking guard, because there
# the whitespace IS worth a complaint.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

paths=$(gg_declared_paths generated); declared=$?
if [ "$declared" = 2 ]; then
  # Never blocks, so the most it can do is say why it did nothing: a blocking
  # whitespace guard after it may now refuse output this would have tidied.
  echo "github-guard: generated-normalise skipped — $(gg_decl_error "$root/$GG_DECL_FILE")" >&2
  exit 0
fi
[ -n "$paths" ] || exit 0

specs=()
while IFS= read -r p; do [ -n "$p" ] && specs+=("$p"); done <<EOF
$paths
EOF

staged=$(git diff --cached --name-only --diff-filter=ACM -- "${specs[@]}")
[ -n "$staged" ] || exit 0
unstaged=$(git diff --name-only --diff-filter=ACMD -- "${specs[@]}")

printf '%s\n' "$staged" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$root/$f" ] || continue

  # Same hazard as any rewrite-then-restage guard: staging the rewritten file
  # would also stage unstaged edits in it. Generated output should never be in
  # that state, so it is reported rather than quietly swept in.
  if printf '%s\n' "$unstaged" | grep -qxF -- "$f"; then
    echo "github-guard: generated-normalise skipped '$f' — it has unstaged changes" >&2
    continue
  fi

  # Via a temp file, because `sed -i` takes an argument on BSD and refuses one
  # on GNU, and the guards run on both.
  tmp="$root/$f.gg-tmp"
  if sed -e 's/[[:space:]]*$//' -- "$root/$f" > "$tmp" 2>/dev/null; then
    if cmp -s -- "$root/$f" "$tmp"; then
      rm -f -- "$tmp"
    else
      mv -- "$tmp" "$root/$f" && git add -- "$root/$f"
    fi
  else
    rm -f -- "$tmp"
  fi
done
exit 0
