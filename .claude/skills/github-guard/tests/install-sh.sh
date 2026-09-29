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

# The permission bits as three octal digits, read from `ls -ld`, which prints
# the same `-rwxr-xr-x` string on every platform. Not stat: GNU and BSD `stat`
# take different flags, and GNU reads `stat -f` as FILE SYSTEM status, succeeds,
# and prints an inode table, so a `||` chain in the wrong order never falls back.
# That reported `want 644, got <fs dump>` on the first Linux run of this suite.
# One command for every platform means no order to get wrong. Any trailing
# ACL/xattr marker (`+`, `@`, `.`) is outside the nine characters read.
file_mode() {
  ls -ld "$1" 2>/dev/null | awk '{
    p = substr($1, 2, 9); out = ""
    for (i = 0; i < 3; i++) {
      d = 0; t = substr(p, i * 3 + 1, 3)
      if (substr(t, 1, 1) == "r") d += 4
      if (substr(t, 2, 1) == "w") d += 2
      x = substr(t, 3, 1); if (x == "x" || x == "s" || x == "t") d += 1
      out = out d
    }
    print out
  }'
}
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

# --- 3. THE REGRESSION: a repo's own data files keep their mode ------------
# A data file beside the old in-tree hooks (the one-file-per-fact declarations
# lived there) must not be marked executable, and the .github-guard file must be
# left exactly as it is — mode, content, or otherwise. The installer never writes
# into the working tree.
setup
mkdir -p "$repo/.githooks"
printf 'CI\n' > "$repo/.githooks/required-checks"
chmod 644 "$repo/.githooks/required-checks"
printf '[checks]\n\trequired = CI\n' > "$repo/.github-guard"
chmod 644 "$repo/.github-guard"
cp "$repo/.github-guard" "$root/decl.before"
"$skill/install.sh" "$repo" >/dev/null 2>"$root/err3"
not_exec  "$repo/.githooks/required-checks" "an old data file"
same_mode "$repo/.githooks/required-checks" 644 "an old data file"
not_exec  "$repo/.github-guard" ".github-guard"
same_mode "$repo/.github-guard" 644 ".github-guard"
cmp -s "$repo/.github-guard" "$root/decl.before" \
  && ok ".github-guard content untouched" || bad ".github-guard content changed"
absent    "$repo/.githooks/pre-commit"      "payload copy in the working tree"
# The guards read only .github-guard now, so a declaration left in the old
# layout is read by nothing — and the upgrade is the one place that says so.
grep -qF '.githooks/required-checks' "$root/err3" \
  && ok "an old-layout declaration is named on upgrade" || bad "old declaration not named: $(cat "$root/err3")"
grep -qF 'no longer read' "$root/err3" \
  && ok "and says it is no longer read" || bad "no 'no longer read' note: $(cat "$root/err3")"

# --- 3b. the per-clone path keys are migrated to their new names, once --------
# github-guard.private-path / generated-path became github-guard.paths.private /
# paths.generated, mirroring the file. Nothing at runtime reads the old names, so
# the upgrade moves them, says so, and does not duplicate a value already there.
setup
git -C "$repo" config --add github-guard.private-path tmp
git -C "$repo" config --add github-guard.private-path examples
git -C "$repo" config --add github-guard.paths.private tmp
git -C "$repo" config --add github-guard.generated-path frontend/bindings
"$skill/install.sh" "$repo" >/dev/null 2>"$root/err3b"
got=$(git -C "$repo" config --get-all github-guard.paths.private | tr '\n' ' ')
[ "$got" = "tmp examples " ] && ok "private-path values moved to paths.private, without duplicates" \
                             || bad "paths.private is '$got'"
got=$(git -C "$repo" config --get-all github-guard.paths.generated)
[ "$got" = "frontend/bindings" ] && ok "generated-path moved to paths.generated" || bad "paths.generated is '$got'"
[ -z "$(git -C "$repo" config --get-all github-guard.private-path)$(git -C "$repo" config --get-all github-guard.generated-path)" ] \
  && ok "the old keys are gone" || bad "an old key survived the migration"
grep -qF 'migrated git config github-guard.private-path -> github-guard.paths.private' "$root/err3b" \
  && ok "the migration is announced" || bad "silent migration: $(cat "$root/err3b")"
"$skill/install.sh" "$repo" >/dev/null 2>"$root/err3c"
grep -qF 'migrated' "$root/err3c" && bad "a second install migrated again" || ok "a second install has nothing to migrate"

