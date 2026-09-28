#!/usr/bin/env bash
# Tests for the local walls around the default branch, and for how
# github-protect-main arms and disarms them.
#
#   tests/main-walls.sh [path-to-githooks-dir]
#
# The walls exist for one case: GitHub refuses to protect a private repository's
# branch without a paid plan (403 "Upgrade to GitHub Pro"). github-protect-main
# records that in the clone's git config and the walls self-gate on it, so the
# cases below come in pairs — armed, the wall refuses; unarmed, the same action
# goes through. A wall that blocked everywhere would pass every "refuses" case,
# and the unarmed half is what catches it.
#
# The fast-forward case needs real refs, a real remote and git running the
# reference-transaction hook, so it installs the payload into a throwaway
# clone's .git/hooks and drives git itself. gh is stubbed for protect-main.
set -uo pipefail

src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
[ -d "$src/pre-commit.d" ] || { echo "not a githooks dir: $src" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# A work clone with a bare remote whose HEAD is main, and one commit on it.
# Echoes the work clone's path.
make_clone() {
  local dir="$root/$1"
  mkdir -p "$dir"
  git init -q --bare -b main "$dir/remote.git"
  git init -q -b main "$dir/seed"
  git -C "$dir/seed" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m base
  git -C "$dir/seed" push -q "$dir/remote.git" main
  git clone -q "$dir/remote.git" "$dir/work" 2>/dev/null
  git -C "$dir/work" config user.email t@example.com
  git -C "$dir/work" config user.name T
  printf '%s' "$dir/work"
}

arm()    { git -C "$1" config github-guard.protection unavailable; }
disarm() { git -C "$1" config --unset github-guard.protection 2>/dev/null || true; }

commit_guard="$src/pre-commit.d/git-no-commit-on-main.sh"
push_guard="$src/pre-push.d/git-no-push-to-main.sh"

# --- git-no-commit-on-main -------------------------------------------------

w=$(make_clone commit)
( cd "$w" && bash "$commit_guard" ) 2>/dev/null \
  && ok "commit on main, unarmed: allowed" || bad "commit on main, unarmed: should be allowed"
arm "$w"
( cd "$w" && bash "$commit_guard" ) 2>/dev/null \
  && bad "commit on main, armed: should be refused" || ok "commit on main, armed: refused"
git -C "$w" switch -q -c work
( cd "$w" && bash "$commit_guard" ) 2>/dev/null \
  && ok "commit on a branch, armed: allowed" || bad "commit on a branch, armed: should be allowed"
git -C "$w" switch -q --detach main
( cd "$w" && bash "$commit_guard" ) 2>/dev/null \
  && ok "detached HEAD, armed: allowed" || bad "detached HEAD, armed: should be allowed"

# No origin/HEAD: falls back to the usual names, and only those.
w=$(make_clone commit-nohead)
git -C "$w" remote set-head origin -d
arm "$w"
( cd "$w" && bash "$commit_guard" ) 2>/dev/null \
  && bad "no origin/HEAD, on main, armed: should be refused" || ok "no origin/HEAD, on main, armed: refused"
git -C "$w" switch -q -c feature
( cd "$w" && bash "$commit_guard" ) 2>/dev/null \
  && ok "no origin/HEAD, on feature, armed: allowed" || bad "no origin/HEAD, on feature, armed: should be allowed"

# --- git-no-push-to-main ---------------------------------------------------

w=$(make_clone push)
sha=$(git -C "$w" rev-parse HEAD)
z=0000000000000000000000000000000000000000
push() { ( cd "$w" && printf '%s\n' "$1" | bash "$push_guard" ) 2>/dev/null; }
push "refs/heads/work $sha refs/heads/main $z" \
  && ok "push to main, unarmed: allowed" || bad "push to main, unarmed: should be allowed"
arm "$w"
push "refs/heads/work $sha refs/heads/main $z" \
  && bad "push work:main, armed: should be refused" || ok "push work:main, armed: refused"
push "refs/heads/work $sha refs/heads/work $z" \
  && ok "push a branch, armed: allowed" || bad "push a branch, armed: should be allowed"
push "$(printf 'refs/heads/a %s refs/heads/a %s\nrefs/heads/b %s refs/heads/main %s' "$sha" "$z" "$sha" "$z")" \
  && bad "push of several refs, one of them main: should be refused" || ok "push of several refs, one of them main: refused"

# --- git-no-ff-main (reference-transaction, ships disarmed) ------------------

install_hooks() { rm -rf "$1/.git/hooks"; mkdir -p "$1/.git/hooks"; cp -R "$src/." "$1/.git/hooks/"; }

[ ! -e "$src/reference-transaction" ] && [ ! -x "$src/reference-transaction.d/git-no-ff-main.sh" ] \
  && ok "no reference-transaction hook is shipped, and git-no-ff-main ships without the exec bit" \
  || bad "git-no-ff-main must ship disarmed, with no reference-transaction hook installed"

w=$(make_clone ff)
install_hooks "$w"
git -C "$w" switch -q -c mywork
git -C "$w" commit -q --allow-empty -m "unreviewed" --no-verify
git -C "$w" switch -q main
out=$(git -C "$w" merge -q --ff-only mywork 2>&1); rc=$?
case "$out" in *"hook was ignored"*) bad "as shipped, git warns about an ignored hook on every ref update" ;;
  *) ok "as shipped, git prints no ignored-hook hint" ;; esac
