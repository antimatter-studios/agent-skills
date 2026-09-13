#!/usr/bin/env python3
"""Append one task to .task-list.json, creating it if this is the first."""

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

LIST = Path(".task-list.json")


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

    data = {"tasks": []}
    if LIST.exists():
        try:
            data = json.loads(LIST.read_text(encoding="utf-8"))
        except ValueError:
            print(f"{LIST} is not readable as JSON; refusing to overwrite it", file=sys.stderr)
            sys.exit(1)

    tasks = data.setdefault("tasks", [])
    task = {
        "id": max((t.get("id", 0) for t in tasks), default=0) + 1,
        "what": what,
        "by": by,
        "check": check,
        "added": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "handed": None,
        "at": None,
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
