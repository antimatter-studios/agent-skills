#!/usr/bin/env bash
# Tests for git-block-merge-commits' choice of commit range.
#
#   tests/block-merge-commits-range.sh [path-to-githooks-dir]
#
# The guard reads git's pre-push ref list on stdin — one line of
# "<local_ref> <local_sha> <remote_ref> <remote_sha>" per ref — and must
# block only when the push INTRODUCES a merge commit.
#
# The interesting case is a force-push after a rebase. There the old
# remote tip is no longer an ancestor of the new head, so a naive
# "<remote_sha>..<local_sha>" range means "everything reachable from the
# new head but not from the old tip" — which sweeps in the whole new
# base, including merge commits that were already on the remote. The
# guard then blocks a push that introduces no merges at all.
#
# Each case builds a throwaway repo with a real bare remote, because the
# guard consults remote-tracking refs and there is no way to fake those
# convincingly.
set -uo pipefail

src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
guard="$src/pre-push.d/git-block-merge-commits.sh"
[ -f "$guard" ] || { echo "no such guard: $guard" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0

# Build a repo whose main contains a merge commit, with a bare remote
# holding the same history. Echoes the repo path.
build_repo() {
    local dir="$1"
    mkdir -p "$dir/work" "$dir/remote.git"
    git init -q --bare "$dir/remote.git"
    (
        cd "$dir/work"
        git init -q -b main
        git config user.email t@example.com
        git config user.name Test
        git commit -q --allow-empty -m "base"

        # A side branch merged into main with a real merge commit, so
        # main's history contains one.
        git checkout -q -b side
        git commit -q --allow-empty -m "side work"
        git checkout -q main
        git merge -q --no-ff side -m "merge side into main"
        git branch -q -D side

        git remote add origin "$dir/remote.git"
        git push -q origin main
        git fetch -q origin
    )
}

run_guard() {
    # stdin: the pre-push ref line. Echoes status and captured stderr.
    local dir="$1" line="$2"
    ( cd "$dir/work" && printf '%s\n' "$line" | bash "$guard" 2>&1 )
}

check() {
    local name="$1" expected="$2" actual="$3" detail="${4:-}"
    if [ "$expected" = "$actual" ]; then
        printf '  ok   %s\n' "$name"; pass=$((pass + 1))
    else
        printf '  FAIL %s — expected %s, got %s\n' "$name" "$expected" "$actual"
        [ -n "$detail" ] && printf '%s\n' "$detail" | sed 's/^/       /'
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------
# Case 1 — the regression. A rebased branch force-pushed over its old
# tip introduces no merge commit, so it must NOT be blocked, even though
# its new base (main) contains one.
# ---------------------------------------------------------------------
d="$root/case1"; build_repo "$d"
(
    cd "$d/work"
    git checkout -q -b feature main~1     # branch from BEFORE the merge
    git commit -q --allow-empty -m "feature work"
    git push -q origin feature
    git fetch -q origin
    old_tip=$(git rev-parse feature)
    git rebase -q main                     # now based on top of the merge
    new_tip=$(git rev-parse feature)
    printf '%s %s\n' "$old_tip" "$new_tip" > "$d/shas"
)
read -r old_tip new_tip < "$d/shas"
out=$(run_guard "$d" "refs/heads/feature $new_tip refs/heads/feature $old_tip")
rc=$?
check "rebased branch is not blocked" 0 "$rc" "$out"

# ---------------------------------------------------------------------
# Case 2 — the guard must still do its job. A branch that genuinely
# contains its own merge commit has to be blocked.
# ---------------------------------------------------------------------
d="$root/case2"; build_repo "$d"
(
    cd "$d/work"
    git checkout -q -b feature main
    git commit -q --allow-empty -m "feature work"
    git push -q origin feature
    git fetch -q origin
    old_tip=$(git rev-parse feature)
    git checkout -q -b topic
    git commit -q --allow-empty -m "topic work"
    git checkout -q feature
    git merge -q --no-ff topic -m "merge topic into feature"
    new_tip=$(git rev-parse feature)
    printf '%s %s\n' "$old_tip" "$new_tip" > "$d/shas"
)
read -r old_tip new_tip < "$d/shas"
out=$(run_guard "$d" "refs/heads/feature $new_tip refs/heads/feature $old_tip")
rc=$?
check "branch with its own merge IS blocked" 1 "$rc" "$out"

# ---------------------------------------------------------------------
# Case 3 — a brand-new branch off a main that contains a merge must not
# be blocked for main's history.
# ---------------------------------------------------------------------
d="$root/case3"; build_repo "$d"
(
    cd "$d/work"
    git checkout -q -b fresh main
    git commit -q --allow-empty -m "fresh work"
    git rev-parse fresh > "$d/sha"
)
new_tip=$(cat "$d/sha")
zero=0000000000000000000000000000000000000000
out=$(run_guard "$d" "refs/heads/fresh $new_tip refs/heads/fresh $zero")
rc=$?
check "new branch off a merged main is not blocked" 0 "$rc" "$out"

# ---------------------------------------------------------------------
# Case 4 — deleting a remote branch has nothing to inspect.
# ---------------------------------------------------------------------
d="$root/case4"; build_repo "$d"
zero=0000000000000000000000000000000000000000
out=$(run_guard "$d" "(delete) $zero refs/heads/gone $(cd "$d/work" && git rev-parse main)")
rc=$?
check "branch deletion is not blocked" 0 "$rc" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