# --- 3c. a tracked guard that differs from the payload is NAMED, not skipped --
# A path match is not ownership. Twelve repos once tracked a rust-deps-pinned.sh
# far ahead of the payload's; the installer called each "ours" because the path
# matched, installed the payload's copy into .git/hooks, and said nothing — the
# tracked file stayed in the tree looking intact while the check stopped
# running. A byte-identical tracked copy really is ours and stays quiet; that
# is the control that shows the note is about the difference, not the path.
setup
mkdir -p "$repo/.githooks/pre-commit.d"
cp "$skill/githooks/pre-commit.d/rust-deps-pinned.sh" "$repo/.githooks/pre-commit.d/rust-deps-pinned.sh"
printf '# a check only this copy has\n' >> "$repo/.githooks/pre-commit.d/rust-deps-pinned.sh"
cp "$skill/githooks/pre-commit.d/rust-fmt.sh" "$repo/.githooks/pre-commit.d/rust-fmt.sh"
chmod +x "$repo/.githooks/pre-commit.d/"*.sh
cp "$repo/.githooks/pre-commit.d/rust-deps-pinned.sh" "$root/tracked3c.before"
"$skill/install.sh" "$repo" >/dev/null 2>"$root/err3c2"
grep -qF '.githooks/pre-commit.d/rust-deps-pinned.sh' "$root/err3c2" \
  && ok "a tracked guard that differs from the payload is named" \
  || bad "a differing tracked guard was superseded in silence: $(cat "$root/err3c2")"
grep -qF 'superseded' "$root/err3c2" \
  && ok "and the note says the installed payload supersedes it" \
  || bad "the note does not say it is superseded: $(cat "$root/err3c2")"
grep -qF '.githooks/pre-commit.d/rust-fmt.sh' "$root/err3c2" \
  && bad "a byte-identical tracked guard was reported" \
  || ok "control: a byte-identical tracked guard is not reported"
cmp -s "$repo/.githooks/pre-commit.d/rust-deps-pinned.sh" "$root/tracked3c.before" \
  && ok "the tracked copy is left as it was" || bad "the installer rewrote the tracked copy"
cmp -s "$hooks/pre-commit.d/rust-deps-pinned.sh" "$skill/githooks/pre-commit.d/rust-deps-pinned.sh" \
  && ok "the installed guard is the payload's, never the tracked one" \
  || bad "the installer adopted the tracked copy from the working tree"

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

# --- 4b. a guard RETIRED from the payload is pruned; nothing else is ---------
# cp -R is an overlay: a guard removed from the payload stayed in .git/hooks and
# kept running on every repo the upgrade reached. The installer now removes what
# IT placed and the payload no longer has — and only that, so a project-local
# guard dropped into .git/hooks survives. A copy of the skill stands in for the
# next release, with one guard retired.
setup
cp -R "$skill" "$root/skill-next$n"
"$root/skill-next$n/install.sh" "$repo" >/dev/null 2>&1
printf '#!/usr/bin/env bash\nexit 0\n' > "$hooks/pre-commit.d/zz-project-local.sh"
chmod +x "$hooks/pre-commit.d/zz-project-local.sh"
exists "$hooks/pre-commit.d/git-no-trailing-whitespace.sh" "control: the guard about to be retired, before the upgrade"
rm "$root/skill-next$n/githooks/pre-commit.d/git-no-trailing-whitespace.sh"
"$root/skill-next$n/install.sh" "$repo" >/dev/null 2>"$root/err4b"
absent "$hooks/pre-commit.d/git-no-trailing-whitespace.sh" "a guard retired from the payload"
grep -qF 'pre-commit.d/git-no-trailing-whitespace.sh' "$root/err4b" \
  && ok "the prune is announced" || bad "the prune was silent: $(cat "$root/err4b")"
exists "$hooks/pre-commit.d/zz-project-local.sh" "a project-local guard after a pruning upgrade"
exists "$hooks/pre-commit.d/github-protect-main.sh" "a guard still in the payload after a pruning upgrade"

# --- 4c. a destination SYMLINK is replaced, never written through ------------
# cp onto an existing symlink follows it: the payload and the chmod +x landed on
# whatever the link pointed at — a personal or tool-managed hook, rewritten.
setup
printf '#!/bin/sh\n# my own hook\n' > "$root/personal-hook$n"
chmod 644 "$root/personal-hook$n"
cp "$root/personal-hook$n" "$root/personal-hook$n.before"
mkdir -p "$hooks"
ln -s "$root/personal-hook$n" "$hooks/pre-commit"
"$skill/install.sh" "$repo" >/dev/null 2>&1
cmp -s "$root/personal-hook$n" "$root/personal-hook$n.before" \
  && ok "the symlink's target is left untouched" || bad "the install wrote through the symlink into its target"
same_mode "$root/personal-hook$n" 644 "the symlink's target"
[ ! -L "$hooks/pre-commit" ] && ok "the symlink is replaced by the payload's file" \
                             || bad "pre-commit is still a symlink"
is_exec "$hooks/pre-commit" "pre-commit dispatcher that replaced a symlink"

# --- 4d. a core.hooksPath the installer cannot clear is traced to its file ----
# The refusal used to guess 'global or system'. git knows where the value lives,
# so the message names that file. GIT_CONFIG_GLOBAL keeps the suite off the
# machine's own config.
setup
printf '[core]\n\thooksPath = /elsewhere\n' > "$root/global-config$n"
if GIT_CONFIG_GLOBAL="$root/global-config$n" "$skill/install.sh" "$repo" >/dev/null 2>"$root/err4d"; then
  bad "an install with a global core.hooksPath should refuse"
else
  ok "an install with a global core.hooksPath refuses"
fi
grep -qF "$root/global-config$n" "$root/err4d" \
  && ok "the refusal names the config file the value comes from" \
  || bad "the refusal does not say where the value lives: $(cat "$root/err4d")"

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
