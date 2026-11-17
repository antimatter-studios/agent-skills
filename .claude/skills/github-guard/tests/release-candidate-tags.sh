#!/usr/bin/env bash
# A release-candidate tag (vN.N.N-rc<N>, such as v0.4.0-rc1) is tagged, not cut: a build to try before
# its release lands. git-tags-on-main lets it point at a commit that is not on main, and
# git-changelog asks it for no section. Only that exact shape is exempt. A final tag, and every name
# that merely looks like a candidate, stays fully guarded, which is the fail-closed direction.
#
#   tests/release-candidate-tags.sh [githooks-dir]
set -uo pipefail

src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
for guard in pre-push.d/git-tags-on-main.sh pre-push.d/git-changelog.sh lib/common.sh; do
  [ -f "$src/$guard" ] || { echo "missing $guard under $src" >&2; exit 2; }
done

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0
fail=0
zero=0000000000000000000000000000000000000000

new_repo() {
  repo="$root/$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.email tests@example.invalid
  git -C "$repo" config user.name 'Guard tests'
  printf '# Changelog\n\n## [0.3.0] — 2026-01-01\n\n- Old.\n' >"$repo/CHANGELOG.md"
  git -C "$repo" add --all
  git -C "$repo" commit -qm 'main'
}

# commit_on_branch: a commit on a branch main does not contain, as a release branch is.
commit_on_branch() {
  git -C "$repo" switch -q -c release-branch
  printf '\n## [0.4.0] — 2026-02-01\n\n- New.\n' >>"$repo/CHANGELOG.md"
  git -C "$repo" commit -qam 'the release'
}

# push NAME GUARD: pushes tag NAME, as git hands the guard its refs.
push() {
  local name="$1" guard="$2" sha
  sha=$(git -C "$repo" rev-parse "refs/tags/$name")
  printf 'refs/tags/%s %s refs/tags/%s %s\n' "$name" "$sha" "$name" "$zero" |
    (cd "$repo" && bash "$src/pre-push.d/$guard" origin 2>&1)
}

# verdict NAME GUARD EXPECTED-EXIT PHRASE
verdict() {
  local label="$1" name="$2" guard="$3" expected="$4" phrase="$5" output rc
  output=$(push "$name" "$guard"); rc=$?
  if [ "$rc" = "$expected" ] && { [ -z "$phrase" ] || [[ "$output" == *"$phrase"* ]]; } &&
    { [ -n "$phrase" ] || [ -z "$output" ]; }; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf 'FAIL %s — exit %s, wanted %s; output: %s\n' "$label" "$rc" "$expected" "$output"
  fi
}

# --- the helper itself ---------------------------------------------------------------------
helper() {  # helper TAG yes|no
  local expected=1 rc
  [ "$2" = yes ] && expected=0
  bash -c '. "$1/lib/common.sh"; gg_is_release_candidate "$2"' bash "$src" "$1"; rc=$?
  if [ "$rc" = "$expected" ]; then
    pass=$((pass + 1)); printf 'ok   %s is %s\n' "$1" "$([ "$2" = yes ] && echo a candidate || echo not a candidate)"
  else
    fail=$((fail + 1)); printf 'FAIL %s — exit %s, wanted candidate=%s\n' "$1" "$rc" "$2"
  fi
}
helper v0.4.0-rc1 yes
helper v1.0.0-rc2 yes
helper v1.0.0-rc10 yes
helper v10.20.30-rc123 yes
helper v0.4.0 no
helper v0.4.0-RC1 no
helper v0.4.0-Rc1 no
helper v0.4.0-rc no
helper v0.4.0-rc0 no
helper v0.4.0-rc01 no
helper v0.4.0-rc.1 no
helper v0.4.0-rc-1 no
helper v0.4.0-rc1x no
helper v0.4.0-rc1-rc2 no
helper v0.4.0-hotfix no
helper v0.4.0-beta1 no
helper 'v0.4.0~rc1' no
helper 0.4.0-rc1 no
helper v0.4-rc1 no
helper v0.4.0-rc1/evil no
helper nightly no

# --- git-tags-on-main ----------------------------------------------------------------------
new_repo tags
commit_on_branch
git -C "$repo" tag -a v0.4.0-rc1 -m rc
git -C "$repo" tag v0.4.0-rc2
git -C "$repo" tag -a v0.4.0-rc3 -m rc "$(git -C "$repo" rev-parse main)"
git -C "$repo" tag -a v0.4.0 -m real
git -C "$repo" tag release-notes
# Names that look like a candidate and are not one. (Tag names that differ only by case would
# collide on a case-insensitive filesystem, so each of these differs in more than that.)
for bad in v0.4.0-RC9 v0.4.0-rc v0.4.0-rc0 v0.4.0-rc01 v0.4.0-rc.1 v0.4.0-hotfix v0.4.0-rc1x v0.4.0rc1; do
  git -C "$repo" tag "$bad"
