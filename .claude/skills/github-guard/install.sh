#!/usr/bin/env bash
# Install github-guard's hooks into ONE target git repo.
#
#   install.sh [path-to-repo]    copy the guards into <repo>/.githooks (default: cwd)
#                                and point core.hooksPath at it.
#
# The hooks are COPIED as real files and committed with the repo, so anyone who
# clones it gets the guards (no symlinks, nothing pointing outside the repo).
# core.hooksPath is per-clone local config, so each fresh clone re-runs
# `git config core.hooksPath .githooks` (this installer does that for you).
#
# Single-target only. Tracking which projects the guards were copied into, and
# re-syncing them all on upgrade, is GENERIC plumbing that lives in install-skill
# (the deployment registry at ~/.config/install-skill/<skill>.json). This script
# never reads or writes that registry.
set -euo pipefail

src=$(cd "$(dirname "$0")/githooks" && pwd)

# Copy the guard tree into <repo>/.githooks and point core.hooksPath at it.
# cp -R merges into an existing .githooks/ (overwrites github-guard's files,
# leaves any extra guards you added). Returns non-zero if <repo> isn't a git repo.
copy_into() {
  local target="$1" existing
  git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || {
    printf "  skip (not a git repo): %s\n" "$target" >&2; return 1; }
  existing=$(git -C "$target" config --get core.hooksPath || true)
  if [ -n "$existing" ] && [ "$existing" != ".githooks" ]; then
    printf "  WARNING %s: core.hooksPath='%s' (not .githooks); copying into .githooks/ but not changing it.\n" "$target" "$existing" >&2
  fi
  mkdir -p "$target/.githooks"
  cp -R "$src/." "$target/.githooks/"
  # Restore exec bits (cp may drop them) from the SOURCE tree, which is the
  # authority on which payload files are executable — dispatchers and guards yes,
  # lib/common.sh no, since it is sourced. Only files the payload actually ships
  # are touched.
  #
  # The rule used to be name-based (`! -name '*.*'` at depth 1, then `*.d/*.sh`).
  # Git hooks are extensionless by necessity, so that also matched a repo's own
  # data files living beside them: it marked .githooks/required-checks executable
  # in 21 repos in one upgrade run.
  ( cd "$src" && find . -type f -perm -u+x -print0 ) \
    | while IFS= read -r -d '' rel; do
        chmod +x "$target/.githooks/${rel#./}" 2>/dev/null || true
      done
  if [ -z "$existing" ] || [ "$existing" = ".githooks" ]; then
    git -C "$target" config core.hooksPath .githooks
  fi
}

target=$(cd "${1:-$PWD}" && pwd)
copy_into "$target"
printf 'github-guard installed in %s (core.hooksPath=.githooks).\n' "$target"
printf 'Commit the .githooks/ directory so the guards travel with the repo.\n'
printf 'To record this deployment and re-sync every project on upgrade, ask install-skill:\n'
printf '  "deploy github-guard into %s"  /  "upgrade all github-guard deployments".\n' "$target"
