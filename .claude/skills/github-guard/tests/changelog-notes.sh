#!/usr/bin/env bash
# Tests for `git-changelog.sh notes <tag>` — the guard's extraction used as a
# release tool by the changelog-notes action.
#
#   tests/changelog-notes.sh [githooks-dir]   (default: the sibling githooks/)
#
# The guard blocks a version tag whose changelog section is missing; this
# subcommand writes the release body from that same section. Both halves of
# that deal have to hold: the body must be the section (so a release cannot say
# something the changelog does not), and a missing section must fail LOUDLY
# rather than publish an empty release — a release with no notes is the kind of
# mistake nobody notices until someone reads the tag weeks later.
set -uo pipefail

G=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
notes="$G/pre-push.d/git-changelog.sh"
[ -x "$notes" ] || { echo "no git-changelog.sh under $G" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0

ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
says()     { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 (output: ${2//$'\n'/ | })" ;; esac; }
says_not() { case "$2" in *"$1"*) bad "$4 (output: ${2//$'\n'/ | })" ;; *) ok "$4" ;; esac; }

repo="$root/repo"
git init -q "$repo"
git -C "$repo" config user.email github-guard-tests@example.invalid
git -C "$repo" config user.name 'github-guard tests'
# An origin, because the compare link is built from the slug and its absence is
# a different (also supported) shape.
git -C "$repo" remote add origin git@github.com:an-org/a-repo.git
cat > "$repo/CHANGELOG.md" <<'CL'
# Changelog

## v1.2.0

The newest thing, described.

- a bullet

## v1.1.0

The older thing, which must not appear in the newer release.
CL

run() { ( cd "$repo" && "$notes" notes "$1" 2>&1 ); }

printf 'git-changelog notes (%s)\n' "$G"

out=$(run v1.2.0); rc=$?
[ "$rc" = 0 ] && ok "a documented version extracts cleanly" || bad "exit $rc for a documented version"
says "The newest thing, described." "$out" "the body is the changelog section"
says "a bullet"                     "$out" "including its list items"
says_not "The older thing"          "$out" x "the previous version's section is not included"
says_not "## v1.2.0"                "$out" x "the version heading itself is not repeated in the body"
says "What's Changed"               "$out" "a release-notes heading is added"

# The compare link is what makes a release navigable, and it has to name the
# PREVIOUS documented version — not the tag itself, and not the repo's default
# branch.
says "compare/v1.1.0...v1.2.0"      "$out" "the compare link spans the previous version"
says "an-org/a-repo"                "$out" "and names the repo from its origin"

out=$(run 1.2.0)
says "The newest thing, described." "$out" "the leading v is optional"

# The oldest version has nothing to compare against, and inventing a link there
# would produce a 404 in the release body.
out=$(run v1.1.0)
says    "The older thing"  "$out" "the first version still extracts"
says_not compare/          "$out" x "and gets no compare link, having nothing to compare to"

out=$(run v9.9.9); rc=$?
[ "$rc" != 0 ] && ok "an undocumented version fails" || bad "an undocumented version exited 0 — a release would publish empty notes"
says "no '## v9.9.9' section" "$out" "and says which section is missing"

# KEEP A CHANGELOG headings: `## [1.2.0] - date`, an `## [Unreleased]`
# section above the releases, and link definitions at the end of the file.
# The guard's tag check already accepts these headings; the release body must
# come from them too, or a repository in that style has a guard that passes
# its tags and an action that cannot write their notes.
kac="$root/kac"
git init -q "$kac"
git -C "$kac" remote add origin git@github.com:an-org/kac-repo.git
cat > "$kac/CHANGELOG.md" <<'CL'
# Changelog

## [Unreleased]

Not released yet, and never in a release body.

## [0.2.10] — 2026-10-06

Ten, which 0.2.1 must not be mistaken for.

## [0.2.1] - 2026-10-01

### Fixed

- the bracketed section's own text

## 0.2.0

The bare form.

[Unreleased]: https://github.com/an-org/kac-repo/compare/v0.2.10...HEAD
[0.2.10]: https://github.com/an-org/kac-repo/compare/v0.2.1...v0.2.10
[0.2.1]: https://github.com/an-org/kac-repo/compare/v0.2.0...v0.2.1
CL
runk() { ( cd "$kac" && "$notes" notes "$1" 2>&1 ); }

out=$(runk v0.2.1); rc=$?
[ "$rc" = 0 ] && ok "a bracketed [X.Y.Z] heading extracts" || bad "exit $rc for a bracketed heading: ${out//$'\n'/ | }"
says "the bracketed section's own text" "$out" "its body is that section"
says_not "Ten, which"                   "$out" x "0.2.10 is not mistaken for 0.2.1"
says_not "Not released yet"             "$out" x "the [Unreleased] section is not included"
says "compare/v0.2.0...v0.2.1"          "$out" "the previous version is found under a bare heading"

out=$(runk v0.2.10)
says "Ten, which"                       "$out" "0.2.10 extracts on its own"
says "compare/v0.2.1...v0.2.10"         "$out" "its compare link spans the bracketed previous version"

out=$(runk v0.2.0); rc=$?
[ "$rc" = 0 ] && ok "a bare X.Y.Z heading extracts" || bad "exit $rc for a bare heading"
says "The bare form."                   "$out" "its body is that section"
says_not "]: https://"                  "$out" x "link definitions at the end are not part of the last section"

# A repo with no changelog at all: also a failure, and for its own reason.
bare="$root/bare"; git init -q "$bare"
out=$( cd "$bare" && "$notes" notes v1.0.0 2>&1 ); rc=$?
[ "$rc" != 0 ] && ok "no CHANGELOG.md fails" || bad "a repo with no changelog exited 0"
says "no CHANGELOG.md" "$out" "and says so"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "changelog-notes: all $pass checks passed"
