#!/usr/bin/env bash
# Install agentlock into ONE target repository.
#
#   install.sh [path-to-repo]    copy the script to <repo>/tools/agentlock, add .agentlock to
#                                <repo>/.gitignore, and print the chores.yml tasks to add.
#                                (default: cwd)
#   install.sh --tasks           print just the tasks.
#
# PER PROJECT, NOT PER MACHINE
# ----------------------------
# An earlier version of this installed a binary into ~/.local/bin and added the ignore line to
# ~/.config/git/ignore, on the reasoning that a line per project means a commit per project — and
# for a repository with a protected default branch, a pull request per project.
#
# That reasoning was wrong, and the way it was wrong is worth keeping: it solved a per-project
# problem by changing a machine. Every project that adopts this already has a task runner and a
# `.gitignore`; nothing here needs to be true of the operator. A tool that quietly puts itself on
# somebody's PATH to save them a commit has decided on their behalf that its convenience outranks
# their control of their own system, and the cost lands on somebody who never agreed to it — on a
# machine where the next person wonders where `agentlock` came from.
#
# So the script lives in the repository that uses it, `chores.yml` calls it by relative path, and
# `.gitignore` carries the one line. A project adopts it explicitly, which is also how you find out
# whether anyone wanted it.
set -euo pipefail

tasks() {
  cat <<'YAML'
  worktrees:
    desc: Every worktree of this repository, with who holds it and what it would cost to remove
    cmds: ['tools/agentlock list']

  claim:
    desc: Say this worktree is yours, and what you are doing in it
    args:
      - name: doing
        desc: one line about the work
    cmds: ['tools/agentlock claim "{{.DOING}}"']

  unclaim:
    desc: Give this worktree back
    cmds: ['tools/agentlock release']
YAML
}

[ "${1:-}" = '--tasks' ] && { tasks; exit 0; }

repo=${1:-$PWD}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || {
  printf '%s is not a git repository\n' "$repo" >&2; exit 1; }
root=$(git -C "$repo" rev-parse --show-toplevel)

mkdir -p "$root/tools"
install -m 755 "$here/scripts/agentlock" "$root/tools/agentlock"
printf 'installed %s/tools/agentlock\n' "$root"

ignore="$root/.gitignore"
if grep -qx '\.agentlock' "$ignore" 2>/dev/null; then
  printf '%s already ignores .agentlock\n' "$ignore"
else
  # A worktree's owner is a fact about who is at the keyboard right now, never about the branch, so
  # it must not travel in a commit.
  printf '\n# who is working in this worktree; see `chore worktrees`\n.agentlock\n' >> "$ignore"
  printf 'added .agentlock to %s\n' "$ignore"
fi

if [ -f "$root/chores.yml" ] && grep -q '^  worktrees:' "$root/chores.yml"; then
  printf 'chores.yml already has the tasks\n'
else
  printf '\nNow add these to %s/chores.yml (or: install.sh --tasks):\n\n' "$root"
  tasks
fi
