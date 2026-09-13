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
import re
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from source import source                                            # noqa: E402

MAX_BOUNCES = int(os.environ.get("TASK_LOOP_MAX", "40"))
CHECK_TIMEOUT = int(os.environ.get("TASK_CHECK_TIMEOUT", "900"))

# The run's own bookkeeping, kept apart from the work.
#
# Which task was handed out, when it was asked about, and what the repository was sitting on at the
# time are facts about *this run on this machine*. They change every single turn. Keeping them in
# the shared list would mean a diff on every turn and a merge conflict whenever two people ran it,
# for information neither of them wants. The list is the queue and is worth committing; this is not.
STATE = Path(".git/task-runner.json")


def bookkeeping():
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"bounces": 0, "runs": {}}


def keep(state):
    try:
        STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    except OSError:
        pass                                   # no .git, or read-only: the loop still works


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


def comingRoundAgain(tries):
    """What to say to a task that will not finish, which is not "try harder".

    One pass unfinished is ordinary — a turn ran out. Two is a different fact about the task: it is
    bigger or vaguer than a turn, and the same effort applied again gets the same result. So the
    second pass stops asking whether it is done and starts asking what the smallest finishable piece
    of it is.

    It lives here rather than in either branch because both of them are the same moment. A task can
    come round with a failing check or with no check at all, and the answer to "this keeps not
    finishing" does not depend on which.
    """
    if tries < 2:
        return []
    return [
        "",
        f"**This is pass {tries} on this task.** Coming round again is the signal that it is bigger "
        "or vaguer than one turn, not that it wants trying harder — the same effort will get the "
        "same result. So do not simply attempt it again:",
        "",
        "  - **Break it up.** Name the smallest piece that can be finished and checked on its own, "
        "add the rest as tasks below this one, and do that piece. Three small tasks that each finish "
        "beat one that never does.",
        "  - **Or say you cannot.** If it will not break up because it is not clear what is being "
        "asked, that is `needs-respec`: comment with what you tried and where it stopped, and take "
        "the next one. A person respecifies it from your account.",
    ]


def say(lines):
    print("task-runner: " + "\n".join(lines), file=sys.stderr)
    sys.exit(2)


# --- the contract the model has to answer in, and the check that does not trust it ---

REPORT = re.compile(
    r"<task-runner-report[^>]*>(.*?)</task-runner-report>", re.S | re.I)
FIELD = re.compile(r"^\s*(finished|remainder|blockers|holes)\s*:\s*(.+?)\s*$", re.I | re.M)


def whatTheModelSaid(event):
    """The report block out of the last thing the model wrote, or nothing.

    Chris, 13 September 2026: *"perhaps we need claude to output in its verification text a simple
    set of flags that we can mechanically search for... if we get the impression issues should have
    been created, but none were, we know that claude has failed to complete the contract."*

    The Stop event carries the path to the transcript, so the turn's own words are readable from
    here. That is the difference between a hook that ASKS and a hook that CHECKS — everything this
    file did before now was an instruction the model could simply not follow, and nothing would know.
    """
    path = event.get("transcript_path")
    if not path or not Path(path).exists():
        # no transcript to read is NOT a missing report. Complaining here would accuse the model of
        # omitting something it did write, every turn, for ever — a loop that cannot be got out of
        # by doing the right thing, which is the worst kind there is
        return "unreadable"
    last = ""
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("type") != "assistant":
            continue
        for part in (row.get("message") or {}).get("content") or []:
            if isinstance(part, dict) and part.get("type") == "text":
                last = part.get("text", "") or last
    found = REPORT.search(last)
    if not found:
        return None
    said = {k.lower(): v for k, v in FIELD.findall(found.group(1))}
    return said or None


def numbersIn(value):
    """The issue numbers a report line claims, which may be none and may be a lie."""
    return [int(n) for n in re.findall(r"#(\d+)", value or "")]


