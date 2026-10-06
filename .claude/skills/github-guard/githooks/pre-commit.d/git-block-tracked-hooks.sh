#!/usr/bin/env bash
# guard: git-block-tracked-hooks
# Refuse to commit git hooks into the repository's .githooks/ directory.
#
# A hooks directory inside the working tree is code that runs on a developer's
# machine, with their credentials, from whatever the last merged or checked-out
# commit put there. Point core.hooksPath at it, or have an installer copy it
# into .git/hooks, and any pull request can change what runs on the next commit.
# github-guard's own guards live in .git/hooks, installed per clone by
# install.sh, where no ref can reach them. So a commit that ADDS or CHANGES a
# file under .githooks/ is refused; one that deletes them is the fix and goes
# through. Bypass once with `git commit --no-verify`.
set -u

staged=$(git diff --cached --name-only --diff-filter=ACMR -- .githooks)
[ -n "$staged" ] || exit 0

echo "git-block-tracked-hooks: hooks do not belong in the repository:" >&2
printf '%s\n' "$staged" | sed 's/^/  /' >&2
echo "  A committed hook runs whatever the last merged change put there, on every" >&2
echo "  developer's machine. Guards live in .git/hooks, per clone, installed by" >&2
echo "  github-guard's install.sh, where no commit can reach them." >&2
echo "  Unstage with: git restore --staged .githooks" >&2
exit 1
