#!/usr/bin/env bash
# guard: git-block-private-paths
# Refuse to commit anything under a path the repo declared private. BLOCKS.
#
# .gitignore already keeps such material out of a commit — right up until
# someone runs `git add -f`, or a tool does it for them. This is the hard
# backstop for the directories whose contents must not reach the published
# repo: reverse-engineering notes, third-party sample corpora, a vendored
# encoder, a customer's data. Ignoring is a convenience; this is a wall.
#
# Declare the paths per clone or in the tree (see gg_declared_paths):
#
#   git config --add github-guard.private-path tmp
#   git config --add github-guard.private-path examples
#     ...or .githooks/private-paths, one path per line, # for comments
#
# With nothing declared the guard no-ops: which directories are private is not
# something it can guess, and guessing would block the wrong commit.
#
# For a genuine, intentional exception: git commit --no-verify.
set -uf
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

prefixes=$(gg_declared_paths private-path private-paths)
[ -n "$prefixes" ] || exit 0

staged=$(git diff --cached --name-only --diff-filter=ACM)
[ -n "$staged" ] || exit 0

fail=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  while IFS= read -r pre; do
    [ -n "$pre" ] || continue
    pre=${pre%/}
    # Prefix match on whole path components: `tmp` blocks tmp/x and the file
    # tmp itself, and does NOT block tmpl/x — a declaration that swallowed
    # neighbouring directories by spelling would be worse than none.
    case "$path" in
      "$pre" | "$pre"/*)
        echo "github-guard: refusing to commit '$path' — it is under the private '$pre' area," >&2
        echo "             which must not be published." >&2
        echo "             unstage it:   git restore --staged \"$path\"" >&2
        echo "             (if this is genuinely intended: git commit --no-verify)" >&2
        fail=1
        break
        ;;
    esac
  done <<EOF
$prefixes
EOF
done <<EOF
$staged
EOF
exit "$fail"
