#!/usr/bin/env bash
# Install github-guard's hooks into a target git repository (default: cwd).
#
#   install.sh [path-to-repo]
#
# Copies the dispatcher hooks + lib + guard scripts into <repo>/.githooks/ and
# points the repo's core.hooksPath there.
#
# Merge-friendly: github-guard owns the hook dispatchers and lib/, and ships
# its guards into the *.d/ directories. Re-running upgrades those in place;
# any *other* guard scripts you've added to the .d/ dirs are left untouched.
#
# Commit .githooks/ so the scripts travel with the repo. core.hooksPath is
# per-clone local config, so each fresh clone must re-run this (or
# `git config core.hooksPath .githooks`).
set -euo pipefail

src=$(cd "$(dirname "$0")/githooks" && pwd)
target=${1:-$PWD}
target=$(cd "$target" && pwd)

git -C "$target" rev-parse --git-dir >/dev/null 2>&1 \
  || { printf "install: '%s' is not a git repository\n" "$target" >&2; exit 1; }

existing=$(git -C "$target" config --get core.hooksPath || true)
if [ -n "$existing" ] && [ "$existing" != ".githooks" ]; then
  printf "install: WARNING — target already sets core.hooksPath='%s' (not .githooks).\n" "$existing" >&2
  printf "install: copying into .githooks/ but NOT changing core.hooksPath. Reconcile manually.\n" >&2
fi

mkdir -p "$target/.githooks"
# Copy dispatchers, lib/, and *.d/ guards. cp -R merges into existing .githooks/
# (overwrites same-named files, keeps the rest).
cp -R "$src/." "$target/.githooks/"

# Restore executable bits (cp may not preserve them across some filesystems).
# Hooks + the runner + all guard scripts are executable; lib/common.sh is only
# ever sourced, so it doesn't need +x.
find "$target/.githooks" -maxdepth 1 -type f ! -name '*.*' -exec chmod +x {} +   # dispatcher stubs
chmod +x "$target/.githooks/lib/run-guards.sh" 2>/dev/null || true
find "$target/.githooks" -type f -path '*.d/*.sh' -exec chmod +x {} + 2>/dev/null || true

if [ -z "$existing" ] || [ "$existing" = ".githooks" ]; then
  git -C "$target" config core.hooksPath .githooks
fi

printf 'github-guard installed in %s (core.hooksPath=.githooks)\n' "$target"
printf 'Commit the .githooks/ directory so the guards travel with the repo.\n'
printf 'Each fresh clone must run:  git config core.hooksPath .githooks  (or re-run this installer).\n'
