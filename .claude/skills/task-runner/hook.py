#!/usr/bin/env python3
"""Stop hook: verify the task in hand, then hand out the next one. Two guards, one file.

Chris, 2026-09-13, arriving at this over about ten minutes:

  "how do we know the task was completed? just because the turn is over, doesn't
   mean it's actually done what we needed"
  "the verification step asked what tasks are not yet completed and new items
   will be added to the list. That controls that we don't miss things out"
  "what if we insert the new items below the current verifying task, so they
   become the next tasks to complete by nature of being in the file after"

That is the whole design and it is better than handing out tasks alone.

GUARD ONE, VERIFY. The turn ends holding a task. This does not advance. It asks
one question — is it finished, and if not, what is left — and requires the answer
in the file rather than in prose: either the task is marked done, or new tasks
appear describing the remainder. The failure mode changes shape. Work is no
longer silently skipped; skipping it requires an explicit claim that it is
complete, written down where it can be read back.

GUARD TWO, DISPATCH. On the next stop the task is settled, so the first
unfinished one is handed over. Because the remainder was INSERTED BELOW rather
than appended, the next task is the rest of the same job — the context is still
warm. Appending would bring it back ninety unrelated tasks later with everything
forgotten, which is the same reason a stack beats a queue for this.

WHAT IS STILL NOT TRUE. Chris again, and it is the honest frame: "I can never be
sure Claude has written a feature as specified anyway, since I need to manually
read the code and/or test it." Right. A `check` — a command whose exit code
decides — is the only mechanical evidence available, and it only tests what it
was pointed at. Without one, "done" is the model's word. This makes stopping
hard. It does not make the work good, and nothing here should be read as though
it did.
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

LIST = Path(os.environ.get("TASK_LIST", ".task-list.json"))
MAX_BOUNCES = int(os.environ.get("TASK_LOOP_MAX", "40"))
COUNTER = Path(".git/.task-runner-bounces")
CHECK_TIMEOUT = int(os.environ.get("TASK_CHECK_TIMEOUT", "900"))


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def head():
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def passes(check):
    try:
        ran = subprocess.run(check, shell=True, capture_output=True, text=True, timeout=CHECK_TIMEOUT)
    except subprocess.TimeoutExpired:
        return False, f"did not finish inside {CHECK_TIMEOUT}s"
    if ran.returncode == 0:
        return True, ""
    return False, "\n    ".join((ran.stderr or ran.stdout or "").strip().split("\n")[-3:])


def say(lines):
    print("task-runner: " + "\n".join(lines), file=sys.stderr)
    sys.exit(2)


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        sys.exit(0)
    if event.get("stop_hook_active"):
        sys.exit(0)
    if not LIST.exists():
        sys.exit(0)
    try:
        data = json.loads(LIST.read_text(encoding="utf-8"))
    except ValueError:
        sys.exit(0)

    tasks = data.get("tasks", [])
    bounces = int(COUNTER.read_text()) if COUNTER.exists() else 0
    if bounces >= MAX_BOUNCES:
        COUNTER.unlink(missing_ok=True)
        print(f"task-runner: stopping after {bounces} turns; work remains on the list.", file=sys.stderr)
        sys.exit(0)

    held = next((t for t in tasks if t.get("handed") and not t.get("done")), None)

    # ---- guard one: the task in hand has to be answered for before anything advances ----
    #
    # The check runs BEFORE the question rather than after it. Asking "is this finished" and then
    # contradicting the answer a turn later is a worse conversation than asking a question that
    # already knows: a failing check turns "is it done?" into "it is not done, what is left?", which
    # is the question actually worth asking.
    if held is not None and not held.get("asked"):
        check = held.get("check")
        verdict, why = (passes(check) if check else (None, ""))
        held["asked"] = now()
        LIST.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        COUNTER.write_text(str(bounces + 1))

        if verdict is True:
            evidence = [f"Its check passes: `{check}`. That is evidence the symptom is gone — it is"
                        " not evidence the whole task is done, so read it before agreeing with it."]
        elif verdict is False:
            evidence = [f"Its check FAILS: `{check}`" + (f"\n    {why}" if why else ""),
                        "So it is not finished, whatever the turn looked like."]
        else:
            evidence = ["It has no check, so nothing but your word can say either way. Say plainly"
                        " which it is."]

        say([
            f"Task {held['id']} is in hand and this turn is over. Before anything else moves:",
            "",
            f"    {held['what']}",
            "",
        ] + evidence + [
            "",
            "Answer in the file, not in prose.",
            "",
            "  - Finished: mark it `\"done\"` with a timestamp.",
            "  - Not finished: add the remaining work as new tasks INSERTED DIRECTLY BELOW this one,"
            " so the next guard picks up the rest of this same job while it is still in your head."
            " Then mark this one done.",
            "",
            "Do not leave it unanswered. Work that is skipped silently is the thing this exists to"
            " prevent; work that is written down as outstanding is fine.",
        ])

    # ---- the task in hand has been answered for: settle it ----
    if held is not None:
        check = held.get("check")
        if check:
            ok, why = passes(check)
            if ok:
                held["done"] = now()
            else:
                COUNTER.write_text(str(bounces + 1))
                LIST.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
                say([
                    f"Task {held['id']} is not done: `{check}` still fails.",
                    f"    {why}" if why else "",
                    "",
                    "Either finish it, or split what is left into tasks below this one and say which"
                    " part is blocked and on what.",
                ])
        elif not held.get("done"):
            held["done"] = now()
            held["unverified"] = True

    following = next((t for t in tasks if not t.get("done")), None)
    if following is None:
        LIST.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        COUNTER.unlink(missing_ok=True)
        sys.exit(0)                                  # the list is empty: this is what done looks like

    # ---- guard two: hand over the first unfinished task ----
    following["handed"] = now()
    following["at"] = head()
    LIST.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    COUNTER.write_text(str(bounces + 1))

    left = sum(1 for t in tasks if not t.get("done"))
    lines = [f"Next task ({following['id']}), {left} outstanding:", "", f"    {following['what']}"]
    if following.get("check"):
        lines += ["", f"Done when this passes: {following['check']}"]
    say(lines)


main()
