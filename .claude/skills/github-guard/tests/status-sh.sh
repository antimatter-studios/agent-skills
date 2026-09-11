#!/usr/bin/env bash
# Tests for status.sh — the four answers it has to keep apart.
#
#   tests/status-sh.sh [path-to-skill-dir]     (default: the sibling skill root)
#
# The guards live in .git/hooks, one copy per clone, so a copy that drifted is
# invisible to git and the only way to see it is to go and compare. What makes
# this script worth testing is not the comparing, it is the classification: a
# file that matches an OLDER release is a file to overwrite, and a file matching
# NO release is one somebody improved in place. Report the second as the first
# and a sweep quietly deletes work — which is how the sibling-lock check came to
# be missing from the skill for weeks.
#
# So every case below pins one classification AND denies the others: "older"
# asserts the word older appears and the word local does not.
set -uo pipefail

skill=${1:-$(cd "$(dirname "$0")/.." && pwd)}
[ -x "$skill/status.sh" ] || { echo "no status.sh in $skill" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0; n=0

ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

says()     { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 (output: ${2//$'\n'/ | })" ;; esac; }
says_not() { case "$2" in *"$1"*) bad "$4 (output: ${2//$'\n'/ | })" ;; *) ok "$4" ;; esac; }

# A payload with a HISTORY: two releases of one guard, so "older" has something
# to point at. status.sh reads the payload beside itself, so the copy under test
# is the one in this fixture, not the skill's own.
src="$root/source"
pay="$src/skills/github-guard"
mkdir -p "$pay/githooks/pre-commit.d" "$pay/githooks/lib"
cp "$skill/status.sh" "$pay/status.sh"
printf '#!/usr/bin/env bash\nexit 0\n'   > "$pay/githooks/pre-commit"
printf '# sourced, never executed\n'     > "$pay/githooks/lib/common.sh"
printf '#!/usr/bin/env bash\n# v1\n'     > "$pay/githooks/pre-commit.d/g.sh"
chmod +x "$pay/status.sh" "$pay/githooks/pre-commit" "$pay/githooks/pre-commit.d/g.sh"
git init -q "$src"
git -C "$src" config user.email github-guard-tests@example.invalid
git -C "$src" config user.name 'github-guard tests'
git -C "$src" config commit.gpgsign false
git -C "$src" add -A && git -C "$src" commit -q -m v1
v1=$(git -C "$src" rev-parse --short HEAD)
printf '#!/usr/bin/env bash\n# v2\n'     > "$pay/githooks/pre-commit.d/g.sh"
chmod +x "$pay/githooks/pre-commit.d/g.sh"
git -C "$src" add -A && git -C "$src" commit -q -m v2

# Fixture paths are scrubbed out of the captured output before anything is
# asserted on it. macOS puts temporary directories under /var/FOLDERS, which
# contains the substring "older", so a report with no classification in it at
# all matched an assertion looking for one.
# The status is part of what is asserted (a sweep gates on it), so the wrapper
# carries the real one back out instead of printf's.
status() {
  local rc=0 o
  o=$("$pay/status.sh" "$@" 2>&1) || rc=$?
  printf '%s' "${o//$root/FIXTURE}"
  return "$rc"
}

# A target repo holding the CURRENT payload, which each case then perturbs.
target() {
  n=$((n + 1)); repo="$root/repo$n"; hooks="$repo/.git/hooks"
  git init -q "$repo"
  git -C "$repo" config user.email github-guard-tests@example.invalid
  git -C "$repo" config user.name 'github-guard tests'
  git -C "$repo" config commit.gpgsign false
  mkdir -p "$hooks"
  cp -R "$pay/githooks/." "$hooks/"
  chmod +x "$hooks/pre-commit" "$hooks/pre-commit.d/g.sh"
}

printf 'status.sh (%s)\n' "$skill"

# --- 1. an untouched install is current, and says so with exit 0 ------------
target
out=$(status "$repo"); rc=$?
says    current "$out" "an untouched install reads as current"
[ "$rc" = 0 ] && ok "exit 0 when every repo is current" || bad "exit $rc, want 0 when current"

# --- 2. the bytes of an earlier release are dated, not called local --------
target
git -C "$src" show "$v1:skills/github-guard/githooks/pre-commit.d/g.sh" > "$hooks/pre-commit.d/g.sh"
out=$(status -v "$repo"); rc=$?
says    "1 older"  "$out" "an earlier release counts as older"
says    "$v1"      "$out" "the earlier release is named by its commit"
says_not local     "$out" x "an earlier release is NOT called local"
[ "$rc" = 1 ] && ok "exit 1 when a repo is behind" || bad "exit $rc, want 1 when behind"

# --- 3. bytes no release ever had are local, and are never called older ----
# This is the case the whole script exists for: overwrite these and the work is
# gone, so the word "older" must not appear anywhere in the report.
target
printf '#!/usr/bin/env bash\n# a check written here and never upstreamed\n' > "$hooks/pre-commit.d/g.sh"
out=$(status -v "$repo")
says    "1 local"  "$out" "bytes absent from history count as local"
says    customised "$out" "a repo with local work reads as customised"
says_not older     "$out" x "local work is NOT called older"

# --- 4. a file the payload ships and the repo lacks is missing -------------
target
rm -f "$hooks/pre-commit.d/g.sh"
out=$(status -v "$repo")
says "1 missing" "$out" "a guard the install never got counts as missing"

# --- 5. present, identical, and not executable is still a guard that never runs
target
chmod -x "$hooks/pre-commit.d/g.sh"
out=$(status -v "$repo")
says "not-executable" "$out" "identical bytes without the exec bit are reported"
# The file the payload itself ships 644 must not be flagged for the same reason.
says_not "common.sh" "$out" x "a sourced file is not expected to be executable"

# --- 6. core.hooksPath outranks every file: correct hooks, none of them run --
target
git -C "$repo" config core.hooksPath .githooks
out=$(status "$repo")
says "core.hooksPath" "$out" "an overriding core.hooksPath is reported"
says inert            "$out" "matching files under an override read as inert"

# --- 7. executables left in the tracked .githooks/ are named, data is not ---
target
mkdir -p "$repo/.githooks/pre-commit.d"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.githooks/pre-commit.d/repo-own.sh"
chmod +x "$repo/.githooks/pre-commit.d/repo-own.sh"
printf 'Build & Test\n' > "$repo/.githooks/required-checks"
out=$(status "$repo")
says     "pre-commit.d/repo-own.sh no longer runs" "$out" "a repo's own in-tree guard is named"
says     stranded "$out" "a repo with stranded in-tree guards reads as stranded"
# Not `inert`: the installed hooks here run perfectly well. Sharing one word
# with the core.hooksPath case sent a clean-up sweep at repos whose git config
# was the fault and vice versa.
says_not inert    "$out" x "stranded guards are NOT reported as an override"
says_not required-checks "$out" x "in-tree DATA is not mistaken for a stranded guard"

# --- 8. a TRACKED copy of the payload under .githooks/ is its own finding ----
# It does not run, so nothing looks wrong; it reads as the live guards to
# anyone who opens the repo, it is what a branch can rewrite, and it drifts.
target
mkdir -p "$repo/.githooks/pre-commit.d"
cp "$pay/githooks/pre-commit" "$repo/.githooks/pre-commit"
cp "$pay/githooks/pre-commit.d/g.sh" "$repo/.githooks/pre-commit.d/g.sh"
printf 'CI\n' > "$repo/.githooks/required-checks"
git -C "$repo" add -A .githooks
out=$(status -v "$repo")
says "2 tracked copies" "$out" "tracked copies of the payload are counted"
says in-tree            "$out" "a repo still carrying them reads as in-tree"
says_not required-checks "$out" x "the repo's own data is not counted as a copy"

target
mkdir -p "$repo/.githooks"
cp "$pay/githooks/pre-commit" "$repo/.githooks/pre-commit"
git -C "$repo" add -A .githooks
out=$(status "$repo")
says "1 tracked copy in" "$out" "one copy is reported in the singular"

# A declaration directory is not a hook directory: an executable dropped in
# .github-guard/ never runs either, and nothing else would say so.
target
mkdir -p "$repo/.github-guard"
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.github-guard/repo-own.sh"
chmod +x "$repo/.github-guard/repo-own.sh"
printf 'tmp\n' > "$repo/.github-guard/private-paths"
out=$(status "$repo")
says     ".github-guard/repo-own.sh no longer runs" "$out" "an executable in the declaration directory is named"
says_not private-paths "$out" x "and the declarations beside it are not"

# Untracked is not the same finding: one rm away, and it ships to nobody.
target
mkdir -p "$repo/.githooks"
cp "$pay/githooks/pre-commit" "$repo/.githooks/pre-commit"
out=$(status "$repo")
says_not in-tree "$out" x "an untracked leftover is not reported as a tracked copy"

# --- 9. an override outranks everything else that could be said about a repo --
target
mkdir -p "$repo/.githooks/pre-commit.d"
printf '#!/usr/bin/env bash
exit 0
' > "$repo/.githooks/pre-commit.d/repo-own.sh"
chmod +x "$repo/.githooks/pre-commit.d/repo-own.sh"
printf '#!/usr/bin/env bash
# local
' > "$hooks/pre-commit.d/g.sh"
git -C "$repo" config core.hooksPath .githooks
out=$(status "$repo")
says     inert "$out" "an override outranks drift and stranded guards"
says_not customised "$out" x "an override is not reported as the drift underneath it"

# --- 10. without history nothing can be dated, and the report admits it ------
# An installed skill (copied to ~/.claude/skills) has no history of its own. The
# failure to avoid is a confident "local" on 40 repos that are merely behind.
nohist="$root/nohistory/github-guard"
mkdir -p "$nohist"
cp -R "$pay/status.sh" "$pay/githooks" "$nohist/"
target
git -C "$src" show "$v1:skills/github-guard/githooks/pre-commit.d/g.sh" > "$hooks/pre-commit.d/g.sh"
out=$("$nohist/status.sh" -v "$repo" 2>&1); out=${out//$root/FIXTURE}
says "no payload history" "$out" "a payload without history says so"
says "1 local"            "$out" "undatable bytes fall back to local"
# ...and the same payload, pointed at the checkout, dates the same file.
out=$("$nohist/status.sh" -v --source "$src" "$repo" 2>&1); out=${out//$root/FIXTURE}
says "1 older" "$out" "--source restores dating for an installed copy"
says "$v1"     "$out" "--source names the commit the bytes came from"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
