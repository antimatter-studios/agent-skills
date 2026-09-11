#!/usr/bin/env bash
# Tests for github-protect-main's required-status-check selection.
#
#   tests/protect-main-required-checks.sh [path-to-githooks-dir]
#
# The guard talks to GitHub and then PUTs a branch-protection payload, so the
# only way to test it is to give it a GitHub: `gh` is stubbed on PATH, answers
# each API call from fixtures set per case, and the PUT payload is captured to a
# file instead of being sent. The assertion is on that payload — the checks the
# guard would actually require.
#
# The guard tree is COPIED into a throwaway repo per case, because the guard
# resolves its own directory from $0 and reads .githooks/required-checks
# relative to it. Passing a different githooks dir runs these same cases against
# another version of the guard, which is how the regression below was first
# shown to fail (git worktree of the previous commit → case 1 requires all three
# checks instead of just the aggregate).
set -uo pipefail

src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
[ -d "$src/pre-commit.d" ] || { echo "not a githooks dir: $src" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0

# ---- the gh stub -------------------------------------------------------------
# Answers by URL. Both `passed` and `head_names` query the same check-runs URL
# and differ only in their --jq, so the stub keys off the success filter.
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  auth) exit 0 ;;
  api) shift ;;
  *) exit 1 ;;
esac
url=""; put=0; jqexpr=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) [ "${2:-}" = PUT ] && put=1; shift 2 ;;
    --jq) jqexpr="${2:-}"; shift 2 ;;
    -H|--input) shift 2 ;;
    --paginate) shift ;;
    repos/*|user|user/*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ "$put" = 1 ]; then cat > "$GH_CAPTURE"; exit "${GH_PUT_RC:-0}"; fi
case "$url" in
  user)                       printf '%s\n' "${GH_LOGIN:-testowner}" ;;
  */actions/runs*)            printf '%s\n' "${GH_SUITE_IDS:-1}" ;;
  */check-suites/*)           printf '%s' "${GH_DISCOVERED:-}" ;;
  */commits/*/check-runs*)
    case "$jqexpr" in
      *'"success"'*)          printf '%s' "${GH_PASSED:-}" ;;
      *)                      printf '%s' "${GH_HEAD:-}" ;;
    esac ;;
  */contents/.github-guard/required-checks*)
    # The declaration is read from the repo's default branch on the SERVER, not
    # the working tree, so the stub is where it lives. Unset = no such file.
    [ -n "${GH_DECLARATION:-}" ] || exit 1
    printf '%s\n' "$GH_DECLARATION" ;;
  */contents/.githooks/required-checks*)
    # The superseded location, still read when the new one is absent.
    [ -n "${GH_DECLARATION_OLD:-}" ] || exit 1
    printf '%s\n' "$GH_DECLARATION_OLD" ;;
  */branches/*/protection)
    [ "${GH_PROTECTED:-1}" = 1 ] || exit 1
    printf '%s\n%s\n%s\n%s\n' "${GH_REVIEWS:-true}" "${GH_ADMINS:-true}" \
      "${GH_CURRENT:-[]}" "${GH_REVIEW_COUNT:-0}" ;;
  */actions/*|repos/*)        printf '%s\n' "${GH_DEFAULT_BRANCH:-main}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$root/bin/gh"
PATH="$root/bin:$PATH"

# ---- harness -----------------------------------------------------------------
# Each case gets a fresh repo + guard copy. `declared` is what the default
# branch's .githooks/required-checks says, or the literal ABSENT for no such
# file; it is served by the gh stub, because that is where the guard reads it
# from. An optional third argument writes a DIFFERENT file into the working
# tree, which the guard must ignore.
run_case() {
  local name="$1" declared="$2" worktree="${3:-}" n dir
  n=$((pass + fail + 1)); dir="$root/case$n"
  mkdir -p "$dir"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" remote add origin git@github.com:testowner/testrepo.git
  mkdir -p "$dir/.githooks"
  cp -R "$src/." "$dir/.githooks/"
  if [ "$declared" = ABSENT ]; then unset GH_DECLARATION; else export GH_DECLARATION="$declared"; fi
  # Set explicitly per case; never inherited from the previous one.
  if [ -n "${OLD_DECLARATION:-}" ]; then export GH_DECLARATION_OLD="$OLD_DECLARATION"; else unset GH_DECLARATION_OLD; fi
  [ -z "$worktree" ] || printf '%s\n' "$worktree" > "$dir/.githooks/required-checks"
  export GH_CAPTURE="$dir/put.json"
  ( cd "$dir" && bash .githooks/pre-commit.d/github-protect-main.sh ) >"$dir/out" 2>"$dir/err"
  CASE_NAME="$name"; CASE_DIR="$dir"
}

# Assert on required_status_checks in the captured PUT: a JSON array of contexts,
# the string "null" when protection would require no checks, or NONE for no PUT.
expect_checks() {
  local want="$1" got
  if [ ! -f "$CASE_DIR/put.json" ]; then
    got=NONE
  else
    got=$(jq -c '.required_status_checks | if . == null then "null" else [.checks[].context] end' \
            "$CASE_DIR/put.json" 2>/dev/null | sed 's/^"null"$/null/')
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$CASE_NAME"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s\n        want %s\n        got  %s\n' "$CASE_NAME" "$want" "$got"
    sed 's/^/        stderr: /' "$CASE_DIR/err"
  fi
}

expect_stderr() {
  if grep -qF "$1" "$CASE_DIR/err"; then
    pass=$((pass + 1)); printf '  ok    %s (stderr)\n' "$CASE_NAME"
  else
    fail=$((fail + 1)); printf '  FAIL  %s: stderr lacks %s\n' "$CASE_NAME" "$1"
    sed 's/^/        stderr: /' "$CASE_DIR/err"
  fi
}

printf 'github-protect-main: required checks (%s)\n' "$src"

# Protection is missing its require-a-PR setting, so the guard always has a reason
# to write and the payload is observable in every case below. Without this the
# guard correctly SKIPS the PUT whenever the checks it wants are already required,
# which hides its choice (case 8 covers that skip deliberately).
export GH_REVIEWS=false

# 1. THE REGRESSION. The repo requires one always-run aggregate job that `needs:`
#    the others. Discovery still sees the individual jobs and they are all green
#    on main, so the additive union re-adds them — and any of them that later
#    stops reporting (a path-filtered workflow never starts) blocks every merge
#    with nothing to point at. A declared gate must win, and must strip.
export GH_DISCOVERED=$'CI\nFormulae\nWorkflows\n'
export GH_PASSED=$'CI\nFormulae\nWorkflows\n'
export GH_HEAD=$'CI\nFormulae\nWorkflows\n'
export GH_CURRENT='[{"context":"CI"},{"context":"Formulae"},{"context":"Workflows"}]'
run_case 'declared aggregate replaces the discovered jobs' 'CI'
expect_checks '["CI"]'

# 2. No declaration → the additive discovery behaviour is untouched: a check that
#    is discovered and green on main is added to what is already required.
export GH_CURRENT='[{"context":"Formulae"}]'
run_case 'no declaration keeps additive discovery' ABSENT
expect_checks '["CI","Formulae","Workflows"]'

# 3. `none` is the explicit way to require nothing (still PR-only + admins).
run_case 'none requires no checks' 'none'
expect_checks 'null'

# 4. A file someone blanked mid-edit must not read as "require nothing" — it
#    behaves exactly like case 2.
run_case 'comments-only file is ignored' '# aggregate goes here'
expect_checks '["CI","Formulae","Workflows"]'
expect_stderr 'lists no checks'

# 5. A typo would otherwise be required immediately, never report, and lock the
#    repo (enforce_admins). Nothing eligible → keep what is required today.
export GH_CURRENT='[{"context":"Formulae"}]'
run_case 'a misspelled check does not strip the gate' 'Cl'
expect_checks '["Formulae"]'
expect_stderr 'no declared check is eligible yet'

# 6. Declared but never green on main, yet already required → honour it (the
#    promotion gate exists to stop NEW never-green checks, not to drop old ones).
export GH_PASSED=$'Formulae\n'
export GH_CURRENT='[{"context":"CI"},{"context":"Formulae"}]'
run_case 'already-required declaration survives a never-green check' 'CI'
expect_checks '["CI"]'

# 7. Declared, green on main, not yet required → promoted.
export GH_PASSED=$'CI\nFormulae\n'
export GH_CURRENT='[{"context":"Formulae"}]'
run_case 'a green declared check is promoted' 'CI'
expect_checks '["CI"]'

# 8. Nothing to change → no PUT at all. The guard runs on every commit, so fully
#    protected + already requiring exactly the declared check must be a no-op.
export GH_REVIEWS=true
export GH_CURRENT='[{"context":"CI"}]'
run_case 'already correct → no write' 'CI'
expect_checks NONE

# 9. A PARTIAL declaration must not weaken the gate. `Nope` is not eligible yet,
#    so the declared set is not yet the whole story — exact-replacing here would
#    DROP `Workflows`, which the full declaration never asked to remove, leaving
#    a weaker gate than before the declaration was written. Union until every
#    declared check is eligible; only then does "declared wins, exactly" apply.
export GH_REVIEWS=false
export GH_PASSED=$'CI\nFormulae\n'
export GH_CURRENT='[{"context":"Workflows"}]'
run_case 'a partial declaration unions rather than stripping' $'CI\nFormulae\nNope'
expect_checks '["CI","Formulae","Workflows"]'
expect_stderr 'not required yet'

# 10. The declaration is a PRIVILEGED input — `none` strips every required check
#     — so it must come from the trusted default branch, never from whatever is
#     checked out. Reviewing a contributor's branch locally and committing while
#     it is checked out must not let that branch unprotect main.
export GH_PASSED=$'CI\nFormulae\n'
export GH_CURRENT='[{"context":"CI"}]'
run_case 'a working-tree declaration cannot unprotect the branch' 'CI' 'none'
expect_checks '["CI"]'

# 11. The declaration outlived the directory it was named for. Hooks live in
#     .git/hooks, so .githooks/ holds no hooks and the file belongs in
#     .github-guard/ — but a repo that has not moved it yet must keep its gate,
#     and be told, rather than silently falling back to discovery.
export GH_PASSED=$'CI\n'
export GH_CURRENT='[]'
OLD_DECLARATION='CI' run_case 'a declaration still in .githooks/ is honoured' ABSENT
expect_checks '["CI"]'
expect_stderr 'move it to .github-guard/required-checks'

# ...and the new location wins when both exist, which is what makes a move
# safe: the old file can be deleted in a second commit, or left, and the answer
# does not change in between.
export GH_PASSED=$'CI\nFormulae\n'
export GH_CURRENT='[]'
OLD_DECLARATION='Formulae' run_case 'the new location wins over the old' 'CI'
expect_checks '["CI"]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
