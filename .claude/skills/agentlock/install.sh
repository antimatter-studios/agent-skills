#!/usr/bin/env bash
# Install agentlock's two commands onto PATH, and its ignore line, for this machine.
#
#   install.sh [bin-dir]    copy git-agentlock and git-worktrees into <bin-dir>
#                           (default: ~/.local/bin) and add .agentlock to the
#                           global excludes file.
#
# WHY A GLOBAL IGNORE AND NOT A PER-PROJECT .gitignore
# ----------------------------------------------------
# `.agentlock` has to be invisible to git in every repository an agent might work
# in, including ones it has not met yet. A line in each project's `.gitignore`
# means a commit per project, which for a repository with a protected default
# branch means a pull request per project — a review, a CI run and a merge, to
# adopt a convention that has not proved itself yet. Conventions with that much
# friction in front of them do not get adopted.
#
# `~/.config/git/ignore` is read by git with no configuration when
# `core.excludesFile` is unset, and is the documented place for exactly this: a
# rule that is about how *this machine* works rather than about the project. One
# line, once, and every repository on the machine ignores the file for ever.
#
# The trade: the rule does not travel with a clone. Somebody setting up a new
# machine runs this installer, which is the same deal github-guard makes about
# its hooks, and for a comparable reason — these are per-operator facts, not
# per-project ones.
#
# MACHINE-WIDE, NOT PER-REPOSITORY
# --------------------------------
# Git runs any `git-foo` found on PATH as `git foo`, so there is nothing to
# configure in a repository to get `git worktrees` there. Re-running this is the
# update mechanism.
set -euo pipefail

bin=${1:-$HOME/.local/bin}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ignore=${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore

mkdir -p "$bin"
install -m 755 "$here/scripts/git-agentlock" "$here/scripts/git-worktrees" "$bin/"
printf 'installed git-agentlock and git-worktrees into %s\n' "$bin"

mkdir -p "$(dirname "$ignore")"
if grep -qx '\.agentlock' "$ignore" 2>/dev/null; then
  printf '%s already ignores .agentlock\n' "$ignore"
else
  printf '\n# advisory worktree ownership, see `git agentlock`\n.agentlock\n' >> "$ignore"
  printf 'added .agentlock to %s\n' "$ignore"
fi

case ":$PATH:" in
  *":$bin:"*) ;;
  # Said rather than fixed: editing somebody's shell profile from an installer is a larger
  # liberty than copying two scripts, and the failure without it is obvious and immediate.
  *) printf '\nnote: %s is not on PATH, so `git worktrees` will not resolve yet.\n' "$bin" >&2 ;;
esac

printf '\ntry: git worktrees\n'
