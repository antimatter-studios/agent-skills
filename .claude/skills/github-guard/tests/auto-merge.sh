#!/usr/bin/env bash
# Tests for github-auto-merge — the guard that keeps a repo's "Allow auto-merge"
# setting in line with `merge.auto` in its .github-guard — and for the
# auto-merge action that asks for it on each pull request.
#
#   tests/auto-merge.sh [path-to-githooks-dir]
#
# `gh` is stubbed. The guard's PATCH and the action's `gh pr merge` are captured
# to files instead of being sent, so every assertion is on what WOULD have
# changed on GitHub. The .github-guard file is served the way the contents API
# serves it (JSON, base64) and decoded by the guard's own --jq.
#
# The case the guard exists to get right is the refusal: auto-merge on a branch
# with no required status checks merges a pull request the moment it opens,
# before CI has run. It is asserted both ways — no PATCH, and a warning.
set -uo pipefail

src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
[ -f "$src/pre-commit.d/github-auto-merge.sh" ] || { echo "no github-auto-merge.sh under $src" >&2; exit 2; }
action=$(cd "$(dirname "$0")/../../../../.github/actions/auto-merge" 2>/dev/null && pwd)/auto-merge.sh

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pass=0; fail=0; n=0

ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

# ---- the gh stub -------------------------------------------------------------
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  auth) exit 0 ;;
  pr)
    # gh pr merge <n> --repo <r> --auto --squash
    printf '%s\n' "$*" >> "$GH_MERGE_LOG"
    exit "${GH_MERGE_RC:-0}" ;;
  api) shift ;;
  *) exit 1 ;;
esac
url=""; method=GET; jqexpr=""; fields=()
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    -F|-f) fields+=("$2"); shift 2 ;;
    -H|--input) shift 2 ;;
    --paginate) shift ;;
    repos/*|user|user/*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ "$method" = PATCH ]; then printf '%s\n' "${fields[@]}" >> "$GH_PATCH_LOG"; exit 0; fi
case "$url" in
  user) printf '%s\n' "${GH_LOGIN:-testowner}" ;;
  user/memberships/orgs/*) exit 1 ;;
  */contents/*)
    case "$url" in */contents/.github-guard\?*) ;; *) exit 1 ;; esac
    if [ "${GH_DECL_DIR:-0}" = 1 ]; then
      body='[{"type":"file","name":"required-checks"}]'
    elif [ -n "${GH_DECL:-}" ]; then
      body=$(jq -n --arg c "$(printf '%s\n' "$GH_DECL" | base64)" '{type:"file",encoding:"base64",content:$c}')
    else
      exit 1
    fi
    printf '%s' "$body" | jq -r "$jqexpr" ;;
  */branches/*/protection)
    [ -n "${GH_PROTECTION:-}" ] || exit 1   # 404: unprotected
    printf '%s' "$GH_PROTECTION" | jq -r "$jqexpr" ;;
  repos/*/*)
    printf '{"default_branch":"main","allow_auto_merge":%s}' "${GH_ALLOW:-false}" | jq -r "$jqexpr" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$root/bin/gh"
PATH="$root/bin:$PATH"

# ---- guard harness -----------------------------------------------------------
guard() {
  local name="$1" dir
  n=$((n + 1)); dir="$root/g$n"
  git init -q "$dir"
  git -C "$dir" remote add origin git@github.com:testowner/testrepo.git
  mkdir -p "$dir/.hooks"; cp -R "$src/." "$dir/.hooks/"
  [ -z "${WORKTREE_DECL:-}" ] || printf '%s\n' "$WORKTREE_DECL" > "$dir/.github-guard"
  export GH_PATCH_LOG="$dir/patch.log"; : > "$GH_PATCH_LOG"
  ( cd "$dir" && bash .hooks/pre-commit.d/github-auto-merge.sh ) >"$dir/out" 2>"$dir/err"; rc=$?
  CASE="$name"; DIR="$dir"
  [ "$rc" = 0 ] || bad "$CASE: the guard exited $rc — it must never block"
}
patched() {
  local got; got=$(tr '\n' ' ' < "$DIR/patch.log" | sed 's/ $//')
  if [ "$got" = "$1" ]; then ok "$CASE → ${1:-no change}"
  else bad "$CASE: want PATCH '${1:-none}', got '${got:-none}'"; sed 's/^/        stderr: /' "$DIR/err"; fi
}
warned() {
  if grep -qF "$1" "$DIR/err"; then ok "$CASE (says: $1)"
  else bad "$CASE: stderr lacks '$1'"; sed 's/^/        stderr: /' "$DIR/err"; fi
}

