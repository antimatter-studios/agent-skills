#!/usr/bin/env python3
"""UserPromptSubmit hook: say what the task in hand is, on every message.

Chris, 13 September 2026: *"can we control how you see messages as additional? instead of turn
ending or turn changing?"*

Partly, and this is the part. A message sent while the model is working already arrives as an
additional mid-turn note and does not end the turn; a message sent while it is idle starts a fresh
one, which is right — that is what a conversation is. What was missing is that neither of them says
**the task in hand is still in hand**, so a fresh turn looks like a clean slate and the job quietly
stops being worked on.

This appends one line to every prompt naming the held task. It is not a compulsion: the model can
still answer and stop. What it removes is the excuse that the task had gone out of view — and,
with the Stop hook's drift check, a turn that changes nothing now has to account for itself.

Exits 0 always. A hook that can block a person from typing is a worse thing than a forgotten task.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def main():
    try:
        json.load(sys.stdin)
    except ValueError:
        return 0
    try:
        state = json.loads(Path(".git/task-runner.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0
    held = next(
        (
            ident
            for ident, run in (state.get("runs") or {}).items()
            if isinstance(run, dict) and run.get("handed")
        ),
        None,
    )
    if held is None:
        return 0
    print(
        f"Task #{held} is in hand and stays in hand. This message is ADDITIONAL: answer it in a few"
        " sentences and carry on with the task in the same turn. Answering is never the whole turn."
        " If the message changes what the task should be, say so and re-file it — do not simply"
        " stop working on it."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
