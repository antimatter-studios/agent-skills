#!/usr/bin/env bash
# Collect every script in the tree for CI's Syntax and ShellCheck steps.
#
#   .github/scripts/collect-scripts.sh [root]    (default: cwd)
#
# Writes scripts.z (shell) and python.z, NUL-separated, into the current
# directory, and prints how many files it classified.
#
# What counts as a script: any file with a shebang. Git hooks are extensionless
# by necessity, so a name-based rule either misses the dispatchers or sweeps up
# data files that live beside them — the old extensionless required-checks
# declaration was linted as shell on the first run here.
#
# The shebang also names the language, and that is the split: a
# `#!/usr/bin/env python3` file handed to `bash -n` is a syntax error on its
# first regex. A shebang naming neither is refused, not left unchecked.
#
# NOTHING IS SKIPPED IN SILENCE. The first line is read with `head`, not
# `read`, which returns non-zero on a final line with no newline and so dropped
# a file whose only line was its shebang. A file that cannot be read fails the
# collection by name: an unreadable file in the payload is a finding. And the
# count of files classified must equal the count of files with a shebang, so
# the verdict is a statement about the whole tree, with the number in it.
set -euo pipefail
root=${1:-.}
: > scripts.z
: > python.z
shebangs=0
while IFS= read -r -d '' f; do
  if ! magic=$(head -c2 -- "$f" 2>/dev/null) || [ ! -r "$f" ]; then
    echo "::error file=$f::cannot read $f"; exit 1
  fi
  [ "$magic" = '#!' ] || continue
  shebangs=$((shebangs + 1))
  first=$(head -n1 -- "$f")
  case "$first" in
    '#!'*python*) printf '%s\0' "$f" >> python.z ;;
    '#!'*bash*|'#!'*/sh|'#!'*' sh') printf '%s\0' "$f" >> scripts.z ;;
    '#!'*) echo "::error file=$f::no syntax check for shebang: $first"; exit 1 ;;
  esac
done < <(find "$root" -path "$root/.git" -prune -o -type f -print0)

count() { tr -cd '\0' < "$1" | wc -c | tr -d ' '; }
shell=$(count scripts.z); python=$(count python.z)
echo "shell:"; tr '\0' '\n' < scripts.z | sed 's/^/  /'
echo "python:"; tr '\0' '\n' < python.z | sed 's/^/  /'
if [ $((shell + python)) != "$shebangs" ]; then
  echo "::error::classified $((shell + python)) of $shebangs files with a shebang"; exit 1
fi
[ "$shell" -gt 0 ] || { echo "::error::no shell scripts found under $root"; exit 1; }
echo "$shebangs files with a shebang: $shell shell, $python python"