PROTECTED='{"required_status_checks":{"strict":true,"checks":[{"context":"CI"}]}}'
NOCHECKS='{"required_status_checks":null,"required_pull_request_reviews":{}}'
ON=$'[merge]\n\tauto = true'
OFF=$'[merge]\n\tauto = false'

printf 'github-auto-merge guard (%s)\n' "$src"

GH_DECL=$ON GH_PROTECTION=$PROTECTED GH_ALLOW=false guard 'merge.auto = true, main requires checks: enabled'
patched 'allow_auto_merge=true'

GH_DECL=$ON GH_PROTECTION=$PROTECTED GH_ALLOW=true guard 'already enabled: no write'
patched ''

GH_DECL=$ON GH_PROTECTION=$NOCHECKS GH_ALLOW=false guard 'REFUSED: main requires no status checks'
patched ''
warned 'NOT enabling auto-merge'

GH_DECL=$ON GH_PROTECTION='' GH_ALLOW=false guard 'REFUSED: main is not protected at all'
patched ''
warned 'NOT enabling auto-merge'

# Already on with nothing gating it: turning it OFF would be second-guessing a
# setting someone may have made on purpose, so it warns instead.
GH_DECL=$ON GH_PROTECTION=$NOCHECKS GH_ALLOW=true guard 'on without required checks: warned, not changed'
patched ''
warned 'WARNING'

GH_DECL=$OFF GH_PROTECTION=$PROTECTED GH_ALLOW=true guard 'merge.auto = false disables it'
patched 'allow_auto_merge=false'

GH_DECL=$OFF GH_ALLOW=false guard 'merge.auto = false, already off: no write'
patched ''

GH_DECL=$'[checks]\n\trequired = CI' GH_PROTECTION=$PROTECTED GH_ALLOW=true guard 'no merge.auto: the setting is left alone'
patched ''

GH_DECL='' GH_PROTECTION=$PROTECTED GH_ALLOW=true guard 'no .github-guard at all: left alone'
patched ''

GH_DECL=$'[merge]\n\tauto = sometimes' GH_PROTECTION=$PROTECTED GH_ALLOW=false guard 'a non-boolean is not read as true'
patched ''
warned 'not a boolean'

GH_DECL=$'[merge\n\tauto = true' GH_PROTECTION=$PROTECTED GH_ALLOW=false guard 'a malformed file changes nothing'
patched ''
warned 'not valid git-config'

GH_DECL_DIR=1 GH_PROTECTION=$PROTECTED GH_ALLOW=true guard 'the old .github-guard/ directory changes nothing'
patched ''
warned 'not a file'

# git-config booleans: yes/on/1 are true too.
GH_DECL=$'[merge]\n\tauto = yes' GH_PROTECTION=$PROTECTED GH_ALLOW=false guard 'auto = yes is a true'
patched 'allow_auto_merge=true'

# The working tree is not where this is read from: a checked-out branch saying
# `auto = true` must not switch it on.
WORKTREE_DECL=$ON GH_DECL='' GH_PROTECTION=$PROTECTED GH_ALLOW=false guard 'a working-tree merge.auto is not read'
patched ''

# Owner-only, as every github-* guard.
GH_LOGIN=someone-else GH_DECL=$ON GH_PROTECTION=$PROTECTED GH_ALLOW=false guard 'a repo you do not own is left alone'
patched ''

