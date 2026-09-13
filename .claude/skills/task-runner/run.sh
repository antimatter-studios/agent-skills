#!/usr/bin/env bash
# Work the queue from OUTSIDE the session, where the agent cannot decline.
#
#   run.sh [max-tasks]
#
# The Stop hook cannot compel anything and it is worth being plain about why: it runs after a turn
# has already ended, exits 2, and that re-invokes the model with a message. It is a trigger, not a
# gate. Nothing in it constrains what the next turn contains, so a turn spent writing a summary
# satisfies every check it has — which is exactly what happened, repeatedly, on 13 September 2026.
#
# This is the other shape. The loop lives here, in a shell, and the model is a subprocess that gets
# one task at a time. Between invocations THIS decides what happened, by asking git and GitHub
# rather than by reading what the model said about itself. A run that produces no evidence is
# retried with the failure quoted back at it; a task that survives three of those is labelled and
# the queue moves on.
#
# The difference that matters: the agent cannot end this loop. Only evidence or exhaustion can.
set -uo pipefail

# Run from a copy, so editing this file cannot corrupt a run already in progress.
#
# bash reads a script incrementally rather than all at once, so a long run reads its own later lines
# off disk long after it started. Editing this file during a run therefore changes the script the
# run is still reading — which on 13 September 2026 produced `syntax error near unexpected token
# 'fi'` at line 86, partway through, because somebody added a lock file to it while it worked.
if [ "${TASK_RUNNER_COPY:-}" != "1" ]; then
  mine=$(mktemp -t task-runner)
  cat "$0" > "$mine"
  TASK_RUNNER_COPY=1 bash "$mine" "$@"
  code=$?
  rm -f "$mine"
  exit $code
fi

here="${TASK_RUNNER_HOME:-$HOME/.claude/skills/task-runner}"

# Say that this is driving, so the interactive session's Stop hook stands down. Without it both are
# armed on one queue: the hook hands the open session the task the subprocess is already working,
# and whichever finishes second overwrites the first. Cleared however this exits.
lock=".git/task-runner.lock"
printf '%s' "$$" > "$lock"
trap 'rm -f "$lock"' EXIT INT TERM
max=${1:-20}
tried=0

say() { printf '\n=== %s\n' "$*"; }

# `awk` rather than `sed`, because BSD sed has no \s and the version of this that used one
# returned an empty string on macOS — so the loop reported "queue empty" and exited without ever
# invoking anything. Found by running it, which is the whole point of this file existing.
next_task() { python3 "$here/task.py" list 2>/dev/null | grep -v 'waiting on' | head -1 | awk '{print $2}'; }

evidence() {   # $1 = issue number, $2 = commit to measure from
  python3 - "$here" "$1" "$2" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from source import source
found = source().evidenceOn(int(sys.argv[2]), sys.argv[3])
print("|".join(found))
PY
}

while [ "$tried" -lt "$max" ]; do
  task=$(next_task)
  [ -z "$task" ] && { say "queue empty"; exit 0; }

  base=$(git rev-parse HEAD)
  brief=$(python3 "$here/task.py" show "$task" 2>/dev/null)
  say "task #$task, from $base"

  for attempt in 1 2 3; do
    if [ "$attempt" -eq 1 ]; then
      prompt="$brief"
    else
      prompt="$brief

ATTEMPT $attempt. The previous attempt left NOTHING behind: no commit naming #$task, no pull
request referencing it, no label on it, no sub-issue of it, and it is not closed. Whatever was
written last time, the repository and the tracker are exactly as they were. Do the work, or hand
it back with a label. Both leave a mark. Writing about it does not."
    fi

    # TASK_LOOP_MAX=0 disables the Stop hook INSIDE the subprocess, and without it this hangs.
    # The nested session inherits this project's hooks, so it bounces itself up to forty times
    # before returning — a loop inside the loop, each one handing itself the same task. The first
    # run of this file never came back, which is how it was found.
    TASK_LOOP_MAX=0 claude -p "$prompt" --permission-mode acceptEdits </dev/null >/dev/null 2>&1

    got=$(evidence "$task" "$base")
    if [ -n "$got" ]; then
      say "#$task left: ${got//|/, }"
      break
    fi
    say "#$task attempt $attempt left nothing"
  done

  if [ -z "$(evidence "$task" "$base")" ]; then
    # three turns and nothing to show. That is not a task the loop can finish, and saying so is
    # worth more than a fourth attempt: a person reads the label and decides what it really wants.
    say "#$task produced nothing in three attempts — labelling needs-respec"
    python3 "$here/task.py" label "$task" +needs-respec >/dev/null 2>&1
    python3 "$here/task.py" say "$task" "The runner gave this three attempts from $base and each one left nothing behind — no commit naming it, no pull request, no label, no sub-issue. That is a task the loop cannot get hold of, which is usually a task that does not say what done looks like." >/dev/null 2>&1
  fi
  tried=$((tried + 1))
done

say "stopped after $tried tasks"
