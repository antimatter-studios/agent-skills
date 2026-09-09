#!/usr/bin/env bash
# Tests for install.sh — what it lands in a target repo, and what it leaves alone.
#
#   tests/install-sh.sh [path-to-skill-dir]     (default: the sibling skill root)
#
# install.sh runs against every recorded project on upgrade, so a mistake here is
# multiplied by the number of guarded repos: the exec-bit rule marked
# .githooks/required-checks executable in 21 of them at once, because that rule
# matched extensionless files by name and a git hook has no extension.
#
# The load-bearing case is the last one. The guards used to be installed into the
# working tree with core.hooksPath, which means a branch could REPLACE the hook
# git was about to run; case 6 checks out a branch carrying a hostile hook and
# proves it does not execute. It only proves that because it first proves the
# attack fires at all under the old arrangement — an absent marker from a hook
# nobody ran would say nothing.
set -uo pipefail

skill=${1:-$(cd "$(dirname "$0")/.." && pwd)}
[ -x "$skill/install.sh" ] || { echo "no install.sh in $skill" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0
n=0

# A throwaway repo per case. Identity and signing are set locally so the suite
# does not depend on (or disturb) the machine's global git config.
setup() {
  n=$((n + 1)); repo="$root/repo$n"; hooks="$repo/.git/hooks"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email github-guard-tests@example.invalid
  git -C "$repo" config user.name  'github-guard tests'
  git -C "$repo" config commit.gpgsign false
}

ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

is_exec()     { [ -x "$1" ] && ok "$2 is executable" || bad "$2 should be executable"; }
not_exec()    { [ ! -x "$1" ] && ok "$2 is not executable" || bad "$2 should NOT be executable"; }
exists()      { [ -f "$1" ] && ok "$2 exists" || bad "$2 missing"; }
absent()      { [ ! -e "$1" ] && ok "$2 absent" || bad "$2 should not exist"; }

# The end state that matters, asserted rather than assumed: core.hooksPath
# overrides .git/hooks, so hooks-installed-but-config-still-set is an install
# that looks applied and never runs.
hooks_path_unset() {
  got=$(git -C "$1" config --get core.hooksPath 2>/dev/null)
  [ -z "$got" ] && ok "core.hooksPath unset ($2)" \
                || bad "core.hooksPath should be unset ($2), got '$got'"
}

# GNU stat first, then BSD — NOT the other way round: on GNU, `stat -f` means
# "file system status", so it SUCCEEDS and prints an inode table instead of a
# mode, and a `||` fallback never fires. That reported `want 644, got <fs dump>`
# on the first Linux run of this suite.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
same_mode()   { got=$(file_mode "$1"); [ "$got" = "$2" ] \
                && ok "$3 kept mode $2" || bad "$3 changed mode (want $2, got $got)"; }

printf 'install.sh (%s)\n' "$skill"

# --- 1. a fresh install lands a working hook tree, OUTSIDE the working tree ---
setup
"$skill/install.sh" "$repo" >/dev/null
exists   "$hooks/pre-commit"                            "pre-commit dispatcher"
is_exec  "$hooks/pre-commit"                            "pre-commit dispatcher"
is_exec  "$hooks/pre-commit.d/github-protect-main.sh"   "a guard"
is_exec  "$hooks/lib/run-guards.sh"                     "lib/run-guards.sh"
# Sourced, never executed — the source tree records it 644 and the installer
# must not invent an exec bit the payload does not have.
not_exec "$hooks/lib/common.sh"                         "lib/common.sh"
hooks_path_unset "$repo" "fresh install"
# Nothing is written into the working tree: a file a branch can rewrite is a
# file a branch can use to replace the hook that runs next.
absent   "$repo/.githooks"                              "in-tree .githooks/"

# --- 2. an older install's core.hooksPath is CLEARED ------------------------
# Every guarded repo currently carries core.hooksPath=.githooks. Leaving it set
# makes the new install inert while every surface check says it worked.
setup
git -C "$repo" config core.hooksPath .githooks
"$skill/install.sh" "$repo" >/dev/null
hooks_path_unset "$repo" "upgrade from an in-tree install"
is_exec "$hooks/pre-commit" "pre-commit dispatcher after upgrade"

# --- 3. THE REGRESSION: a repo's own data file keeps its mode ----------------
# .githooks/required-checks is repo-local config the guards read FROM THE SERVER,
# so the directory stays in the tree even though the hooks no longer live there.
# The installer must not touch it — mode, content, or otherwise.
setup
mkdir -p "$repo/.githooks"
printf 'CI\n' > "$repo/.githooks/required-checks"
chmod 644 "$repo/.githooks/required-checks"
"$skill/install.sh" "$repo" >/dev/null
not_exec  "$repo/.githooks/required-checks" "required-checks"
same_mode "$repo/.githooks/required-checks" 644 "required-checks"
[ "$(cat "$repo/.githooks/required-checks")" = CI ] \
  && ok "required-checks content untouched" || bad "required-checks content changed"
absent    "$repo/.githooks/pre-commit"      "payload copy in the working tree"

# --- 4. a project-local extra guard survives an upgrade ---------------------
setup
"$skill/install.sh" "$repo" >/dev/null
mkdir -p "$hooks/pre-commit.d"   # so a failing installer reports a FAIL, not a shell error
printf '#!/usr/bin/env bash\nexit 0\n' > "$hooks/pre-commit.d/zz-project-local.sh"
chmod +x "$hooks/pre-commit.d/zz-project-local.sh"
"$skill/install.sh" "$repo" >/dev/null
exists  "$hooks/pre-commit.d/zz-project-local.sh" "project-local guard"
is_exec "$hooks/pre-commit.d/zz-project-local.sh" "project-local guard"
is_exec "$hooks/pre-commit.d/github-protect-main.sh" "payload guard after upgrade"

# --- 5. not a git repo → refuses, and leaves nothing behind ------------------
n=$((n + 1)); plain="$root/plain$n"; mkdir -p "$plain"
if "$skill/install.sh" "$plain" >/dev/null 2>&1; then
  bad "install into a non-repo should fail"
else
  ok "install into a non-repo fails"
fi
[ ! -d "$plain/.githooks" ] && ok "non-repo left clean" || bad "non-repo got a .githooks"

# --- 6. THE NEGATIVE CONTROL: a branch cannot replace the hook that runs -----
# Checking out an untrusted branch (a fork's PR, someone else's push) rewrites
# the working tree, and git resolves the hook AFTER that. With the hooks inside
# the tree, the branch supplies the code that then runs with the reviewer's
# credentials. The hostile hook here only touches a temp file.
setup
marker="$root/pwned$n"
probe="$root/probe$n"
printf 'x\n' > "$repo/file"
git -C "$repo" add file
git -C "$repo" commit -q --no-verify -m base
base_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)

