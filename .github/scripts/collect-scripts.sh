#!/usr/bin/env bash
# Collect every script in the tree for CI's Syntax and ShellCheck steps.
#
#   .github/scripts/collect-scripts.sh [root]    (default: cwd)
#
# Writes scripts.z (shell) and python.z, NUL-separated, into the current
# directory. What counts as a script: any file with a shebang.
set -euo pipefail
root=${1:-.}
: > scripts.z
: > python.z
find "$root" -path "$root/.git" -prune -o -type f -print > files.txt
while IFS= read -r f; do
  IFS= read -r first < "$f" 2>/dev/null || continue
  case "$first" in
    '#!'*python*) printf '%s\0' "$f" >> python.z ;;
    '#!'*bash*|'#!'*/sh|'#!'*' sh') printf '%s\0' "$f" >> scripts.z ;;
    '#!'*) echo "::error file=$f::no syntax check for shebang: $first"; exit 1 ;;
  esac
done < files.txt
rm files.txt
echo "shell:"; tr '\0' '\n' < scripts.z | sed 's/^/  /'
echo "python:"; tr '\0' '\n' < python.z | sed 's/^/  /'
test -s scripts.z