if [ "$rc" = 0 ]; then
  ok "ff main onto local work, as shipped (disarmed): allowed"
  git -C "$w" reset -q --hard origin/main
else
  bad "ff main onto local work, as shipped (disarmed): should be allowed"
fi

# Armed exactly as the dispatcher template says.
cp "$w/.git/hooks/lib/reference-transaction.dispatcher" "$w/.git/hooks/reference-transaction"
chmod +x "$w/.git/hooks/reference-transaction" "$w/.git/hooks/reference-transaction.d/git-no-ff-main.sh"
before=$(git -C "$w" rev-parse main)
git -C "$w" merge -q --ff-only mywork 2>/dev/null \
  && bad "ff main onto local work, armed: should be refused" || ok "ff main onto local work, armed: refused"
[ "$(git -C "$w" rev-parse main)" = "$before" ] \
  && ok "  … and main did not move" || bad "  … main moved anyway"

# A sync with the remote must still work, with main checked out and without.
d=$(dirname "$w")
git clone -q "$d/remote.git" "$d/other" 2>/dev/null
git -C "$d/other" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m "reviewed, merged"
git -C "$d/other" push -q origin main
git -C "$w" pull -q --ff-only 2>/dev/null \
  && ok "pull --ff-only of main, armed: allowed (a sync)" || bad "pull --ff-only of main, armed: should be allowed"
git -C "$d/other" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m "merged again"
git -C "$d/other" push -q origin main
git -C "$w" switch -q mywork
git -C "$w" fetch -q origin main:main 2>/dev/null \
  && ok "fetch origin main:main with main not checked out, armed: allowed" \
  || bad "fetch origin main:main, armed: should be allowed"
[ "$(git -C "$w" rev-parse main)" = "$(git -C "$d/other" rev-parse main)" ] \
  && ok "  … and main is the remote's" || bad "  … main is not the remote's"

# Armed, then re-installed: the installer must leave the modes as they are.
bash "$(dirname "$src")/install.sh" "$w" >/dev/null 2>&1
[ -x "$w/.git/hooks/reference-transaction" ] && [ -x "$w/.git/hooks/reference-transaction.d/git-no-ff-main.sh" ] \
  && ok "re-running the installer keeps an armed git-no-ff-main armed" \
  || bad "re-running the installer disarmed git-no-ff-main"

# --- github-protect-main arms and disarms ------------------------------------

mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in auth) exit 0 ;; api) shift ;; *) exit 1 ;; esac
put=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) [ "${2:-}" = PUT ] && put=1; shift 2 ;;
    --jq|-H|--input) shift 2 ;;
    --paginate) shift ;;
    repos/*|user|user/*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$([ "$put" = 1 ] && echo PUT || echo GET)" "$url" >> "$GH_LOG"
[ "$put" = 1 ] && { cat >/dev/null; exit 1; }
case "$url" in
  user) echo testowner ;;
  */branches/*/protection)
    case "$GH_PROBE" in
      plan)      echo 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' >&2; exit 1 ;;
      forbidden) echo 'gh: Must have admin rights to Repository. (HTTP 403)' >&2; exit 1 ;;
      unprotected) echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1 ;;
      *) printf 'true\ntrue\n[]\n0\n' ;;
    esac ;;
  repos/testowner/testrepo) echo main ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$root/bin/gh"

pm="$src/pre-commit.d/github-protect-main.sh"
w=$(make_clone protect)
git -C "$w" remote set-url origin git@github.com:testowner/testrepo.git
export GH_LOG="$root/gh.log"
run_pm() { : > "$GH_LOG"; ( cd "$w" && GH_PROBE="$1" PATH="$root/bin:$PATH" bash "$pm" ) 2>"$root/pm.err"; }
armed() { [ "$(git -C "$w" config --get github-guard.protection)" = unavailable ]; }

run_pm plan
armed && ok "protect-main, plan refusal: walls armed" || bad "protect-main, plan refusal: walls should be armed"
grep -q 'armed the local walls' "$root/pm.err" && ok "  … and it says so" || bad "  … without saying so"
! grep -q '^PUT' "$GH_LOG" && ok "  … and it attempts no protection PUT" || bad "  … but still attempted the PUT"
[ "$(wc -l < "$GH_LOG")" -le 3 ] && ok "  … and stops after the probe ($(wc -l < "$GH_LOG" | tr -d ' ') gh calls)" \
  || bad "  … but went on to make $(wc -l < "$GH_LOG" | tr -d ' ') gh calls"
run_pm plan
armed && [ ! -s "$root/pm.err" ] && ok "protect-main, plan refusal again: still armed, quietly" \
  || bad "protect-main, plan refusal again: should stay armed without output"

run_pm forbidden
armed && ok "protect-main, a 403 that is not the plan: record left alone" \
  || bad "protect-main, a 403 that is not the plan: should not disarm"

run_pm unprotected
armed && bad "protect-main, protection available (404 not protected): should disarm" \
  || ok "protect-main, protection available (404 not protected): walls disarmed"

arm "$w"
run_pm protected
armed && bad "protect-main, branch protected: should disarm" || ok "protect-main, branch protected: walls disarmed"

disarm "$w"
run_pm protected
armed && bad "protect-main, protected and never armed: should stay unarmed" \
  || ok "protect-main, protected and never armed: stays unarmed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
