#!/usr/bin/env bash
# guard: github-auto-merge
# Keep the repo's "Allow auto-merge" setting in line with what its
# .github-guard declares on the default branch. Owner-only, fail-open — NEVER
# blocks the commit.
#
#   [merge]
#   	auto = true     → allow_auto_merge on (only once main has required checks)
#   	auto = false    → allow_auto_merge off
#   (no merge.auto)   → the setting is left exactly as it is
#
# The setting only ALLOWS auto-merge; something still has to ask for it on each
# pull request. agent-skills' .github/actions/auto-merge does that from CI.
#
# THE REFUSAL. Auto-merge merges a pull request the moment its requirements are
# met. With no required status checks, the requirements are met the moment the
# PR is opened, so an "auto-merged" PR lands before CI has run a single step.
# Enabling it on such a branch is refused, loudly, and retried on every commit;
# github-protect-main (which sorts after this guard) is what adds the required
# checks, so a repo being set up converges on the following commit.
#
# delete_branch_on_merge is deliberately NOT touched. It is a separate
# preference with its own cost — a branch deleted on merge is gone from under
# whoever else has it checked out — and auto-merge works either way.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

slug=$(gg_repo_slug); [ -n "$slug" ] || exit 0
gg_have_gh || { echo "github-guard: gh not installed/authed — skipping auto-merge setting for $slug" >&2; exit 0; }
owner=${slug%%/*}
gg_user_owns "$owner" || exit 0

branch=$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null) || {
  echo "github-guard: couldn't read default branch for $slug — skipping auto-merge setting" >&2; exit 0; }
[ -n "$branch" ] || exit 0

# Read from the default branch on the SERVER, never the working tree: turning
# auto-merge on changes what a pull request can do without anyone watching, so
# a branch that is merely checked out must not be able to switch it on.
decl=$(mktemp "${TMPDIR:-/tmp}/gg-decl.XXXXXX")
trap 'rm -f "$decl"' EXIT
gg_fetch_server_decl "$slug" "$branch" "$decl"; fetched=$?
# Absent or unreachable: nothing declared that we could see, so change nothing.
[ "$fetched" = 1 ] && exit 0
if [ "$fetched" = 2 ]; then
  echo "github-guard: $GG_DECL_FILE on $branch is not a file — leaving auto-merge as it is" >&2; exit 0
fi
if ! gg_decl_valid "$decl"; then
  echo "github-guard: $GG_DECL_FILE on $branch is not valid git-config ($(gg_decl_error "$decl")) — leaving auto-merge as it is" >&2
  exit 0
fi

want=$(gg_decl_config "$decl" --type=bool --get merge.auto 2>/dev/null); rc=$?
case "$rc" in
  0) ;;
  1) exit 0 ;;   # no merge.auto: not this file's business, leave the setting alone
  *) echo "github-guard: merge.auto on $branch is not a boolean — leaving auto-merge as it is" >&2; exit 0 ;;
esac

have=$(gh api "repos/$slug" --jq '.allow_auto_merge' 2>/dev/null)
case "$have" in
  true|false) ;;
  *) echo "github-guard: couldn't read the auto-merge setting for $slug — skipping" >&2; exit 0 ;;
esac

if [ "$want" = false ]; then
  [ "$have" = false ] && exit 0
  echo "github-guard: $slug merge.auto = false — turning auto-merge off…" >&2
  if gh api -X PATCH "repos/$slug" -F allow_auto_merge=false >/dev/null 2>&1; then
    echo "github-guard: $slug auto-merge off ✓" >&2
  else
    echo "github-guard: PATCH failed for $slug (need repo admin?) — not blocking" >&2
  fi
  exit 0
fi

# want = true. Count the checks main requires; an unprotected branch (404) or an
# unreadable answer counts as none, because "couldn't tell" must not enable it.
checks=$(gh api "repos/$slug/branches/$branch/protection" \
  --jq '(.required_status_checks.checks // .required_status_checks.contexts // []) | length' 2>/dev/null) || checks=0
case "$checks" in '' | *[!0-9]*) checks=0 ;; esac
if [ "$checks" = 0 ]; then
  if [ "$have" = true ]; then
    echo "github-guard: WARNING $slug allows auto-merge but $branch requires no status checks —" >&2
    echo "             an auto-merge PR merges without waiting for CI. Declare checks.required," >&2
    echo "             or set merge.auto = false." >&2
  else
    echo "github-guard: NOT enabling auto-merge on $slug: $branch requires no status checks, so an" >&2
    echo "             auto-merge PR would merge at once, before CI ran. It is enabled on the first" >&2
    echo "             commit after $branch has required checks (github-protect-main adds them)." >&2
  fi
  exit 0
fi

[ "$have" = true ] && exit 0
echo "github-guard: $slug merge.auto = true — turning auto-merge on ($branch requires $checks check(s))…" >&2
if gh api -X PATCH "repos/$slug" -F allow_auto_merge=true >/dev/null 2>&1; then
  echo "github-guard: $slug auto-merge on ✓" >&2
else
  echo "github-guard: PATCH failed for $slug (need repo admin?) — not blocking" >&2
fi
exit 0
