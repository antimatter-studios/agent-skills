#!/usr/bin/env bash
# guard: git-no-commit-on-main
# Refuse to commit while the default branch is checked out. Local, no network.
# Hard block — but only while the walls are armed (see below).
#
# WHY IT EXISTS. github-protect-main makes the default branch "pull requests
# only" by asking GitHub to protect it. GitHub refuses that for a private
# repository without a paid plan (403 "Upgrade to GitHub Pro"), and then nothing
# stops a commit on main, a fast-forward of local work onto it, or a push of it.
# That is the gap this closes, together with git-no-push-to-main.
#
# SELF-GATING. github-protect-main records the refusal in the clone's git config
# (github-guard.protection=unavailable — gg_walls_armed) and clears it once
# protection works again. Unarmed, this is a no-op: where the server enforces
# the rule, a local copy of it would only be a second opinion. A fresh clone
# arms on its first commit — github-protect-main runs after this guard, so that
# one commit is not checked.
#
# ON --no-verify: git skips every pre-commit hook when you pass it, so nothing
# here can see it. That hole closes only server-side. Deliberately not printed
# below: telling a blocked person how to bypass the block teaches the workaround.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

gg_walls_armed || exit 0

branch=$(git symbolic-ref --short -q HEAD) || exit 0   # detached HEAD: fine

# The default branch, from the remote if it has told us, else the usual names.
# No network call: pre-commit runs constantly and must not wait on one.
default=$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
default=${default#origin/}
if [ -z "$default" ]; then
  case "$branch" in
    main | master | trunk) default="$branch" ;;
    *) default="" ;;
  esac
fi

[ -n "$default" ] || exit 0
[ "$branch" = "$default" ] || exit 0

cat >&2 <<MSG
github-guard: BLOCKED — refusing to commit on '$branch'.

Work goes on a branch and reaches $branch through a pull request.

  Your staged and unstaged changes are untouched. To carry them onto a branch:

    git switch -c <a-name-for-the-work>
    git commit ...

  If you have already committed here by mistake, nothing is lost:

    git branch <a-name-for-the-work>     # keep the commits
    git reset --hard origin/$branch      # put $branch back

MSG
exit 1