# ---- action harness ----------------------------------------------------------
printf '\nauto-merge action (%s)\n' "$action"
if [ ! -x "$action" ]; then
  bad "the action script is missing or not executable: $action"
else
  # event <head-repo|null> <base> <draft>
  event() {
    local head=$1 base=$2 draft=$3 headjson
    if [ "$head" = null ]; then headjson=null; else headjson="{\"full_name\":\"$head\"}"; fi
    cat <<JSON
{"repository":{"full_name":"testowner/testrepo","default_branch":"main"},
 "pull_request":{"number":7,"draft":$draft,"base":{"ref":"$base"},"head":{"repo":$headjson}}}
JSON
  }
  act() {
    local name="$1" ev="$2" dir
    n=$((n + 1)); dir="$root/a$n"; mkdir -p "$dir"
    printf '%s\n' "$ev" > "$dir/event.json"
    export GH_MERGE_LOG="$dir/merge.log" GITHUB_OUTPUT="$dir/output"; : > "$GH_MERGE_LOG"; : > "$GITHUB_OUTPUT"
    GITHUB_EVENT_PATH="$dir/event.json" GITHUB_EVENT_NAME="${EVENT_NAME:-pull_request}" RUNNER_TEMP="$dir" \
      "$action" >"$dir/out" 2>&1; rc=$?
    CASE="$name"; DIR="$dir"
  }
  merged() {
    local got; got=$(cat "$DIR/merge.log")
    if [ "$got" = "$1" ]; then ok "$CASE → ${1:-not merged}"
    else bad "$CASE: want '${1:-no merge}', got '${got:-no merge}'"; sed 's/^/        out: /' "$DIR/out"; fi
  }
  result_is() {
    if grep -qxF "result=$1" "$DIR/output"; then ok "$CASE (result=$1)"
    else bad "$CASE: want result=$1, got '$(cat "$DIR/output")'"; fi
  }
  MERGE='pr merge 7 --repo testowner/testrepo --auto --squash'

  GH_DECL=$ON act 'same-repo PR into main with merge.auto = true: auto-merge requested' \
    "$(event testowner/testrepo main false)"
  merged "$MERGE"; result_is enabled
  [ "$rc" = 0 ] && ok "and the step succeeds" || bad "the step exited $rc"

  GH_DECL=$ON act 'a FORK pull request is never auto-merged' "$(event stranger/testrepo main false)"
  merged ''; result_is skipped:fork

  GH_DECL=$ON act 'a pull request from a deleted fork is a fork' "$(event null main false)"
  merged ''; result_is skipped:fork

  GH_DECL=$ON act 'a stacked PR into another branch is not auto-merged' "$(event testowner/testrepo feat/base false)"
  merged ''; result_is skipped:base

  GH_DECL=$ON act 'a draft is not auto-merged' "$(event testowner/testrepo main true)"
  merged ''; result_is skipped:draft

  GH_DECL=$OFF act 'merge.auto = false: not requested' "$(event testowner/testrepo main false)"
  merged ''; result_is skipped:not-declared

  GH_DECL=$'[checks]\n\trequired = CI' act 'no merge.auto: not requested' "$(event testowner/testrepo main false)"
  merged ''; result_is skipped:not-declared

  GH_DECL='' act 'no .github-guard: not requested' "$(event testowner/testrepo main false)"
  merged ''; result_is skipped:no-file

  GH_DECL=$'[merge\n\tauto = true' act 'a malformed .github-guard: not requested' "$(event testowner/testrepo main false)"
  merged ''; result_is skipped:invalid

  GH_DECL=$ON EVENT_NAME=push act 'not a pull request event: nothing to do' "$(event testowner/testrepo main false)"
  merged ''; result_is skipped:event

  GH_DECL=$ON GH_MERGE_RC=1 act 'GitHub refusing the request fails the step' "$(event testowner/testrepo main false)"
  [ "$rc" != 0 ] && ok "$CASE (exit $rc)" || bad "$CASE: exited 0 — a repo that never auto-merges would look fine"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
