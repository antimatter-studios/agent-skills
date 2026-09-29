#!/usr/bin/env bash
# Tests for the floors CI puts under its own verdicts.
#
#   .github/tests/ci-floors.sh
#
# CI printed "all scripts parse", "shellcheck clean" and ran the suites with
# floors of ONE: `test -s` on the collected list, and `found=1` once any suite
# existed. A run that examined one script and one suite printed the same words
# as one that examined all of them. The collector also dropped, in silence, a
# file whose only line was an unterminated shebang, and any file it could not
# read. Each case here builds a throwaway tree, runs the real script from
# .github/scripts/ against it, and asserts on what it accepts.
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
collect="$here/scripts/collect-scripts.sh"
suites="$here/scripts/run-suites.sh"

root=$(mktemp -d)
trap 'chmod -R u+rwx "$root" 2>/dev/null; rm -rf "$root"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

# A tree with two shell scripts, one python script and a data file.
tree() {
  local t="$1"
  mkdir -p "$t/hooks"
  printf '#!/usr/bin/env bash\ntrue\n' > "$t/hooks/a"
  printf '#!/bin/sh\ntrue\n' > "$t/hooks/b.sh"
  printf '#!/usr/bin/env python3\npass\n' > "$t/c.py"
  printf 'just data\n' > "$t/hooks/required-checks"
}
collect_in() {  # collect_in DIR -> rc; output in DIR.out, lists in DIR.work/
  mkdir -p "$1.work"
  ( cd "$1.work" && bash "$collect" "$1" ) >"$1.out" 2>&1
}
listed() { tr '\0' '\n' < "$1" | grep -c . ; }

echo "collect-scripts"

t="$root/t1"; tree "$t"
collect_in "$t"; rc=$?
[ "$rc" = 0 ] && ok "control: an ordinary tree is collected" || bad "an ordinary tree was refused: $(cat "$t.out")"
[ "$(listed "$t.work/scripts.z")" = 2 ] && ok "control: both shell scripts are listed" \
  || bad "shell list: $(tr '\0' ' ' < "$t.work/scripts.z")"
grep -qE '(^|[^0-9])3 files with a shebang' "$t.out" \
  && ok "the verdict states how many files it checked against" || bad "no count in: $(tail -3 "$t.out")"

t="$root/t2"; tree "$t"
printf '#!/usr/bin/env bash' > "$t/hooks/only-a-shebang"
collect_in "$t"; rc=$?
tr '\0' '\n' < "$t.work/scripts.z" | grep -q 'only-a-shebang$' \
  && ok "a file whose only line is an unterminated shebang is collected" \
  || bad "a one-line unterminated shebang file was dropped (rc=$rc)"

t="$root/t3"; tree "$t"
printf '#!/usr/bin/env bash\ntrue\n' > "$t/hooks/locked"; chmod 000 "$t/hooks/locked"
if [ -r "$t/hooks/locked" ]; then
  bad "the unreadable fixture is readable (running as root?) — this case needs a non-root user"
else
  collect_in "$t"; rc=$?
  [ "$rc" != 0 ] && ok "an unreadable file fails the collection" || bad "an unreadable file was skipped in silence"
  grep -qE 'cannot read.*hooks/locked' "$t.out" && ok "and the failure names it" || bad "the unreadable file is not named: $(cat "$t.out")"
fi
chmod 644 "$t/hooks/locked" 2>/dev/null

t="$root/t4"; tree "$t"
printf '#!/usr/bin/env ruby\nputs 1\n' > "$t/r.rb"
collect_in "$t"; rc=$?
[ "$rc" != 0 ] && ok "control: a shebang with no syntax check is still refused" || bad "an unknown shebang was accepted"

echo "run-suites"

# suite NAME BODY: a test file whose basename is NAME.sh.
suite() { mkdir -p "$root/s"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$root/s/$1.sh"; }
run_suites() { bash "$suites" "$@" >"$root/s.out" 2>&1; }

suite good 'echo "good: all 3 checks passed"'
suite other 'echo noise; echo "other: all 2 checks passed"'
run_suites "$root/s/good.sh" "$root/s/other.sh"; rc=$?
[ "$rc" = 0 ] && ok "control: suites that end with their verdict pass" || bad "good suites refused: $(cat "$root/s.out")"
grep -qF '2 suites, 5 checks' "$root/s.out" \
  && ok "the verdict totals suites and checks" || bad "no totals in: $(tail -2 "$root/s.out")"

suite truncated 'echo "ok  something"; exit 0'
run_suites "$root/s/good.sh" "$root/s/truncated.sh"; rc=$?
[ "$rc" != 0 ] && ok "a suite that exits 0 without its verdict line fails" \
  || bad "a suite with no verdict line was accepted"
grep -qE 'truncated\.sh.*no verdict' "$root/s.out" && ok "and the failure names the suite" || bad "suite not named: $(tail -2 "$root/s.out")"

suite empty 'echo "empty: all 0 checks passed"'
run_suites "$root/s/empty.sh"; rc=$?
[ "$rc" != 0 ] && ok "a suite that ran no checks fails" || bad "a suite with zero checks was accepted"

suite misnamed 'echo "good: all 3 checks passed"'
run_suites "$root/s/misnamed.sh"; rc=$?
[ "$rc" != 0 ] && ok "a verdict naming another suite does not count" || bad "a borrowed verdict line was accepted"

suite red 'echo "red: all 1 checks passed"; exit 1'
run_suites "$root/s/red.sh"; rc=$?
[ "$rc" != 0 ] && ok "control: a suite that exits non-zero fails" || bad "a failing suite was accepted"

run_suites "$root/s/does-not-exist-*.sh"; rc=$?
[ "$rc" != 0 ] && ok "control: no suites at all fails" || bad "an empty glob was accepted"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
echo "ci-floors: all $pass checks passed"
