#!/usr/bin/env python3
"""Append one task to .task-list.json, creating it if this is the first."""

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

LIST = Path(".task-list.json")

# A file that turns up in a repository root should say what it is. Anybody who checks this out and
# finds it has no other way to know, and "it is a queue a hook reads" is two lines.
DESCRIPTION = [
    "Work waiting to be done, in order. A Stop hook reads this and will not let a turn end while",
    "anything here is unfinished: it verifies the task in hand, takes any remaining work as new",
    "tasks inserted below it, then hands out the next one.",
    "",
    "`what` is the whole brief — the hook reads it out and the model gets nothing else.",
    "`check` is a shell command whose exit code decides whether the task is done; it must FAIL when",
    "the task is written, or it is not evidence of anything. `by` says who asked for the task.",
    "",
    "Commit this. It is the queue, and somebody else picking the repo up can see what is waiting.",
    "The run's own bookkeeping — which task was handed out, when, against which commit — lives in",
    ".git/task-runner.json instead, because it changes every turn and belongs to the machine doing",
    "the run rather than to the work.",
    "",
    "Added by: ~/.claude/skills/task-runner/add.py",
]


def main():
    # who is asking. A check written by the person who wants the work is a specification; a check
    # written by the model that will be graded on it is a hypothesis it has made about itself. Both
    # are worth having and they are not worth the same, so the file says which.
    by = "model" if "--mine" in sys.argv else "user"
    args = [a for a in sys.argv[1:] if a != "--mine"]

    def pull(flag):
        """Take `--flag value` out of the arguments and hand back the value."""
        nonlocal args
        if flag not in args:
            return None
        at = args.index(flag)
        value = args[at + 1] if at + 1 < len(args) else None
        args = args[:at] + args[at + 2:]
        return value

    check = pull("--check")
    after = pull("--after")
    what = " ".join(args).strip()
    if not what:
        print('usage: add.py "what has to be true when this is done"', file=sys.stderr)
        sys.exit(1)

    data = {"_description": DESCRIPTION, "tasks": []}
    if LIST.exists():
        try:
            data = json.loads(LIST.read_text(encoding="utf-8"))
        except ValueError:
            print(f"{LIST} is not readable as JSON; refusing to overwrite it", file=sys.stderr)
            sys.exit(1)

    """
    A check has to be RED when the task is written, or it is not evidence of anything.

    This is the answer to the only real hole in the design — that the model usually writes both the
    task and the thing it will be graded on, which is marking its own homework. A check chosen after
    the fact, or chosen because it already passes, proves nothing at all; and that is not a matter
    of good faith, it is a fact a machine can settle in one second. So the machine settles it: run
    the check now, and refuse it if it is already green.

    What survives is the red step from red-green, enforced at the moment the task is created rather
    than trusted. A check that has been seen to fail, on a task written before the work, is a
    genuinely different object from a claim made afterwards.

    `--anyway` exists for the case where a check is legitimately green at the outset — a regression
    guard on behaviour that already works, where the task is "keep this true while changing that".
    It is recorded in the task so the reader knows the red step was skipped on purpose.
    """
    if check and "--anyway" not in sys.argv:
        try:
            ran = subprocess.run(check, shell=True, capture_output=True, text=True, timeout=900)
        except subprocess.TimeoutExpired:
            ran = None
        if ran is not None and ran.returncode == 0:
            print(
                f"refusing this check: `{check}` already passes.\n"
                "A check that is green before the work is not evidence the work happened — it is a\n"
                "claim wearing the costume of a test. Write one that fails now and passes when the\n"
                "task is done (the red test from red-green is exactly this), or leave the check off\n"
                "and let the task be marked unverified.\n"
                "If it is deliberately a regression guard on something that already works, pass "
                "--anyway.",
                file=sys.stderr,
            )
            sys.exit(1)

    data.setdefault("_description", DESCRIPTION)
    tasks = data.setdefault("tasks", [])
    task = {
        "id": max((t.get("id", 0) for t in tasks), default=0) + 1,
        "what": what,
        "by": by,
        "check": check,
        # whether the check was seen to fail when this was written. False means somebody said
        # --anyway, and the reader should know the red step did not happen
        "was_red": bool(check) and "--anyway" not in sys.argv,
        "added": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "done": None,
    }
    # `--after N` puts it directly below task N, which is how remainder work stays next to the job
    # it came out of instead of arriving ninety tasks later with the context gone
    where = len(tasks)
    if after is not None:
        where = next((i + 1 for i, t in enumerate(tasks) if str(t.get("id")) == after), len(tasks))
    tasks.insert(where, task)
    LIST.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"task {task['id']} added; {sum(1 for t in tasks if not t.get('done'))} outstanding")


main()
