#!/usr/bin/env bash
# guard: github-protect-main
# Ensure the repo's default branch is protected: require a PR (no direct
# pushes), enforced for admins too, linear history, no force-push/deletion —
# i.e. force everyone into PR mode. Owner-only, fail-open — NEVER blocks.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

slug=$(gg_repo_slug); [ -n "$slug" ] || exit 0
gg_have_gh || { echo "github-guard: gh not installed/authed — skipping branch-protection check for $slug" >&2; exit 0; }
owner=${slug%%/*}
gg_user_owns "$owner" || exit 0

branch=$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null) || {
  echo "github-guard: couldn't read default branch for $slug — skipping" >&2; exit 0; }
[ -n "$branch" ] || exit 0

# Required status checks: auto-discover the checks that gate the default branch
# and require them, strict. We discover from the branch's own check-SUITES
# (head_branch == the default branch), NOT from every check-run on the HEAD
# commit: when HEAD is also a release tag's target (you tag the commit you just
# merged), that commit also carries tag-triggered suites — e.g. a release
# workflow on a vN.N.N tag — whose jobs never run on a pull request. Requiring
# those would make every PR wait forever on checks that can't run. Filtering by
# suite head_branch keeps only the PR/branch checks; the github-actions app
# filter still excludes third-party checks like coderabbit. Self-healing — a
# newly-added job is required one commit cycle after it first runs on the
# branch; never strips existing checks on a transient empty discovery.
#
# Both `desired` (here) and `current` (the read-back below) end as compact JSON
# straight from jq (`jq -c` / `tojson`), so escaping (quotes, backslashes) and
# sort order match and the equality check below is exact. If jq is absent we
# leave `desired` empty and preserve whatever's already set (fail-open).
desired='[]'
if command -v jq >/dev/null 2>&1; then
  # Suite IDs for github-actions runs that ran on the default branch itself
  # (excludes tag-triggered release suites, whose head_branch is the tag name).
  suite_ids=$(gh api --paginate "repos/$slug/commits/$branch/check-suites?per_page=100" \
    --jq ".check_suites[] | select(.app.slug==\"github-actions\") | select(.head_branch==\"$branch\") | .id" 2>/dev/null)
  desired=$(
    for sid in $suite_ids; do
      gh api --paginate "repos/$slug/check-suites/$sid/check-runs?per_page=100" \
        --jq '.check_runs[] | select(.app.slug=="github-actions") | .name' 2>/dev/null
    done | jq -sRc 'split("\n") | map(select(length > 0)) | map({context: .}) | unique'
  )
  [ -n "$desired" ] || desired='[]'
fi

# Current protection facts in one call: PR reviews present? admins enforced?
# plus the currently-required checks from the modern `checks` field (normalized
# to {context}, sorted). Each value is emitted on its OWN line, NOT through
# `@tsv` — `@tsv` adds a second escaping pass on top of `tojson`, so a job name
# containing `"` or `\` would read back double-escaped and never equal the
# `jq -c`-encoded `desired`, re-applying protection on every commit. `tojson`
# output is single-line, so line-reading each field is safe. Empty when unprotected.
{ IFS= read -r has_reviews; IFS= read -r has_admins; IFS= read -r current; } < <(
  gh api "repos/$slug/branches/$branch/protection" --jq \
    '(.required_pull_request_reviews != null),
     (.enforce_admins.enabled // false),
     ((.required_status_checks.checks // []) | map({context: .context}) | unique | tojson)' 2>/dev/null)
[ -n "$current" ] || current='[]'

# Checks to require: prefer a fresh discovery; else keep what's already set;
# never strip checks just because this commit's HEAD has no Actions runs yet.
if [ -n "$desired" ] && [ "$desired" != "[]" ]; then
  want="$desired"
elif [ -n "$current" ] && [ "$current" != "[]" ]; then
  want="$current"
else
  want="[]"
fi

# Already exactly how we want it (PR-mode + admins + matching checks)? Skip.
if [ "$has_reviews" = "true" ] && [ "$has_admins" = "true" ] && [ "${current:-[]}" = "$want" ]; then
  exit 0
fi

if [ "$want" = "[]" ]; then
  rsc='null'
  echo "github-guard: protecting $slug:$branch (require PR, enforce admins, linear history)…" >&2
else
  rsc="{ \"strict\": true, \"checks\": $want }"
  echo "github-guard: protecting $slug:$branch (require PR, enforce admins, linear history, required checks $want)…" >&2
fi

payload=$(cat <<JSON
{
  "required_status_checks": $rsc,
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0, "dismiss_stale_reviews": false, "require_code_owner_reviews": false },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
)
if printf '%s' "$payload" | gh api -X PUT "repos/$slug/branches/$branch/protection" \
     -H "Accept: application/vnd.github+json" --input - >/dev/null 2>&1; then
  echo "github-guard: $slug:$branch protected ✓" >&2
else
  echo "github-guard: protection PUT failed for $slug:$branch (need repo admin?) — not blocking" >&2
fi
exit 0
