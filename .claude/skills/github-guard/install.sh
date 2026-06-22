#!/usr/bin/env bash
# Install / upgrade github-guard's hooks in a target git repo.
#
#   install.sh [path-to-repo]    copy the guards into <repo>/.githooks (default: cwd)
#                                and record <repo> in the installed_into registry
#   install.sh --upgrade-all     re-copy fresh guards into every recorded project
#
# The hooks are COPIED as real files and committed with the repo, so anyone who
# clones it gets the guards (no symlinks, nothing pointing outside the repo).
#
# installed_into registry (~/.config/install-skill/github-guard.json) remembers
# every project the guards were copied into, so `--upgrade-all` can refresh them
# all — each project keeps its own committed copy. core.hooksPath is per-clone
# local config, so each fresh clone runs `git config core.hooksPath .githooks`.
set -euo pipefail

src=$(cd "$(dirname "$0")/githooks" && pwd)
reg="${XDG_CONFIG_HOME:-$HOME/.config}/install-skill/github-guard.json"

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
  # Restore exec bits (cp may drop them); lib/common.sh is sourced, so no +x.
  find "$target/.githooks" -maxdepth 1 -type f ! -name '*.*' -exec chmod +x {} +
  chmod +x "$target/.githooks/lib/run-guards.sh" 2>/dev/null || true
  find "$target/.githooks" -type f -path '*.d/*.sh' -exec chmod +x {} + 2>/dev/null || true
  if [ -z "$existing" ] || [ "$existing" = ".githooks" ]; then
    git -C "$target" config core.hooksPath .githooks
  fi
}

# Append a repo path to installed_into (dedup). Best-effort.
record_install() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$reg" "$1" <<'PY' 2>/dev/null || true
import json, os, sys
reg, target = sys.argv[1:3]
os.makedirs(os.path.dirname(reg), exist_ok=True)
data = {}
if os.path.exists(reg):
    try: data = json.load(open(reg))
    except Exception: data = {}
data.setdefault("name", "github-guard")
paths = [p for p in (data.get("installed_into") or []) if p != target]
paths.append(target)
data["installed_into"] = paths
with open(reg, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
PY
}

if [ "${1:-}" = "--upgrade-all" ]; then
  [ -f "$reg" ] || { echo "github-guard: nothing recorded yet ($reg absent)"; exit 0; }
  paths=$(python3 -c "import json,sys;print('\n'.join(json.load(open(sys.argv[1])).get('installed_into',[])))" "$reg" 2>/dev/null || true)
  [ -n "$paths" ] || { echo "github-guard: installed_into is empty — nothing to upgrade"; exit 0; }
  echo "github-guard: re-copying guards into each recorded project…"
  printf '%s\n' "$paths" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
      copy_into "$p" && printf "  upgraded: %s  (review & commit .githooks/)\n" "$p"
    else
      printf "  skip (missing): %s\n" "$p"
    fi
  done
  exit 0
fi

target=$(cd "${1:-$PWD}" && pwd)
copy_into "$target"
record_install "$target"
printf 'github-guard installed in %s (core.hooksPath=.githooks); recorded in installed_into.\n' "$target"
printf 'Commit the .githooks/ directory so the guards travel with the repo.\n'
printf 'Upgrade every recorded project later with:  install.sh --upgrade-all\n'
