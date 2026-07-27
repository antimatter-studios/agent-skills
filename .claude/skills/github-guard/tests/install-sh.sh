#!/usr/bin/env bash
# Tests for install.sh — what it lands in a target repo, and what it leaves alone.
#
#   tests/install-sh.sh [path-to-skill-dir]     (default: the sibling skill root)
#
# install.sh runs against every recorded project on upgrade, so a mistake here is
# multiplied by the number of guarded repos: the exec-bit rule marked
# .githooks/required-checks executable in 21 of them at once, because that rule
# matched extensionless files by name and a git hook has no extension.
set -uo pipefail

skill=${1:-$(cd "$(dirname "$0")/.." && pwd)}
[ -x "$skill/install.sh" ] || { echo "no install.sh in $skill" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0
n=0

# A throwaway repo per case. `pre` runs before install.sh, so a case can set up
# repo-local state the installer must not damage.
setup() {
  n=$((n + 1)); repo="$root/repo$n"
  mkdir -p "$repo"
  git init -q "$repo"
}

ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

is_exec()     { [ -x "$1" ] && ok "$2 is executable" || bad "$2 should be executable"; }
not_exec()    { [ ! -x "$1" ] && ok "$2 is not executable" || bad "$2 should NOT be executable"; }
exists()      { [ -f "$1" ] && ok "$2 exists" || bad "$2 missing"; }
same_mode()   { [ "$(stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1")" = "$2" ] \
                && ok "$3 kept mode $2" || bad "$3 changed mode (want $2, got $(stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"))"; }

printf 'install.sh (%s)\n' "$skill"

# --- 1. a fresh install lands a working hook tree ---------------------------
setup
"$skill/install.sh" "$repo" >/dev/null
exists   "$repo/.githooks/pre-commit"                            "pre-commit dispatcher"
is_exec  "$repo/.githooks/pre-commit"                            "pre-commit dispatcher"
is_exec  "$repo/.githooks/pre-commit.d/github-protect-main.sh"   "a guard"
is_exec  "$repo/.githooks/lib/run-guards.sh"                     "lib/run-guards.sh"
# Sourced, never executed — the source tree records it 644 and the installer
# must not invent an exec bit the payload does not have.
not_exec "$repo/.githooks/lib/common.sh"                         "lib/common.sh"
[ "$(git -C "$repo" config --get core.hooksPath)" = ".githooks" ] \
  && ok "core.hooksPath set" || bad "core.hooksPath not set"

# --- 2. THE REGRESSION: a repo's own data file keeps its mode ----------------
# .githooks/required-checks is repo-local config, not payload, and lives at the
# same depth as the dispatchers with no extension either.
setup
mkdir -p "$repo/.githooks"
printf 'CI\n' > "$repo/.githooks/required-checks"
chmod 644 "$repo/.githooks/required-checks"
"$skill/install.sh" "$repo" >/dev/null
not_exec  "$repo/.githooks/required-checks" "required-checks"
same_mode "$repo/.githooks/required-checks" 644 "required-checks"
[ "$(cat "$repo/.githooks/required-checks")" = CI ] \
  && ok "required-checks content untouched" || bad "required-checks content changed"

# --- 3. a project-local extra guard survives an upgrade ---------------------
setup
"$skill/install.sh" "$repo" >/dev/null
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.githooks/pre-commit.d/zz-project-local.sh"
chmod +x "$repo/.githooks/pre-commit.d/zz-project-local.sh"
"$skill/install.sh" "$repo" >/dev/null
exists  "$repo/.githooks/pre-commit.d/zz-project-local.sh" "project-local guard"
is_exec "$repo/.githooks/pre-commit.d/zz-project-local.sh" "project-local guard"

# --- 4. not a git repo → refuses, and leaves nothing behind ------------------
n=$((n + 1)); plain="$root/plain$n"; mkdir -p "$plain"
if "$skill/install.sh" "$plain" >/dev/null 2>&1; then
  bad "install into a non-repo should fail"
else
  ok "install into a non-repo fails"
fi
[ ! -d "$plain/.githooks" ] && ok "non-repo left clean" || bad "non-repo got a .githooks"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
