#!/usr/bin/env bash
# A version-tag push is judged against the tagged tree, even when the current
# checkout has since removed or moved its changelog files.
set -uo pipefail

hooks=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
guard="$hooks/pre-push.d/git-changelog.sh"
[ -x "$guard" ] || { echo "missing git-changelog.sh under $hooks" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0

new_repo() {
  repo="$root/$1"
  git init -q "$repo"
  git -C "$repo" config user.email tests@example.invalid
  git -C "$repo" config user.name 'Guard tests'
}

tag_and_remove() {
  git -C "$repo" add --all
  git -C "$repo" commit -qm 'the release tree'
  git -C "$repo" tag v2.0.0
  tagged=$(git -C "$repo" rev-parse v2.0.0)
  git -C "$repo" rm -q --ignore-unmatch CHANGELOG.md README.md
  git -C "$repo" commit -qm 'the current tree no longer has a changelog'
}

push_tag() {
  printf 'refs/tags/v2.0.0 %s refs/tags/v2.0.0 %040d\n' "$tagged" 0 \
    | (cd "$repo" && bash "$guard") 2>&1
}

check() {
  local name="$1" expected="$2" phrase="$3" output rc
  output=$(push_tag); rc=$?
  if [ "$rc" = "$expected" ] && { [ -z "$phrase" ] || [[ "$output" == *"$phrase"* ]]; }; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (exit %s, output: %s)\n' "$name" "$rc" "$output"
  fi
}

new_repo changelog
printf '# Changelog\n\n## v1.0.0\n\nOld release.\n' > "$repo/CHANGELOG.md"
tag_and_remove
check 'a tagged CHANGELOG.md missing the version is rejected' 1 'CHANGELOG.md has no section for v2.0.0'

new_repo readme
printf '# Example\n\n## Changelog\n\n### v1.0.0\n\nOld release.\n' > "$repo/README.md"
tag_and_remove
check 'a tagged README changelog missing the version is rejected' 1 'README changelog has no section for v2.0.0'

new_repo documented
printf '# Changelog\n\n## v2.0.0\n\nThis release.\n' > "$repo/CHANGELOG.md"
tag_and_remove
check 'a documented old tag passes from a later checkout' 0 ''

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
