#!/usr/bin/env bash
# guard: git-no-push-to-main
# Refuse to push anything to the default branch. Local, no network. Hard block —
# but only while the walls are armed (gg_walls_armed; see git-no-commit-on-main
# for why they exist and how they arm).
#
# THIS IS THE HALF THAT CLOSES THE HOLE. Blocking commits while main is checked
# out stops the obvious mistake and none of these:
#
#   git push origin my-branch:main        never touched main locally
#   git push origin HEAD:main             same
#   git switch main && git merge x        a fast-forward makes no commit at all,
#   git push                              so pre-commit never runs
#
# Reads the ref list git supplies on stdin, like git-block-merge-commits.
#
# ON --no-verify: git skips the hook entirely. That hole closes server-side only.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

gg_walls_armed || exit 0

default=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
default=${default#origin/}
[ -n "$default" ] || default=main

status=0
while read -r local_ref local_sha remote_ref remote_sha; do
  : "$local_ref" "$local_sha" "$remote_sha"
  [ "$remote_ref" = "refs/heads/$default" ] || continue

  cat >&2 <<MSG
github-guard: BLOCKED — refusing to push to '$default'.

  $default moves by pull request only. Nothing has been pushed.

  Push your branch instead, then open a PR:

    git push -u origin HEAD
    gh pr create

  If you were fast-forwarding a stale local $default, you do not need to push
  it at all — that ref is local bookkeeping:

    git fetch origin $default:$default

MSG
  status=1
done
exit $status
