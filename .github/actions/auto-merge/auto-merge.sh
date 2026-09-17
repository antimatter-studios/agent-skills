#!/usr/bin/env bash
# The auto-merge action's logic, kept in a script so it can be tested with `gh`
# stubbed (see .claude/skills/github-guard/tests/auto-merge-action.sh).
#
# Reads the event from $GITHUB_EVENT_PATH and $GITHUB_EVENT_NAME, writes
# result=<...> to $GITHUB_OUTPUT when set. Exits non-zero only when it decided
# to enable auto-merge and GitHub refused, so a misconfigured repo is visible
# rather than silently never merging.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
lib=${GG_COMMON_SH:-$here/../../../.claude/skills/github-guard/githooks/lib/common.sh}
[ -f "$lib" ] || { echo "::error::auto-merge: $lib is missing"; exit 1; }
# shellcheck source=../../../.claude/skills/github-guard/githooks/lib/common.sh
. "$lib"

result() {
  echo "auto-merge: $2"
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "result=$1" >> "$GITHUB_OUTPUT"
  exit 0
}

case "${GITHUB_EVENT_NAME:-}" in
  pull_request|pull_request_target) ;;
  *) result skipped:event "not a pull request event (${GITHUB_EVENT_NAME:-unset}) — nothing to do" ;;
esac

ev=${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is not set}
{ IFS= read -r number; IFS= read -r repo; IFS= read -r head_repo; IFS= read -r base
  IFS= read -r default_branch; IFS= read -r draft; } < <(jq -r '
  .pull_request.number, .repository.full_name,
  (.pull_request.head.repo.full_name // ""), .pull_request.base.ref,
  .repository.default_branch, (.pull_request.draft // false)' "$ev")

# A deleted fork has no head repo at all; that is a fork too.
[ "$head_repo" = "$repo" ] \
  || result skipped:fork "#$number comes from ${head_repo:-a deleted fork}, not $repo — fork pull requests are never auto-merged"
[ "$base" = "$default_branch" ] \
  || result skipped:base "#$number targets $base, not $default_branch — only pull requests into the default branch wait on its required checks"
[ "$draft" = false ] \
  || result skipped:draft "#$number is a draft — run again on ready_for_review"

decl=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gg-decl.XXXXXX")
trap 'rm -f "$decl"' EXIT
rc=0; gg_fetch_server_decl "$repo" "$default_branch" "$decl" || rc=$?
case "$rc" in
  0) ;;
  2) result skipped:invalid "$GG_DECL_FILE on $default_branch is not a file" ;;
  *) result skipped:no-file "no readable $GG_DECL_FILE on $default_branch" ;;
esac
gg_decl_valid "$decl" \
  || result skipped:invalid "$GG_DECL_FILE on $default_branch is not valid git-config ($(gg_decl_error "$decl"))"
want=$(gg_decl_config "$decl" --type=bool --get merge.auto 2>/dev/null) || want=
[ "$want" = true ] \
  || result skipped:not-declared "$GG_DECL_FILE on $default_branch does not set merge.auto = true"

echo "auto-merge: enabling squash auto-merge for $repo#$number"
if ! gh pr merge "$number" --repo "$repo" --auto --squash; then
  echo "::error::auto-merge: GitHub refused to enable auto-merge on #$number. Is \"Allow auto-merge\" on for $repo (github-guard's github-auto-merge guard turns it on once $default_branch requires status checks), and does the token have contents: write and pull-requests: write?"
  exit 1
fi
[ -z "${GITHUB_OUTPUT:-}" ] || echo "result=enabled" >> "$GITHUB_OUTPUT"
