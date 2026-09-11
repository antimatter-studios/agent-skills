#!/usr/bin/env bash
# Report whether a repo's installed guards match THIS copy of github-guard.
#
#   status.sh [-v] [repo ...]    default: cwd
#
# The guards live in .git/hooks, outside the working tree, which is what stops a
# branch checkout from rewriting them (see install.sh). The cost of that choice
# is that they no longer travel with the repo: every clone holds its own copy,
# copies drift, and a copy that drifted is invisible to `git status`. This script
# is the missing read: it says, per repo, which files differ from the payload
# beside it and — when that payload sits in a git checkout — whether a differing
# file is an OLDER release or something written locally that was never upstreamed.
#
# That distinction is the whole point. "Older" is a file to overwrite by
# re-running install.sh. "Local" is a file someone improved in place, and
# overwriting it destroys work: several of the guards' best checks were written
# that way, in one deployment, and had to be recovered by hand. So the two are
# never reported as one number.
#
# The dating half needs the history of the payload. An installed skill (copied
# to ~/.claude/skills/<skill> by install-skill) has no history of its own, so
# point --source at an agent-skills checkout to get it; without one, files are
# still compared, just not dated.
set -euo pipefail

verbose=0
source_repo=
repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose) verbose=1 ;;
    --source) source_repo="${2:?--source needs a path}"; shift ;;
    --source=*) source_repo="${1#--source=}" ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'status.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) repos+=("$1") ;;
  esac
  shift
