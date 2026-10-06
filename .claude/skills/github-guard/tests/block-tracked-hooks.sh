#!/usr/bin/env bash
# Tests for git-block-tracked-hooks.
#
#   tests/block-tracked-hooks.sh [githooks-dir]   (default: the sibling githooks/)
#
# A hooks directory committed to the repository is code that runs on a
# developer's machine, with their credentials, from whatever the last merged
# change put there: point core.hooksPath at it, or copy it into .git/hooks, and
# any pull request can change what runs on the next commit. github-guard keeps
# its guards in .git/hooks, per clone, where no ref can reach them. The guard
# under test refuses a commit that adds or changes anything under .githooks/,
# and lets the deletion through, because removing such a directory is the fix.
set -uo pipefail

G=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
guard="$G/pre-commit.d/git-block-tracked-hooks.sh"
[ -f "$guard" ] || { echo "no guard at $guard" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

repo="$root/repo"
git init -q "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t

run_guard() { (cd "$repo" && bash "$guard" 2>&1); }

printf 'git-block-tracked-hooks (%s)\n' "$G"

# An ordinary file passes, silently.
printf 'hello\n' > "$repo/readme.txt"
git -C "$repo" add readme.txt
out=$(run_guard); rc=$?
[ "$rc" -eq 0 ] && ok "an ordinary file is allowed" || bad "an ordinary file is allowed (rc=$rc)"
[ -z "$out" ] && ok "and produces no output" || bad "and produces no output (output: ${out//$'\n'/ | })"
git -C "$repo" commit -q -m base --no-verify

# Adding a hook under .githooks/ is refused, and the message says why and where
# the guards belong instead.
mkdir -p "$repo/.githooks/pre-commit.d"
printf '#!/bin/sh\necho hi\n' > "$repo/.githooks/pre-commit"
printf '#!/bin/sh\n' > "$repo/.githooks/pre-commit.d/x.sh"
git -C "$repo" add .githooks
out=$(run_guard); rc=$?
[ "$rc" -ne 0 ] && ok "adding .githooks/ is refused" || bad "adding .githooks/ is refused (rc=$rc)"
case "$out" in *".githooks/pre-commit"*) ok "and the file is named" ;;
  *) bad "and the file is named (output: ${out//$'\n'/ | })" ;; esac
case "$out" in *".git/hooks"*) ok "and the message says where the guards live instead" ;;
  *) bad "and the message says where the guards live instead (output: ${out//$'\n'/ | })" ;; esac

# Changing a hook that is already committed is refused too: the modification is
# exactly what a hostile change would be.
git -C "$repo" commit -q -m "hooks already present" --no-verify
printf '#!/bin/sh\necho changed\n' > "$repo/.githooks/pre-commit"
git -C "$repo" add .githooks/pre-commit
out=$(run_guard); rc=$?
[ "$rc" -ne 0 ] && ok "changing a committed hook is refused" || bad "changing a committed hook is refused (rc=$rc)"
git -C "$repo" reset -q --hard

# A commit that does not touch them is refused too, while they are tracked:
# a repository that still carries .githooks/ has to drop it at its next
# commit, rather than keep it for as long as nobody edits it.
printf 'more\n' >> "$repo/readme.txt"
git -C "$repo" add readme.txt
out=$(run_guard); rc=$?
[ "$rc" -ne 0 ] && ok "any commit is refused while .githooks/ is tracked" || bad "any commit is refused while .githooks/ is tracked (rc=$rc)"
case "$out" in *"git rm -r --cached .githooks"*|*"git rm -r .githooks"*) ok "and the message says how to remove them" ;;
  *) bad "and the message says how to remove them (output: ${out//$'\n'/ | })" ;; esac
git -C "$repo" reset -q --hard

# Deleting them is the fix, so the deletion goes through.
git -C "$repo" rm -q -r .githooks
out=$(run_guard); rc=$?
[ "$rc" -eq 0 ] && ok "deleting .githooks/ is allowed" || bad "deleting .githooks/ is allowed (rc=$rc, output: ${out//$'\n'/ | })"
git -C "$repo" commit -q -m "hooks gone" --no-verify

# A path that merely contains the word is not a hooks directory.
mkdir -p "$repo/docs"
printf 'notes\n' > "$repo/docs/githooks.md"
printf 'x\n' > "$repo/.githooks-notes"
git -C "$repo" add docs .githooks-notes
out=$(run_guard); rc=$?
[ "$rc" -eq 0 ] && ok "githooks.md and .githooks-notes are not hooks" || bad "githooks.md and .githooks-notes are not hooks (rc=$rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "block-tracked-hooks: all $pass checks passed"