done
verdict 'a candidate tag off main is accepted' v0.4.0-rc1 git-tags-on-main.sh 0 ''
verdict 'a lightweight candidate off main is accepted' v0.4.0-rc2 git-tags-on-main.sh 0 ''
verdict 'a candidate on main is accepted' v0.4.0-rc3 git-tags-on-main.sh 0 ''
verdict 'a final tag off main is still blocked' v0.4.0 git-tags-on-main.sh 1 'tag v0.4.0 points at'
verdict 'a non-semver tag off main is still blocked' release-notes git-tags-on-main.sh 1 'not on main'
for bad in v0.4.0-RC9 v0.4.0-rc v0.4.0-rc0 v0.4.0-rc01 v0.4.0-rc.1 v0.4.0-hotfix v0.4.0-rc1x v0.4.0rc1; do
  verdict "$bad off main is still blocked" "$bad" git-tags-on-main.sh 1 'not on main'
done

# A push of several tags is judged tag by tag.
output=$(printf 'refs/tags/v0.4.0-rc1 %s refs/tags/v0.4.0-rc1 %s\nrefs/tags/v0.4.0 %s refs/tags/v0.4.0 %s\nrefs/tags/v0.4.0-RC9 %s refs/tags/v0.4.0-RC9 %s\n' \
  "$(git -C "$repo" rev-parse v0.4.0-rc1)" "$zero" "$(git -C "$repo" rev-parse v0.4.0)" "$zero" "$(git -C "$repo" rev-parse v0.4.0-RC9)" "$zero" |
  (cd "$repo" && bash "$src/pre-push.d/git-tags-on-main.sh" origin 2>&1))
rc=$?
if [ "$rc" = 1 ] && [[ "$output" == *'tag v0.4.0 points at'* ]] && [[ "$output" == *'tag v0.4.0-RC9 points at'* ]] && [[ "$output" != *'v0.4.0-rc1 points'* ]]; then
  pass=$((pass + 1)); printf 'ok   a push of a candidate, a release and a look-alike blocks only the last two\n'
else
  fail=$((fail + 1)); printf 'FAIL mixed push — exit %s: %s\n' "$rc" "$output"
fi

# --- git-changelog -------------------------------------------------------------------------
# A candidate needs no section. A final tag with none is still refused, and so is a look-alike.
new_repo changelog
git -C "$repo" tag -a v0.4.0-rc1 -m rc
git -C "$repo" tag -a v0.4.0 -m real
git -C "$repo" tag v0.4.0-RC9
git -C "$repo" tag v0.4.0-rc0
git -C "$repo" tag v0.4.0-rc.1
verdict 'a candidate whose release has no section is accepted' v0.4.0-rc1 git-changelog.sh 0 ''
verdict 'the final tag with no section is still refused' v0.4.0 git-changelog.sh 1 'CHANGELOG.md has no section for v0.4.0.'
verdict 'an uppercase look-alike is checked like a release' v0.4.0-RC9 git-changelog.sh 1 'no section for v0.4.0-RC9'
verdict 'rc0 is checked like a release' v0.4.0-rc0 git-changelog.sh 1 'no section for v0.4.0-rc0'
verdict 'a dotted look-alike is checked like a release' v0.4.0-rc.1 git-changelog.sh 1 'no section for v0.4.0-rc.1'

new_repo readme
printf '# Example\n\n## Changelog\n\n### v0.3.0\n\nOld.\n' >"$repo/README.md"
git -C "$repo" add --all
git -C "$repo" commit -qm 'readme'
git -C "$repo" tag -a v0.4.0-rc1 -m rc
verdict 'a candidate is not asked for a README section either' v0.4.0-rc1 git-changelog.sh 0 ''

# The final tag still has its own section, whatever its candidates did.
new_repo documented
commit_on_branch
git -C "$repo" tag -a v0.4.0 -m real
git -C "$repo" tag -a v0.4.0-rc1 -m rc
verdict 'a documented final tag passes' v0.4.0 git-changelog.sh 0 ''
verdict 'and so does its candidate' v0.4.0-rc1 git-changelog.sh 0 ''

[ "$fail" -eq 0 ] || exit 1
echo "release-candidate-tags: all $pass checks passed"
