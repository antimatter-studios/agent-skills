#!/usr/bin/env bash
# Install agentlock for this machine, and print the chore tasks a project should adopt.
#
#   install.sh [bin-dir]    copy `agentlock` into <bin-dir> (default: ~/.local/bin) and add
#                           .agentlock to the global excludes file.
#   install.sh --tasks      print the chores.yml tasks, so they can be pasted or piped.
#
# WHY A GLOBAL IGNORE AND NOT A PER-PROJECT .gitignore
# ----------------------------------------------------
# `.agentlock` has to be invisible to git in every repository an agent might work in, including ones
# it has not met yet. A line in each project's `.gitignore` is a commit per project, and for a
# repository with a protected default branch that is a pull request per project — a review, a CI run
# and a merge, to adopt a convention that has not proved itself. Conventions with that much friction
# in front of them do not get adopted.
#
# `~/.config/git/ignore` is read by git with no configuration when `core.excludesFile` is unset, and
# is the documented place for a rule about how *this machine* works rather than about the project.
# One line, once, and every repository on the machine ignores the file for ever.
#
# The trade: the rule does not travel with a clone, so a new machine runs this installer. That is
# the same deal github-guard makes about its hooks, and for a comparable reason — these are
# per-operator facts, not per-project ones.
#
# WHY THE VERBS GO IN chores.yml AND NOT ON git
# ---------------------------------------------
# The first version shipped `git worktrees`, one letter from git's own `git worktree`. Nothing was
# shadowed — git resolves built-ins before PATH — but a typo of the built-in silently ran something
# else, and "technically safe" is not "reads safely". The verbs belong beside a project's other
# verbs, where `chore worktrees` reads like `chore check` and `chore release`.
set -euo pipefail

tasks() {
  cat <<'YAML'
  worktrees:
    desc: Every worktree of this repository, with who holds it and what it would cost to remove
    cmds: ['agentlock list']

  claim:
    desc: Say this worktree is yours, and what you are doing in it
    args:
      - name: doing
        desc: one line about the work
    cmds: ['agentlock claim "{{.DOING}}"']

  unclaim:
    desc: Give this worktree back
    cmds: ['agentlock release']
YAML
}

[ "${1:-}" = '--tasks' ] && { tasks; exit 0; }

bin=${1:-$HOME/.local/bin}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ignore=${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore

mkdir -p "$bin"
install -m 755 "$here/scripts/agentlock" "$bin/"
printf 'installed agentlock into %s\n' "$bin"

mkdir -p "$(dirname "$ignore")"
if grep -qx '\.agentlock' "$ignore" 2>/dev/null; then
  printf '%s already ignores .agentlock\n' "$ignore"
else
  printf '\n# advisory worktree ownership, see the agentlock skill\n.agentlock\n' >> "$ignore"
  printf 'added .agentlock to %s\n' "$ignore"
fi

case ":$PATH:" in
  *":$bin:"*) ;;
  # Said rather than fixed: editing somebody's shell profile from an installer is a larger liberty
  # than copying one script, and the failure without it is obvious and immediate.
  *) printf '\nnote: %s is not on PATH, so `agentlock` will not resolve yet.\n' "$bin" >&2 ;;
esac

printf '\nNow add these to the project'\''s chores.yml (or: install.sh --tasks):\n\n'
tasks
