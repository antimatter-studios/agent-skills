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
# Declare the paths in the tree, in the repo's .github-guard file, or per clone
# (see gg_declared_paths; the per-clone config wins where both exist):
#
#   .github-guard                       .git/config (git config --add ...)
#   [paths]                             github-guard.paths.private tmp
#   	private = tmp                     github-guard.paths.private examples
#   	private = examples
#
# With nothing declared the guard no-ops: which directories are private is not
# something it can guess, and guessing would block the wrong commit.
#
# For a genuine, intentional exception: git commit --no-verify.
set -uf
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

staged=$(git diff --cached --name-only --diff-filter=ACM)
[ -n "$staged" ] || exit 0

prefixes=$(gg_declared_paths private); declared=$?
if [ "$declared" = 2 ]; then
  # A .github-guard git cannot read may be the one naming the private paths, and
  # this guard cannot tell. Letting the commit through would read "unreadable"
  # as "nothing is private", which is the one answer a wall must not give. It
  # reads the working-tree file, so fixing the file clears this at once.
  root=$(git rev-parse --show-toplevel)
  echo "github-guard: can't tell which paths are private — $(gg_decl_error "$root/$GG_DECL_FILE")." >&2
  echo "             Fix .github-guard (git config -f .github-guard --list shows the error)," >&2
  echo "             or declare the paths per clone: git config --add github-guard.paths.private <path>" >&2
  exit 1
fi
[ -n "$prefixes" ] || exit 0

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