def brokenPromises(said, store, held):
    """What the report claims against what the tracker actually holds.

    The flag is not the evidence — it is the claim. An unfinished task that filed nothing is the
    case this exists to catch, and a number that was written down but never created is the case it
    catches by accident and is worth catching twice as much.
    """
    wrong = []
    finished = (said.get("finished") or "").strip().lower() in ("yes", "true", "done")
    filed = sum(len(numbersIn(said.get(k))) for k in ("remainder", "blockers", "holes"))
    if not finished and filed == 0:
        wrong.append("you say it is not finished and filed nothing. What is left has to become a"
                     " task or it is work that has been silently skipped.")
    for kind in ("remainder", "blockers", "holes"):
        for number in numbersIn(said.get(kind)):
            if not store.exists(number):
                wrong.append(f"the report names #{number} as a {kind} and no such task exists.")
            elif kind == "remainder" and not store.isChildOf(number, held["id"]):
                # the mistake that was made four times in one afternoon: a remainder filed with
                # `add` rather than `split`, so the rest of a job floats free of the job
                wrong.append(f"#{number} is called the remainder of #{held['id']} and is not a"
                             f" sub-issue of it. Use `task.py split {held['id']}`, not `add`.")
    return wrong


def main():
    try:
        event = json.load(sys.stdin)
    except ValueError:
        sys.exit(0)
    if event.get("stop_hook_active"):
        sys.exit(0)
    store = source()
    tasks = store.tasks()
    if not tasks:
        STATE.unlink(missing_ok=True)
        sys.exit(0)                          # nothing waiting: this is what done looks like
    state = bookkeeping()
    runs = state.setdefault("runs", {})
    bounces = state.get("bounces", 0)
    if bounces >= MAX_BOUNCES:
        STATE.unlink(missing_ok=True)
        print(f"task-runner: stopping after {bounces} turns; work remains on the list.", file=sys.stderr)
        sys.exit(0)

    def run(task):
        return runs.setdefault(str(task["id"]), {})

    held = next((t for t in tasks if run(t).get("handed")), None)

    # ---- guard one: the task in hand has to be answered for before anything advances ----
    #
    # The check runs BEFORE the question rather than after it. Asking "is this finished" and then
    # contradicting the answer a turn later is a worse conversation than asking a question that
    # already knows: a failing check turns "is it done?" into "it is not done, what is left?", which
    # is the question actually worth asking.
    # how many times this one has come round unfinished. One is ordinary; two says the task is
    # bigger or vaguer than a turn, which is the moment to break it up rather than try harder
    if held is not None:
        run(held)["attempts"] = run(held).get("attempts", 0) + 1

    if held is not None and not run(held).get("asked"):
        check = held.get("check")
        verdict, why = (passes(check) if check else (None, ""))
        run(held)["asked"] = now()
        state["bounces"] = bounces + 1
        keep(state)

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
            f"Task {held['id']} ({store.label}) is in hand and this turn is over. "
            "Before anything else moves:",
            "",
            f"    {held['what']}",
            "",
        ] + evidence + comingRoundAgain(run(held).get("attempts", 1)) + [
            "",
            "Answer in the file, not in prose.",
            "",
            "  - Finished: mark it `\"done\"` with a timestamp.",
            "  - Not finished: add the remaining work as new tasks INSERTED DIRECTLY BELOW this one,"
            " so the next guard picks up the rest of this same job while it is still in your head."
            " Then mark this one done.",
            "",
            "  - EITHER WAY, file what the work turned up. A task that finished green still found"
            " things, and they are gone the moment this turn ends: you are the only one who saw"
            " them, and nobody reading the diff later will know they were ever noticed. Three kinds,"
            " and they take three different shapes because they are three different facts:",
            "      * REMAINDER — what is left of THIS job. A sub-issue of it, inserted below, as"
            " above.",
            "      * BLOCKER — a thing that has to happen before this can, found by trying. Its own"
            " task, with this one recorded as blocked by it. Not a child: it is not part of this"
            " job, it is in front of it.",
            "      * HOLE — something wrong or missing NEXT DOOR, found while reading. Nothing to do"
            " with this task and no relation to it. Its own task, on its own.",
            "    A hole you mention in prose and do not file is a hole you found and threw away."
            " Write down what you saw, where, and why it matters — enough that somebody who was not"
            " here can pick it up cold.",
            "  - You tried and could not: that is `needs-respec`, and the label is the small part."
            " Comment with the ATTEMPT — what you actually did, what happened, where it stopped, and"
            " your best guess at what the task does not say. Do not rewrite the task yourself: you"
            " are the one who could not read it, so your version is likely wrong the same way. A"
            " person respecifies it from your account, which is why the account is the deliverable.",
            "    Other reasons it cannot go on, all of which LEAVE IT OPEN: `needs-hands` where it"
            " wants a person's device, eye or judgement; `cant-fix` where it is blocked on something"
            " outside this repository. You being unable to do a thing is not a decision that nobody"
            " should. Only close — reason `not planned` — when it should not be done by anybody at"
            " all, and say why.",
            "",
            "Do not leave it unanswered. Work that is skipped silently is the thing this exists to"
            " prevent; work that is written down as outstanding is fine.",
            "",
            "AND END YOUR REPLY WITH THIS BLOCK, exactly, filled in. It is read mechanically and"
            " checked against the tracker — a number you name here that does not exist is caught,"
            " and so is saying the job is unfinished while filing nothing:",
            "",
            f"    <task-runner-report task=\"{held['id']}\">",
            "    finished: yes|no",
            "    remainder: #<id> ... | none",
            "    blockers: #<id> ... | none",
            "    holes: #<id> ... | none",
            "    </task-runner-report>",
        ])

    # ---- did the model answer in the shape it was asked to? ----
    if held is not None and run(held).get("asked"):
        said = whatTheModelSaid(event)
        if said == "unreadable":
            said = None                      # cannot check this turn; fall through and take the word
        elif said is None:
            keep(state)
            say([
                f"Task {held['id']} was asked for and the report block is missing.",
                "",
                "It is read mechanically, so it has to be there and it has to be the last thing in"
                " your reply. Answer the question above, then end with:",
                "",
                f"    <task-runner-report task=\"{held['id']}\">",
                "    finished: yes|no",
                "    remainder: #<id> ... | none",
                "    blockers: #<id> ... | none",
                "    holes: #<id> ... | none",
                "    </task-runner-report>",
            ])
        wrong = brokenPromises(said, store, held) if said else []
        if wrong:
            keep(state)
            say([f"Task {held['id']}: the report does not hold up."] + [f"  - {w}" for w in wrong]
                + ["", "File what is missing, then report again."])

    # ---- the task in hand has been answered for: settle it ----
    if held is not None:
        check = held.get("check")
        if check:
            ok, why = passes(check)
            if ok:
                store.mark_done(held, now())
            else:
                state["bounces"] = bounces + 1
                keep(state)
                say([
                    f"Task {held['id']} is not done: `{check}` still fails.",
                    f"    {why}" if why else "",
                    "",
                    "Either finish it, or split what is left into tasks below this one and say which"
                    " part is blocked and on what.",
                ] + comingRoundAgain(run(held).get("attempts", 1)))
        else:
            # no check: the model's word, and the store says so where a reader will see it
            store.mark_done(held, now(), verified=False)

    waiting = store.tasks(after=held["id"] if held else None)
    workable = [t for t in waiting if not t.get("waiting_on")]
    following = next((t for t in workable if not run(t).get("handed") or t is held), None)
    if following is None and waiting:
        # everything left is waiting on something that is itself still open, which is a fact worth
        # saying rather than a silent stop: it means the queue is ordered wrongly or a blocker is stuck
        blocked = ", ".join(f"#{t['id']} waits on {t['waiting_on']}" for t in waiting[:5])
        print(f"task-runner: nothing workable — every remaining task is blocked ({blocked}).",
              file=sys.stderr)
        sys.exit(0)
    if following is None:
        STATE.unlink(missing_ok=True)
        sys.exit(0)                                  # the list is empty: this is what done looks like

    # ---- guard two: hand over the first unfinished task ----
    run(following)["handed"] = now()
    run(following)["at"] = head()
    state["bounces"] = bounces + 1
    keep(state)

    left = len(store.tasks())
    lines = [f"Next task ({following['id']}), {left} outstanding:", "", f"    {following['what']}"]
    if following.get("check"):
        lines += ["", f"Done when this passes: {following['check']}"]

    # and everything written on it since, which is where the answers to anything it asked will be
    said = store.said(following)
    if said:
        lines += ["", f"--- {len(said)} comment(s) on this task, oldest first. READ THEM BEFORE"
                  " STARTING: a task that stopped for an answer has the answer here, and a task"
                  " that did not may still have been argued about since it was written. ---"]
        for note in said:
            when = (note["when"] or "")[:10]
            lines += ["", f"  [{when}] {note['by']}:", ""]
            lines += [f"    {line}" for line in note["what"].splitlines()]
    say(lines)


# importable, so the contract above can be tested without a Stop event to feed it. This file ran
# `main()` at import and a test that merely loaded it hung on stdin for ever — the same fault
# `release.ts` had this morning, found the same way and worth writing down twice.
if __name__ == "__main__":
    main()