done
[ ${#repos[@]} -gt 0 ] || repos=("$PWD")

src=$(cd "$(dirname "$0")/githooks" && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Index of every version of every payload file that the source history has ever
# held, newest commit first, as "<path> <blob> <commit> <date>". Lookups are by
# (path, blob): the same bytes under a different name is a different question and
# we do not want to answer it by accident.
#
# git's own blob id is the hash to use, not a sha256 of the file: the source's
# copy of a blob id comes straight out of the tree, so a match is exact and needs
# no second hashing pass over history.
index="$tmp/index"
: >"$index"
build_index() {
  local repo top prefix c stamp
  repo=${source_repo:-$src}
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || return 1
  # Where the payload lives inside that checkout. With --source we are told the
  # repo, not the subdirectory, so locate it the same way install-skill does.
  if [ -n "$source_repo" ]; then
    prefix=$(cd "$top" && git ls-files --full-name | sed -n 's#^\(.*/github-guard\)/githooks/pre-commit$#\1/githooks#p' | head -1)
    [ -n "$prefix" ] || return 1
  else
    # Ask git where the payload sits, rather than subtracting the toplevel from
    # the path: `--show-toplevel` reports the PHYSICAL path while $PWD keeps the
    # symlinked one it was reached by, so on macOS's /var (a link to /private/var)
    # the subtraction silently strips nothing and every file becomes undatable.
    prefix=$(git -C "$src" rev-parse --show-prefix)
    prefix=${prefix%/}
    [ -n "$prefix" ] || return 1
  fi
  while IFS= read -r c; do
    stamp=$(git -C "$top" log -1 --format='%h %cs' "$c")
    git -C "$top" ls-tree -r "$c" -- "$prefix" \
      | awk -v pre="$prefix/" -v s="$stamp" '{ sub(/^.*blob /,""); blob=$1; $1=""; sub(/^\t?[ ]*/,""); p=$0; sub("^" pre, "", p); print p, blob, s }' >>"$index"
  done < <(git -C "$top" log --format=%H -- "$prefix")
  [ -s "$index" ]
}
dating=1
build_index || dating=0

# Newest source commit whose tree held these exact bytes at this exact path.
# Prints nothing and fails when history has never held them — awk exits 0 on a
# search that matched nothing, so the emptiness is the answer and the caller
# must not read the exit status alone.
dated_as() {
  local hit
  [ "$dating" = 1 ] || return 1
  hit=$(awk -v p="$1" -v b="$2" '$1 == p && $2 == b { print $3, $4; exit }' "$index")
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

hooks_dir_of() {
  # --git-common-dir because hooks are not per-worktree, and deliberately not
  # --git-path hooks, which honours core.hooksPath and would send us looking in
  # whatever in-tree directory an old install left behind.
  local target="$1" common
  common=$(cd "$target" && git rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  (cd "$target" && cd "$common" && printf '%s/hooks\n' "$(pwd)")
}

exit_code=0
for target in "${repos[@]}"; do
  target=$(cd "$target" 2>/dev/null && pwd) || { printf '%s: no such directory\n' "$target" >&2; exit_code=1; continue; }
  hooks=$(hooks_dir_of "$target") || { printf '%-52s not a git repo\n' "$target"; exit_code=1; continue; }

  missing=0 older=0 local_edits=0 unarmed=0 notes=()
  details=()

  while IFS= read -r rel; do
    rel=${rel#./}
    have="$hooks/$rel"
    if [ ! -f "$have" ]; then
      missing=$((missing + 1)); details+=("missing  $rel"); continue
    fi
    if ! cmp -s "$src/$rel" "$have"; then
      blob=$(git hash-object "$have")
      if when=$(dated_as "$rel" "$blob"); then
        older=$((older + 1)); details+=("older    $rel  ($when)")
      else
        local_edits=$((local_edits + 1)); details+=("local    $rel")
      fi
      continue
    fi
    # Identical bytes that git will not execute are still a guard that does not
    # run, and nothing else in this report would show it.
    if [ -x "$src/$rel" ] && [ ! -x "$have" ]; then
      unarmed=$((unarmed + 1)); details+=("unarmed  $rel")
    fi
  done < <(cd "$src" && find . -type f | sort)

  # core.hooksPath overrides .git/hooks wholesale: set, every file above is
  # correct AND never runs. It outranks any count, so it is said first.
  hp=$(git -C "$target" config --get core.hooksPath 2>/dev/null || true)
  [ -n "$hp" ] && notes+=("core.hooksPath=$hp overrides these hooks")

  # Executables under a tracked .githooks/ are guards this layout no longer runs.
  # required-checks is data, is 644, and correctly does not appear here.
  stranded=0
  if [ -d "$target/.githooks" ]; then
    orphans=$( (cd "$target/.githooks" && find . -type f -perm -u+x | sed 's#^\./##' | sort) )
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      [ -f "$src/$o" ] && continue
      stranded=$((stranded + 1))
      notes+=(".githooks/$o no longer runs")
    done <<<"$orphans"
  fi

  # One word per repo, and the two conditions that are NOT file drift get their
  # own words rather than sharing one: an override means the installed files are
  # right and none of them run, while stranded in-tree guards mean the installed
  # files are right and something ELSE used to run beside them. Reported as one
  # state they read as the same problem, and the sweep that cleans the tree gets
  # pointed at repos whose git config is the actual fault.
  state=current
  [ "$stranded" -gt 0 ] && state=stranded
  [ $((older + missing + unarmed)) -gt 0 ] && state=behind
  [ "$local_edits" -gt 0 ] && state=customised
  # An override outranks every count: with it set, nothing under .git/hooks runs
  # at all, so what those files say is beside the point until it is cleared.
  [ -n "$hp" ] && state=inert

  summary=""
  [ "$older" -gt 0 ] && summary+="$older older "
  [ "$local_edits" -gt 0 ] && summary+="$local_edits local "
  [ "$missing" -gt 0 ] && summary+="$missing missing "
  [ "$unarmed" -gt 0 ] && summary+="$unarmed not-executable "
  [ "$stranded" -gt 0 ] && summary+="$stranded stranded in .githooks/ "
  printf '%-52s %-11s %s\n' "$target" "$state" "${summary% }"
  for n in ${notes[@]+"${notes[@]}"}; do printf '%-52s   %s\n' "" "$n"; done
  if [ "$verbose" = 1 ]; then
    for d in ${details[@]+"${details[@]}"}; do printf '%-52s   %s\n' "" "$d"; done
  fi
  [ "$state" = current ] || exit_code=1
done

# A repo that is not current is a repo to act on, so the exit status says so: a
# sweep can stop on it, and `status.sh <repos>` doubles as the gate.
[ "$dating" = 1 ] || printf 'note: no payload history available, so differing files are all reported as local.\n      Pass --source <agent-skills checkout> to tell older releases from local edits.\n' >&2
exit "$exit_code"
