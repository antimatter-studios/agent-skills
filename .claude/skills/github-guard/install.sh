#!/usr/bin/env bash
# Install github-guard's hooks into ONE target git repo.
#
#   install.sh [path-to-repo]    copy the guards into <repo>'s .git/hooks
#                                (default: cwd) and clear core.hooksPath.
#
# WHY .git/hooks AND NOT AN IN-TREE .githooks/
# --------------------------------------------
# Git resolves a hook path at the moment it runs the hook, which for a checkout
# is AFTER the working tree has been rewritten. Point core.hooksPath at a
# directory inside the working tree and checking out an untrusted branch — a
# fork's PR, someone else's push — replaces the very hook that is about to run:
# their pre-commit then executes with your credentials, your ssh-agent and your
# gh token, against your checkout. Reviewing contributions locally is the normal
# case, so this is not a hypothetical.
#
# .git/hooks is per-repository, lives outside the working tree, and no ref can
# reach it. Whatever the operator last installed is what git executes. Re-running
# this installer stays the update mechanism, exactly as before.
#
# The trade: the guards no longer travel inside the repo, so a fresh clone runs
# this installer (a per-machine skill) rather than `git config core.hooksPath`.
# That is the price of the hooks not being rewritable by a branch.
#
# Single-target only. Tracking which projects the guards were copied into, and
# re-syncing them all on upgrade, is GENERIC plumbing that lives in install-skill
# (the deployment registry at ~/.config/install-skill/<skill>.json). This script
# never reads or writes that registry.
set -euo pipefail

src=$(cd "$(dirname "$0")/githooks" && pwd)

# Absolute path of the hooks directory git will read once core.hooksPath is gone.
#
# --git-common-dir, so a linked worktree installs into the ONE hooks directory
# git actually consults (hooks are not per-worktree). And deliberately NOT
# `rev-parse --git-path hooks`, which HONOURS core.hooksPath: while the old
# in-tree setting is still present that would hand back `.githooks` and we would
# cheerfully install straight back into the working tree.
hooks_dir_of() {
  local target="$1" common
  common=$(cd "$target" && git rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  (cd "$target" && cd "$common" && printf '%s/hooks\n' "$(pwd)")
}

# core.hooksPath OVERRIDES .git/hooks entirely. An install that writes the guards
# and leaves the setting in place is INERT — the old in-tree path keeps winning,
# silently, and every check short of running a hook says the install worked. So
# clear every scope this repo owns and then ASSERT the end state; a value that
# survives from --global/--system is the operator's to remove, and we refuse
# rather than pretend.
clear_hooks_path() {
  local target="$1" eff
  # `--unset-all` exits 5 for "key not there", which is the common case and not
  # an error; a genuine failure is caught by the assertion below either way.
  git -C "$target" config --unset-all core.hooksPath 2>/dev/null || true
  if [ "$(git -C "$target" config --get extensions.worktreeConfig 2>/dev/null || true)" = "true" ]; then
    git -C "$target" config --worktree --unset-all core.hooksPath 2>/dev/null || true
  fi
  eff=$(git -C "$target" config --get core.hooksPath 2>/dev/null || true)
  [ -z "$eff" ] && return 0
  printf '  ERROR %s: core.hooksPath is still %s after clearing this repo'\''s config.\n' "$target" "$eff" >&2
  printf '        It comes from your global or system git config and overrides .git/hooks,\n' >&2
  printf '        so the guards would be installed and never run. Clear it, then re-run:\n' >&2
  printf '          git config --global --unset core.hooksPath\n' >&2
  return 1
}

# A repo that predates this layout may keep its OWN guards in the tracked
# .githooks/. They used to run via core.hooksPath and now do not, so name each
# one instead of silently importing it: copying executables out of the working
# tree is the exact trust hole this install closes, and the bulk upgrade sweep
# runs across clones parked on whatever branch someone left them on.
#
# The test is the exec bit, not the filename. .githooks/required-checks is data,
# not a hook — and is read from the server, not the tree — so it is 644 and never
# trips this.
warn_orphaned_tree_guards() {
  local target="$1" rel found=0
  [ -d "$target/.githooks" ] || return 0
  while IFS= read -r rel; do
    rel=${rel#./}
    [ -f "$src/$rel" ] && continue     # ours; now installed under .git/hooks
    if [ "$found" = 0 ]; then
      found=1
      printf '  NOTE %s: repo-local guards under .githooks/ no longer run:\n' "$target" >&2
    fi
    printf '       .githooks/%s\n' "$rel" >&2
  done < <(cd "$target/.githooks" && find . -type f -perm -u+x | sort)
  if [ "$found" = 1 ]; then
    printf '       Move each into .git/hooks/<hook>.d/ to keep it, or delete it.\n' >&2
  fi
  return 0
}

# Copy the guard tree into <repo>'s .git/hooks. cp -R merges into an existing
# hooks dir (overwrites github-guard's files, leaves any extra guards you dropped
# there). Returns non-zero if <repo> isn't a git repo, or if the end state can't
# be reached. Sets HOOKS_DIR on success.
HOOKS_DIR=
copy_into() {
  local target="$1" hooks rel
  git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || {
    printf '  skip (not a git repo): %s\n' "$target" >&2; return 1; }
  hooks=$(hooks_dir_of "$target") || {
    printf '  skip (cannot resolve git dir): %s\n' "$target" >&2; return 1; }

  clear_hooks_path "$target" || return 1

  mkdir -p "$hooks"
  cp -R "$src/." "$hooks/"
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
        chmod +x "$hooks/${rel#./}" 2>/dev/null || true
      done

  warn_orphaned_tree_guards "$target"

  # Assert the END STATE, not the actions. Both halves matter and they fail
  # independently: hooks present but core.hooksPath still set = inert install.
  [ -x "$hooks/pre-commit" ] || {
    printf '  ERROR %s: %s/pre-commit missing or not executable after install.\n' "$target" "$hooks" >&2
    return 1; }
  [ -z "$(git -C "$target" config --get core.hooksPath 2>/dev/null || true)" ] || {
    printf '  ERROR %s: core.hooksPath is set again — the install would not run.\n' "$target" >&2
    return 1; }

  HOOKS_DIR="$hooks"
}

target=$(cd "${1:-$PWD}" && pwd)
copy_into "$target"
printf 'github-guard installed in %s\n' "$target"
printf '  hooks:          %s  (outside the working tree; no branch can rewrite them)\n' "$HOOKS_DIR"
printf '  core.hooksPath: unset  (it would override .git/hooks, so the installer clears it)\n'
printf 'Nothing to commit — the guards are per-clone. Every clone re-runs this installer.\n'
printf 'To record this deployment and re-sync every project on upgrade, ask install-skill:\n'
printf '  "deploy github-guard into %s"  /  "upgrade all github-guard deployments".\n' "$target"
