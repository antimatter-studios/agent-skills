#!/usr/bin/env bash
# Run every test suite, the way CI's Tests step does.
#
#   .github/scripts/run-suites.sh [suite ...]   (default: every skill's tests/*.sh)
set -euo pipefail
[ $# -gt 0 ] || set -- .claude/skills/*/tests/*.sh
found=0
for t in "$@"; do
  [ -e "$t" ] || continue
  found=1
  printf '\n=== %s\n' "$t"
  bash "$t"
done
[ "$found" = 1 ] || { echo "no test suites found" >&2; exit 1; }
