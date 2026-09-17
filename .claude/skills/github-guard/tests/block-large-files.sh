#!/usr/bin/env bash
# Tests for git-block-large-files.
#
#   tests/block-large-files.sh [githooks-dir]   (default: the sibling githooks/)
#
# The guard read the size with `stat -f '%z'` first. On GNU coreutils that is
# filesystem status, not file size, and it succeeds, so on Linux every staged
# file produced "integer expression expected" and nothing was ever blocked. The
# cases below run on whichever platform CI uses, so a regression shows up there.
set -uo pipefail

G=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
guard="$G/pre-commit.d/git-block-large-files.sh"
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

run_guard() { (cd "$repo" && GITHUB_GUARD_MAX_FILE_MB=1 bash "$guard" 2>&1); }

# A small file passes, and says nothing at all.
printf 'hello\n' > "$repo/small.txt"
git -C "$repo" add small.txt
out=$(run_guard); rc=$?
[ "$rc" -eq 0 ] && ok "a small file is allowed" || bad "a small file is allowed (rc=$rc)"
[ -z "$out" ] && ok "and produces no output" || bad "and produces no output (output: ${out//$'\n'/ | })"
git -C "$repo" reset -q

# A file over the limit is blocked and named.
head -c $((2 * 1024 * 1024)) /dev/zero > "$repo/big.bin"
git -C "$repo" add big.bin
out=$(run_guard); rc=$?
[ "$rc" -ne 0 ] && ok "a file over the limit is blocked" || bad "a file over the limit is blocked (rc=$rc)"
case "$out" in *"'big.bin' is 2 MiB"*) ok "and the message names it and its size" ;;
  *) bad "and the message names it and its size (output: ${out//$'\n'/ | })" ;; esac
case "$out" in *"integer expression"*) bad "no shell arithmetic error (output: ${out//$'\n'/ | })" ;;
  *) ok "no shell arithmetic error" ;; esac
git -C "$repo" reset -q

# Exactly at the limit is allowed; the rule is "larger than".
head -c $((1024 * 1024)) /dev/zero > "$repo/edge.bin"
git -C "$repo" add edge.bin
run_guard >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "a file exactly at the limit is allowed" || bad "a file exactly at the limit is allowed (rc=$rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
