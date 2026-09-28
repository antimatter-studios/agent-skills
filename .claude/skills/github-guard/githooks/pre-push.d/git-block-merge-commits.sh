#!/usr/bin/env bash
# guard: git-block-merge-commits
# Block any push whose pushed range contains a merge commit — the safety net
# behind git-block-merge-commit (also catches merges that arrived via fetch,
# cherry-pick, or a merge-preserving rebase). Reads the ref list git provides
# on stdin. Checks the server's current refs so stale local tracking refs cannot
# hide a merge. Hard block. Bypass only with --no-verify.
set -u
status=0
remote=${1:-origin}
published=()
checked=0
while read -r local_ref local_sha remote_ref remote_sha; do
  # Deleting a remote branch (local_sha all-zero): nothing to inspect.
  printf '%s' "$local_sha" | grep -qE '^0+$' && continue
  if [ "$checked" = 0 ]; then
    tips=$(git ls-remote --refs "$remote" 2>/dev/null) || {
      echo 'github-guard: BLOCKED — cannot verify which merge commits are already on the remote' >&2
      exit 1
    }
    while IFS=$'\t' read -r sha _ref; do
      [ -n "$sha" ] || continue
      # An unrelated server ref may name an object this clone has not fetched yet.
      commit=$(git rev-parse --verify "$sha^{commit}" 2>/dev/null) || continue
      published+=("$commit")
    done <<< "$tips"
    checked=1
  fi
  # Exclude only commits the server currently advertises. A rebased branch
  # can include merges from published main; a stale local origin/* ref can
  # include a merge that the server no longer has. The ref line's remote_sha
  # is all zeroes for a new branch, which needs no special revision argument.
  merges=$(git rev-list --merges "$local_sha" --not "${published[@]}" 2>/dev/null)
  if [ -n "$merges" ]; then
    printf 'github-guard: BLOCKED — push to %s contains merge commit(s):\n' "$remote_ref" >&2
    printf '%s\n' "$merges" | sed 's/^/  /' >&2
    printf '  Linearize first:  git pull --rebase   |   git rebase <upstream>\n' >&2
    status=1
  fi
done
exit $status
