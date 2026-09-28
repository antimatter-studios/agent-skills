#!/usr/bin/env bash
# guard: git-no-ff-main  (reference-transaction, SHIPS DISARMED — see
#        ../lib/reference-transaction.dispatcher for how to arm it)
# Refuse to move the local default branch onto anything that did not come from
# the remote. Local; one network call, made only on the way to refusing (see
# below). Hard block.
#
# WHEN TO ARM IT. git-no-push-to-main already stops unreviewed work reaching the
# remote's default branch. What it cannot see is the LOCAL one moving:
# `git switch main && git merge --ff-only my-branch` makes no commit (so
# pre-commit never runs) and no merge commit (so pre-merge-commit never runs).
# In a clone one person uses, that is their own bookkeeping. In a clone several
# people or agents share — each branching from, testing against or syncing the
# same local main — it quietly hands everyone unreviewed commits. Arm it there.
#
# The distinction it has to draw, because one of these is routine:
#
#   A  git fetch origin main:main   sync with the remote. Adds nothing new; the
#      git pull --ff-only           content already went through a PR. ALLOW.
#
#   B  git merge --ff-only mywork   puts YOUR unreviewed commits on main. BLOCK.
#
# Both move refs/heads/main, so the ref name cannot tell them apart. What can:
# in A the new commit is already on the remote-tracking branch; in B it is not.
set -u

# Only the "prepared" stage can refuse; "committed" and "aborted" are reports.
[ "${1:-}" = "prepared" ] || exit 0

default=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
default=${default#origin/}
[ -n "$default" ] || default=main
tracking="refs/remotes/origin/$default"

# No remote-tracking branch yet (a fresh clone mid-fetch, or no remote at all):
# there is nothing to compare against, so this cannot judge. Fail open.
git rev-parse --verify -q "$tracking" >/dev/null 2>&1 || exit 0

status=0
while read -r _old new ref; do
  [ "$ref" = "refs/heads/$default" ] || continue
  case "$new" in *[!0]*) ;; *) continue ;; esac   # deletion: not our business

  # Already on the remote-tracking branch => this is a sync (case A). Allow.
  if git merge-base --is-ancestor "$new" "$tracking" 2>/dev/null; then
    continue
  fi

  # Not on it YET is not the same as not on the remote. `git fetch origin
  # main:main` moves main first and origin/main after, in two transactions, so
  # at this point a genuine sync is still ahead of the tracking branch. Only
  # now, on the way to refusing, ask the remote itself — the one network call
  # this guard makes, and never on the routine path. Offline, it cannot confirm
  # and refuses; `git pull --ff-only` updates origin/main first and still works.
  remote_tip=$(git ls-remote origin "refs/heads/$default" 2>/dev/null | cut -f1)
  if [ -n "$remote_tip" ] && git merge-base --is-ancestor "$new" "$remote_tip" 2>/dev/null; then
    continue
  fi

  cat >&2 <<MSG
github-guard: BLOCKED — refusing to move '$default' onto unreviewed commits.

  $new is not on $tracking, so this is not a sync with the remote —
  it is putting local work onto $default, which is what pull requests are for.

  Syncing with the remote is fine and is not what this blocked:
    git fetch origin $default:$default

  To land the work, push the branch and open a PR:
    git push -u origin HEAD
    gh pr create
MSG
  status=1
done
exit $status