git -C "$repo" checkout -q -b hostile
mkdir -p "$repo/.githooks"
cat > "$repo/.githooks/pre-commit" <<EOF
#!/usr/bin/env bash
printf 'pwned\n' > "$marker"
exit 0
EOF
chmod +x "$repo/.githooks/pre-commit"
git -C "$repo" add .githooks/pre-commit
git -C "$repo" commit -q --no-verify -m hostile
git -C "$repo" checkout -q "$base_branch"

# 6a. The control fires. Without this, case 6b's silence proves nothing — a hook
# that never runs also writes no marker.
git -C "$repo" config core.hooksPath .githooks
git -C "$repo" checkout -qf hostile
rm -f "$marker"
git -C "$repo" commit -q --allow-empty -m attack1
[ -f "$marker" ] && ok "control: an in-tree hook from the checked-out branch DOES run" \
                 || bad "control did not fire — the rest of this case proves nothing"

# 6b. Install, then take the hostile branch again. A probe guard in the real
# hooks directory shows hooks ran at all, so an absent marker means the branch's
# hook was ignored, not that hooks were skipped.
git -C "$repo" checkout -qf "$base_branch"
"$skill/install.sh" "$repo" >/dev/null 2>&1
mkdir -p "$hooks/pre-commit.d"
printf '#!/usr/bin/env bash\nprintf ran > "%s"\nexit 0\n' "$probe" > "$hooks/pre-commit.d/zz-probe.sh"
chmod +x "$hooks/pre-commit.d/zz-probe.sh"
rm -f "$marker" "$probe"
git -C "$repo" checkout -qf hostile
git -C "$repo" commit -q --allow-empty -m attack2
[ -f "$probe" ]   && ok "installed hooks still run after the checkout" \
                  || bad "installed hooks did not run — the marker check below is vacuous"
[ ! -f "$marker" ] && ok "the branch's .githooks/pre-commit did NOT run" \
                   || bad "the branch's .githooks/pre-commit RAN — hooks are still rewritable by a checkout"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
