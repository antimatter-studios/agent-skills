#!/usr/bin/env bash
set -uo pipefail

src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
git init -q -b main "$root/work"
cd "$root/work" || exit 2
pass=0
fail=0
check() {
  local name="$1" expected="$2" actual="$3" detail="${4:-}"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s — expected %s, got %s\n%s\n' "$name" "$expected" "$actual" "$detail"
    fail=$((fail + 1))
  fi
}
enabled() { bash -c '. "$1/lib/common.sh"; guard_enabled example "$2"' bash "$src" "$1"; }

for default in true auto false; do
  expected=0
  [ "$default" != false ] || expected=1
  enabled "$default"
  check "absent flag uses $default default" "$expected" "$?"
done

for value in true false auto; do
  expected=0
  [ "$value" != false ] || expected=1
  git config -f .github-guard guards.example "$value"
  enabled false
  check "file flag $value overrides default" "$expected" "$?"
  git config github-guard.guards.example "$value"
  git config -f .github-guard guards.example false
  enabled true
  check "clone flag $value overrides file" "$expected" "$?"
  git config --unset github-guard.guards.example
done
git config -f .github-guard guards.example true
enabled false
check 'file true enables a default-false guard' 0 "$?"
git config github-guard.guards.example false
enabled true
check 'clone false overrides file true' 1 "$?"
git config --unset github-guard.guards.example

git config -f .github-guard guards.example invalid
out=$(enabled true 2>&1)
check 'invalid value keeps enabled default' 0 "$?" "$out"
case "$out" in *'invalid guards.example'*) check 'invalid value warns' yes yes ;; *) check 'invalid value warns' yes no "$out" ;; esac
enabled false 2>/dev/null
check 'invalid value keeps disabled default' 1 "$?"
printf 'not [valid\n' > .github-guard
out=$(enabled true 2>&1)
check 'malformed file keeps default' 0 "$?" "$out"
case "$out" in *'cannot read .github-guard'*) check 'malformed file warns' yes yes ;; *) check 'malformed file warns' yes no "$out" ;; esac
git config github-guard.guards.example false
enabled true
check 'clone override wins even with malformed file' 1 "$?"
git config --unset github-guard.guards.example
printf '[guards]\n example = false\n' > "$root/included"
printf '[include]\n path = %s\n' "$root/included" > .github-guard
enabled true
check 'declaration includes are not followed' 0 "$?"

printf '[checks]\n strict = false\n[merge]\n auto = false\n' > .github-guard
enabled true
check 'settings are not guard switches' 0 "$?"

bash "$src/pre-merge-commit.d/git-block-merge-commit.sh" >/dev/null 2>&1
check 'existing guard still blocks by default' 1 "$?"
git config -f .github-guard guards.block-merge-commit false
bash "$src/pre-merge-commit.d/git-block-merge-commit.sh" >/dev/null 2>&1
check 'file false skips a blocking guard' 0 "$?"
git config github-guard.guards.block-merge-commit true
bash "$src/pre-merge-commit.d/git-block-merge-commit.sh" >/dev/null 2>&1
check 'clone true restores a file-disabled guard' 1 "$?"

for guard in "$src"/*.d/*.sh; do
  name=$(basename "$guard" .sh)
  name=${name#git-}
  name=${name#github-}
  git config "github-guard.guards.$name" false
  out=$(bash "$guard" </dev/null 2>&1)
  check "clone false skips $name" 0 "$?" "$out"
  check "disabled $name is silent" '' "$out"
done

mkdir -p "$root/hooks/lib" "$root/hooks/pre-merge-commit.d"
cp "$src/lib/common.sh" "$src/lib/run-guards.sh" "$root/hooks/lib/"
cp "$src/pre-merge-commit.d/git-block-merge-commit.sh" "$root/hooks/pre-merge-commit.d/"
bash "$root/hooks/lib/run-guards.sh" pre-merge-commit </dev/null >/dev/null 2>&1
check 'dispatcher skips a disabled blocking guard' 0 "$?"

[ "$fail" -eq 0 ] || exit 1
echo "guard-flags: all $pass checks passed"
