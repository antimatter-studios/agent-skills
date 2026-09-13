#!/usr/bin/env python3
"""Every way the tracker may be touched, as commands rather than as things to compose.

    task.py list                      what is outstanding, and what each is waiting on
    task.py show <id>                 one task, with everything written on it since
    task.py add "<text>" [--check C]  a task with no parent: a hole found next door
    task.py split <id> "<text>"       the REMAINDER of that job, as a sub-issue of it

Anything longer than a line goes in a file: `--body-file <path>` instead of the text. A brief is
markdown and markdown has backticks in it, and a backtick in a shell argument is a command
substitution — which silently deleted three code names out of a task the first afternoon this CLI
existed. A file cannot be eaten by the shell on the way past.
    task.py block <id> <on>           <id> cannot start until <on> is finished
    task.py label <id> +a -b          put a state on it, or take one off
    task.py done <id> [--check C]     finished; refuses if a label says it is waiting
    task.py reopen <id> "<why>"       un-close something that should not have been
    task.py say <id> "<text>"         write on it, once per distinct thing said

Chris, 13 September 2026: *"If we mechanically give claude these commands, it'll make the quality
of the responses higher since we don't rely on the agent to think of what to run. They ask for a
command, they are given a command, they execute the command exactly as given."*

He is right, and the evidence is a day of getting it wrong by hand. In one session the model
invented a GraphQL field that does not exist (`blockedByIssueId`; it is `blockingIssueId`), read an
array length off an object and got the count of its keys, broke a query with an embedded newline,
wrote a zsh loop that did not split because zsh does not word-split unquoted variables, and filed
four issues with raw `gh` instead of the runner's own functions — so they are missing from its run
record. Five distinct faults, none of them interesting, all of them from re-deriving a command that
should have been fixed.

The point is not that the model cannot write `gh` commands. It is that writing them *again each
time* means each one is a fresh chance to be subtly different, and subtly different is exactly the
kind of wrong that still returns a plausible answer.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from source import source, STUCK_LABELS      # noqa: E402


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    what, rest = argv[0], argv[1:]
    store = source()

    def pull(flag):
        if flag not in rest:
            return None
        at = rest.index(flag)
        value = rest[at + 1] if at + 1 < len(rest) else None
        del rest[at:at + 2]
        return value

    if what == "list":
        for t in store.tasks():
            waiting = f"  waiting on {t['waiting_on']}" if t.get("waiting_on") else ""
            print(f"#{t['id']:>3}  {t['what'].splitlines()[0][:70]}{waiting}")
        return 0

    if what == "show":
        ident = int(rest[0])
        task = next((t for t in store.tasks() if t["id"] == ident), {"id": ident})
        print(task.get("what", f"#{ident}"))
        said = store.said(task)
        print(f"\n--- {len(said)} comment(s), oldest first ---")
        for note in said:
            print(f"\n[{note['when'][:10]}] {note['by']}:\n{note['what']}")
        return 0

    if what == "add":
        check = pull("--check")
        body = pull("--body-file")
        made = store.add(Path(body).read_text(encoding="utf-8") if body else rest[0], check=check)
        print(f"#{made}" if made else "could not create it")
        return 0 if made else 1

    if what == "split":
        check = pull("--check")
        body = pull("--body-file")
        text = Path(body).read_text(encoding="utf-8") if body else rest[1]
        store.insert_after({"id": int(rest[0])}, text, check=check)
        print(f"filed under #{rest[0]}")
        return 0

    if what == "block":
        store.block({"id": int(rest[0])}, int(rest[1]))
        print(f"#{rest[0]} waits on #{rest[1]}")
        return 0

    if what == "label":
        ident = int(rest[0])
        add = [a[1:] for a in rest[1:] if a.startswith("+")]
        off = [a[1:] for a in rest[1:] if a.startswith("-")]
        unknown = [l for l in add if l not in STUCK_LABELS and not l.startswith("needs-")]
        if unknown:
            print(f"not a state this runner knows: {unknown}", file=sys.stderr)
        store.label({"id": ident}, add=add, remove=off)
        print(f"#{ident}: +{add} -{off}")
        return 0

    if what == "done":
        check = pull("--check")
        from datetime import datetime, timezone
        when = datetime.now(timezone.utc).isoformat(timespec="seconds")
        store.mark_done({"id": int(rest[0]), "check": check}, when, verified=bool(check))
        return 0

    if what == "reopen":
        store.reopen({"id": int(rest[0])}, rest[1] if len(rest) > 1 else "")
        print(f"#{rest[0]} is open again")
        return 0

    if what == "say":
        body = pull("--body-file")
        store.say({"id": int(rest[0])}, Path(body).read_text(encoding="utf-8") if body else rest[1])
        return 0

    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
