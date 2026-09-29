#!/usr/bin/env bash
# Run every test suite, the way CI's Tests step does.
#
#   .github/scripts/run-suites.sh [suite ...]
#       (default: every skill's tests/*.sh, and .github/tests/*.sh)
#
# A suite passes only if it exits 0 AND its last line is
#
#   <basename>: all N checks passed
#
# with N at least 1. Exit 0 alone is not evidence a suite finished: an early
# `exit 0`, or a setup that collapsed so the remaining checks were satisfied by
# absence, gives status 0 having run a prefix of its checks. The trailing line
# is printed only after the last check, and N is what the suite itself
# counted. Every suite is run and every failure named before the step fails.
set -uo pipefail
[ $# -gt 0 ] || set -- .claude/skills/*/tests/*.sh .github/tests/*.sh
suites=0 checks=0 failed=()
out=$(mktemp); trap 'rm -f "$out"' EXIT
for t in "$@"; do
  [ -e "$t" ] || continue
  suites=$((suites + 1))
  name=$(basename "$t" .sh)
  printf '\n=== %s\n' "$t"
  bash "$t" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  last=$(grep -v '^[[:space:]]*$' "$out" | tail -1)
  n=$(printf '%s\n' "$last" | sed -nE "s/^${name//./\\.}: all ([0-9]+) checks passed\$/\\1/p")
  if [ "$rc" != 0 ]; then
    failed+=("$t: exit $rc")
  elif [ -z "$n" ]; then
    failed+=("$t: no verdict — the last line must be '$name: all N checks passed'")
  elif [ "$n" -lt 1 ]; then
    failed+=("$t: ran no checks")
  else
    checks=$((checks + n))
  fi
done
[ "$suites" -gt 0 ] || { echo "no test suites found" >&2; exit 1; }
if [ ${#failed[@]} -gt 0 ]; then
  printf '\n%d of %d suites failed:\n' "${#failed[@]}" "$suites" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
printf '\n%d suites, %d checks, all passed\n' "$suites" "$checks"
