#!/usr/bin/env bash
set -uo pipefail

src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
guard="$src/pre-push.d/git-push-up-to-date.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
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
git init -q --bare -b trunk "$root/remote.git"
git clone -q "$root/remote.git" "$root/seed" 2>/dev/null
git -C "$root/seed" -c user.name=T -c user.email=t@example.com commit -q --allow-empty -m base
git -C "$root/seed" push -q origin trunk
git clone -q "$root/remote.git" "$root/work"
cd "$root/work" || exit 2
git config user.name T
git config user.email t@example.com
git remote rename origin upstream
git switch -q -c feature
git commit -q --allow-empty -m feature
stale=$(git rev-parse HEAD)
zero=0000000000000000000000000000000000000000
run_guard() { printf '%s\n' "$1" | bash "$guard" upstream 2>&1; }
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'current new branch is allowed by default' 0 "$?" "$out"

git -C "$root/seed" -c user.name=T -c user.email=t@example.com commit -q --allow-empty -m advance
git -C "$root/seed" push -q origin trunk
latest=$(git -C "$root/seed" rev-parse HEAD)
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'stale new branch is refused after fetching' 1 "$?" "$out"
expected="github-guard: you cannot push a branch that is not up to date. feature ($stale) does not contain upstream/trunk ($latest). Rebase it first: git fetch upstream trunk && git rebase upstream/trunk, then push again."
check 'refusal names branch, both SHAs, remote and remedy' "$expected" "$out"
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $stale")
check 'existing stale branch is refused' 1 "$?" "$out"
mkdir -p .git/hooks/lib .git/hooks/pre-push.d
cp "$src/pre-push" .git/hooks/pre-push
cp "$src/lib/common.sh" "$src/lib/run-guards.sh" .git/hooks/lib/
cp "$guard" .git/hooks/pre-push.d/
out=$(git push upstream feature 2>&1)
check 'real pre-push dispatcher refuses stale branch' 1 "$?" "$out"
published=$(git --git-dir="$root/remote.git" for-each-ref --format='%(refname)' refs/heads/feature)
check 'refused push leaves remote branch absent' '' "$published"
git rebase -q upstream/trunk
current=$(git rev-parse HEAD)
out=$(run_guard "refs/heads/feature $current refs/heads/feature $stale")
check 'rebased branch is allowed' 0 "$?" "$out"
out=$(git push upstream feature 2>&1)
check 'real pre-push dispatcher allows rebased branch' 0 "$?" "$out"
out=$(run_guard "refs/heads/feature $stale refs/heads/renamed $zero")
check 'pushed SHA is checked, not checked-out HEAD' 1 "$?" "$out"
out=$(run_guard "refs/heads/feature $current refs/heads/current $zero
refs/heads/old $stale refs/heads/old $zero")
check 'every branch in a multi-ref push is checked' 1 "$?" "$out"
mkdir -p "$root/bin"
cat > "$root/bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = fetch ]; then printf 'fetch\n' >> "$GG_FETCH_LOG"; fi
exec "$GG_REAL_GIT" "$@"
SH
chmod +x "$root/bin/git"
real_git=$(command -v git)
out=$(GG_REAL_GIT="$real_git" GG_FETCH_LOG="$root/fetches" PATH="$root/bin:$PATH" run_guard "refs/heads/old $stale refs/heads/old $zero
refs/heads/feature $current refs/heads/current $zero")
check 'later current ref does not erase a stale refusal' 1 "$?" "$out"
fetches=$(wc -l < "$root/fetches" | tr -d ' ')
check 'multi-ref push fetches default only once' 1 "$fetches"

git config -f .github-guard guards.push-up-to-date false
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'file false opts out' 0 "$?" "$out"
git config github-guard.guards.push-up-to-date true
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'clone true overrides file opt-out' 1 "$?" "$out"
git config github-guard.guards.push-up-to-date auto
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'auto still checks a stale branch' 1 "$?" "$out"
git config github-guard.guards.push-up-to-date false
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'clone false opts out' 0 "$?" "$out"
git config --unset github-guard.guards.push-up-to-date
git config -f .github-guard guards.push-up-to-date true

git symbolic-ref --delete refs/remotes/upstream/HEAD
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'missing tracking HEAD discovers server default' 1 "$?" "$out"
git symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/trunk
git remote set-url upstream "$root/offline.git"
out=$(run_guard "refs/heads/feature $stale refs/heads/trunk $zero")
check 'default-branch target is skipped offline' 0 "$?" "$out"
check 'default-branch skip does not fetch or warn' '' "$out"
out=$(run_guard "(delete) $zero refs/heads/gone $stale")
check 'deletion is skipped offline' 0 "$?" "$out"
check 'deletion skip does not fetch or warn' '' "$out"
out=$(run_guard "refs/tags/v1 $stale refs/tags/v1 $zero")
check 'tag is skipped offline' 0 "$?" "$out"
check 'tag skip does not fetch or warn' '' "$out"
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'fetch failure allows push' 0 "$?" "$out"
case "$out" in *'warning: cannot fetch upstream trunk'*) check 'offline allowance warns' yes yes ;; *) check 'offline allowance warns' yes no "$out" ;; esac
git symbolic-ref --delete refs/remotes/upstream/HEAD
out=$(run_guard "refs/heads/feature $stale refs/heads/feature $zero")
check 'unknown default allows push' 0 "$?" "$out"
case "$out" in *'warning: default branch for upstream is unknown'*) check 'unknown default warns' yes yes ;; *) check 'unknown default warns' yes no "$out" ;; esac
out=$(bash "$guard" upstream </dev/null 2>&1)
check 'empty ref input is a silent no-op' '' "$out"

[ "$fail" -eq 0 ] || exit 1
echo "push-up-to-date: all $pass checks passed"
