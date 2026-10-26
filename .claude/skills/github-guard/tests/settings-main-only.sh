#!/usr/bin/env bash
# Exercise all settings writers with real branches and linked worktrees. The
# gh stub deliberately offers settings that need changing: a missing write on
# current main is a failure, just like a write from a feature or stale checkout.
set -euo pipefail
src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in auth) exit 0 ;; api) shift ;; *) exit 1 ;; esac
url=; method=GET; query=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    --jq) query=$2; shift 2 ;;
    -F|-f|-H|--input) shift 2 ;;
    --paginate) shift ;;
    *) url=$1; shift ;;
  esac
done
if [ "$method" != GET ]; then
  printf '%s %s\n' "$method" "$url" >> "$GH_WRITES"
  [ "$method" != PUT ] || cat >/dev/null
  exit 0
fi
case "$url" in
  user) echo testowner ;;
  */git/ref/heads/*)
    [ "${GH_UNREACHABLE:-0}" = 0 ] || exit 1
    printf '%s\n' "$GH_REMOTE_SHA" ;;
  */contents/*) printf 'file:[merge]\n auto = true\n' ;;
  */branches/*/protection)
    if [ -n "$query" ]; then
      case "$query" in
        *length*) echo 1 ;;
        *) printf 'false\nfalse\n[]\n0\nfalse\nfalse\ntrue\n' ;;
      esac
    fi ;;
  */actions/runs*|*/check-runs*|*/commits\?*) : ;;
  repos/testowner/testrepo)
    case "$query" in
      .default_branch) [ "${GH_NO_DEFAULT:-0}" = 0 ] || exit 1; echo "${GH_BRANCH:-main}" ;;
      .allow_auto_merge) echo false ;;
      *) echo 'true false true' ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$root/bin/gh"
export PATH="$root/bin:$PATH"
w="$root/work"
git init -q -b main "$w"
git -C "$w" -c user.name=T -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m base
git -C "$w" remote add origin git@github.com:testowner/testrepo.git
base=$(git -C "$w" rev-parse HEAD)
export GH_REMOTE_SHA="$base" GH_WRITES="$root/writes"

check() {
  local label=$1 target=$2 expected=$3 guard rc
  for guard in github-auto-merge github-merge-squash-only github-protect-main; do
    : > "$GH_WRITES"
    rc=0
    (cd "$target" && bash "$src/pre-commit.d/$guard.sh") >"$root/out" 2>&1 || rc=$?
    if [ "$rc" = 0 ] && { { [ "$expected" = write ] && [ -s "$GH_WRITES" ]; } || { [ "$expected" = skip ] && [ ! -s "$GH_WRITES" ]; }; }; then
      pass=$((pass + 1)); echo "ok   $guard: $label"
    else
      fail=$((fail + 1)); echo "FAIL $guard: $label (expected $expected, exit $rc)"
      cat "$GH_WRITES" "$root/out"
    fi
  done
}

check 'current default branch applies settings' "$w" write
git -C "$w" switch -q -c feature
check 'feature at the same commit cannot write' "$w" skip
git -C "$w" -c user.name=T -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m feature
check 'diverged feature cannot write' "$w" skip
git -C "$w" switch -q --detach main
check 'detached HEAD at current main cannot write' "$w" skip
git -C "$w" switch -q main
export GH_REMOTE_SHA=$(git -C "$w" rev-parse feature)
git -C "$w" update-ref refs/remotes/origin/main "$base"
check 'stale main cannot trust its stale origin/main' "$w" skip
git -C "$w" reset -q --hard feature
export GH_REMOTE_SHA="$base"
check 'main ahead of GitHub cannot write' "$w" skip
git -C "$w" reset -q --hard "$base"
GH_UNREACHABLE=1 check 'unreadable remote HEAD cannot write' "$w" skip
GH_NO_DEFAULT=1 check 'unreadable default branch cannot write' "$w" skip
export GH_REMOTE_SHA=null
check 'malformed remote HEAD cannot write' "$w" skip
export GH_REMOTE_SHA="$base"
git -C "$w" branch -m trunk
GH_BRANCH=trunk check 'current non-main default branch applies settings' "$w" write
git -C "$w" branch -m main
git -C "$w" worktree add -q -b linked "$root/linked" main
check 'feature worktree cannot write while main exists elsewhere' "$root/linked" skip
check 'main worktree still applies settings' "$w" write
git init -q -b main "$root/unborn"
git -C "$root/unborn" remote add origin git@github.com:testowner/testrepo.git
check 'unborn main cannot write' "$root/unborn" skip

[ "$fail" = 0 ] || { echo "$fail failed, $pass passed"; exit 1; }
echo "settings-main-only: all $pass checks passed"
