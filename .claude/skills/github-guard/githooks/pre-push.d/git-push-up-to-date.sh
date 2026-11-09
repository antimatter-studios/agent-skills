#!/usr/bin/env bash
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"
guard_enabled push-up-to-date true || exit 0

remote=${1:-origin}
default=
default_sha=
checked=0
status=0
while read -r local_ref local_sha remote_ref remote_sha; do
  : "$local_ref" "$remote_sha"
  printf '%s' "$local_sha" | grep -qE '^0+$' && continue
  case "$remote_ref" in refs/heads/*) ;; *) continue ;; esac
  if [ "$checked" = 0 ]; then
    default=$(git symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null) || default=
    default=${default#"refs/remotes/$remote/"}
    if [ -z "$default" ]; then
      default=$(git ls-remote --symref "$remote" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\(.*\)[[:space:]]HEAD$|\1|p')
    fi
    if [ -z "$default" ]; then
      echo "github-guard: warning: default branch for $remote is unknown — allowing push without an up-to-date check" >&2
      exit 0
    fi
    checked=1
  fi
  [ "$remote_ref" != "refs/heads/$default" ] || continue
  if [ -z "$default_sha" ]; then
    if ! git fetch --quiet "$remote" "$default"; then
      echo "github-guard: warning: cannot fetch $remote $default — allowing push without an up-to-date check" >&2
      exit 0
    fi
    default_sha=$(git rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) || {
      echo "github-guard: warning: cannot resolve $remote/$default — allowing push without an up-to-date check" >&2
      exit 0
    }
  fi
  if ! git merge-base --is-ancestor "$default_sha" "$local_sha"; then
    branch=${remote_ref#refs/heads/}
    echo "github-guard: you cannot push a branch that is not up to date. $branch ($local_sha) does not contain $remote/$default ($default_sha). Rebase it first: git fetch $remote $default && git rebase $remote/$default, then push again." >&2
    status=1
  fi
done
exit "$status"
