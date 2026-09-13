#!/usr/bin/env python3
"""Where the work lives: a file, or the repository's own issues.

Chris, 2026-09-13: "we could have a task runner which can run with or without
github — without github we use the .task-list.json file, but with the github
repo, we can use another branch in the python script where it uses the github
issues as a way to represent the same data, but in github issues instead."

Same loop, same questions, two stores. The loop asks a source four things and
does not care which one answered:

    tasks()            what is waiting, in order
    mark_done(task)    it is finished
    insert_after(...)  the remainder of it, next rather than last
    label              what to call the store when speaking to a person

WHICH ONE, AND WHY IT MATTERS WHERE. A `gh` call measures about half a second;
reading a file is about a millisecond. That is the difference between a loop you
can run on every turn end and one you cannot, so the DEFAULT IS THE FILE. Point
it at issues when the list is something other people need to see and discuss, and
accept the half second, the auth, and the fact that it stops working on a train.

HOW A CHECK SURVIVES IN AN ISSUE. Issues have no custom fields — only Projects v2
does — so the check goes in the body as an HTML comment:

    <!-- check: pnpm exec vitest run src/world/purses.test.ts -->

Invisible when rendered, trivial to parse, and it travels with the issue rather
than living in a project somebody has to remember to attach.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

CHECK_IN_BODY = re.compile(r"<!--\s*check:\s*(.+?)\s*-->", re.DOTALL)
# "must happen after", which GitHub does have a native relation for — `addBlockedBy`, and a
# `blockedBy` field on every issue, beside `blocking` and `issueDependenciesSummary`.
#
# This file read a `Blocked by #25` line out of the body for a while, on my assertion that no such
# relation existed. It does, I had looked for sub-issues and then stated a conclusion about
# dependencies without checking, and Chris caught it. The text convention is kept as a *fallback*
# only — an issue somebody wrote by hand still means what it says — but the relation is what is read
# first, because it is structural, it shows in the interface, and it cannot drift from a reword.
#
# Sub-issues remain a different thing and are still used for what they are: containment. Remainder
# work genuinely *is* part of the task it split from; #26 is not part of #25, it merely cannot start
# until #25 is done.
BLOCKED_BY = re.compile(r"[Bb]locked by #(\d+)")
LABEL = os.environ.get("TASK_LABEL", "task-runner")
# a check that was seen to fail when the task was written is a different object from one that was
# not, and a label is the only thing on an issue that is visible at a glance and queryable
RED_LABEL = os.environ.get("TASK_RED_LABEL", "check-was-red")

# Work that cannot be done by whoever is running the loop, and is not waiting on another task.
#
# The first task this queue offered was a phone layout whose remaining half is, in its own words,
# "the part that wants a real thumb on real glass rather than an emulator". Nothing in the tracker
# could say that: `Blocked by #N` covers a task waiting on a task, and this is a task waiting on a
# person with a device. Without a way to say it, the loop hands the same impossible thing back every
# time it comes round, which is how a queue teaches somebody to stop reading it.
HANDS_LABEL = os.environ.get("TASK_HANDS_LABEL", "needs-hands")

# Work somebody has already decided cannot be done, which the loop must stop offering.
#
# Chris, 2026-09-13: "we should update the issues with tags like cant_fix or wont_fix and this will
# mean we can't get stuck on an infinite loop trying to complete tasks we have already determined
# can't be fixed."
#
# Two cases and only one of them is a label. **Won't fix** is a decision, and GitHub closes an issue
# `--reason "not planned"` natively: it leaves the open queue on its own, shows a different icon, and
# needs nothing here at all. That is the right route and the skill says so.
#
# **Can't fix yet** is different: the work is real, it is blocked on something outside the
# repository, and closing it would lose it. It stays open, wears a label, and is skipped — the same
# treatment as `needs-hands`, for the same reason. A queue that hands back a known-impossible task
# every time it comes round is a queue somebody stops reading.
STUCK_LABELS = {
    l.strip()
    for l in os.environ.get(
        "TASK_STUCK_LABELS", "cant-fix,wont-fix,blocked,needs-respec,needs-feedback"
    ).split(",")
    if l.strip()
}


class FileTasks:
    """The default: a JSON file in the repository root, read in about a millisecond."""

    label = ".task-list.json"

    def __init__(self, path):
        self.path = Path(path)

    def _read(self):
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {"tasks": []}

    def _write(self, data):
        self.path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def tasks(self, after=None):
        out = [t for t in self._read().get("tasks", []) if not t.get("done")]
        # position is the order; insert_after already placed it. What a file cannot get from a
        # relation it keeps in a field, and the hook asks the same question of both sources
        still_open = {t.get("id") for t in out}
        for t in out:
            t["waiting_on"] = [n for n in t.get("blocked_by", []) if n in still_open]
        return out

    def exists(self, number):
        """Is there such a task at all? Asked of the store, so a claimed number can be checked."""
        return any(t.get("id") == number for t in self._read().get("tasks", []))

    def isChildOf(self, number, parent):
        """A file has no relations; position is the order, so a remainder below its job is a child."""
        return True

    def add(self, what, check=None, labels=()):
        """A task with no parent: something found next door that belongs to nobody's job."""
        data = self._read()
        tasks = data.setdefault("tasks", [])
        made = max((t.get("id", 0) for t in tasks), default=0) + 1
        tasks.append({"id": made, "what": what, "by": "model", "check": check, "done": None})
        self._write(data)
        return made

    def relabel(self, task, add=(), remove=()):
        """A file has no labels, so the states live in a field of their own."""
        data = self._read()
        for t in data.get("tasks", []):
            if t.get("id") == task["id"]:
                now = set(t.get("labels", [])) | set(add)
                t["labels"] = sorted(now - set(remove))
        self._write(data)

    def reopen(self, task, why=""):
        """Un-finish something that was marked done and should not have been."""
        data = self._read()
        for t in data.get("tasks", []):
            if t.get("id") == task["id"]:
                t["done"] = None
                t.pop("unverified", None)
        self._write(data)

    def unblock(self, task, on):
        """It was not waiting on that after all, or it has stopped."""
        data = self._read()
        for t in data.get("tasks", []):
            if t.get("id") == task["id"] and on in t.get("blocked_by", []):
                t["blocked_by"].remove(on)
        self._write(data)

    def said(self, task):
        """What has been said on this task since it was written.

        A file has no comment thread, so this is empty and honestly so — the whole argument for
        issues over a file is that other people can write on them. Present because the hook asks
        both sources the same question and must not have to know which it is talking to.
        """
        return []

    def block(self, task, on):
        """Record that this task waits on another, which is ordering rather than impossibility.

        A field rather than a sentence in the brief, for the same reason the GitHub source uses the
        relation rather than a `Blocked by #25` line: a reword cannot silently unblock something,
        and the thing that decides what to hand out next reads exactly what was written.
        """
        data = self._read()
        for t in data.get("tasks", []):
            if t.get("id") == task["id"] and on not in t.setdefault("blocked_by", []):
                t["blocked_by"].append(on)
        self._write(data)

    def mark_done(self, task, when, verified=True):
        data = self._read()
        for t in data.get("tasks", []):
            if t.get("id") == task["id"]:
                t["done"] = when
                if not verified:
                    t["unverified"] = True
        self._write(data)

    def say(self, task, what):
        """A file has nowhere to put a comment, and inventing a log beside it would be a second
        record of the same run that nothing reads. The hook prints it either way."""

    def insert_after(self, task, what, check=None):
        data = self._read()
        tasks = data.setdefault("tasks", [])
        at = next((i + 1 for i, t in enumerate(tasks) if t.get("id") == task["id"]), len(tasks))
        tasks.insert(
            at,
            {
                "id": max((t.get("id", 0) for t in tasks), default=0) + 1,
                "what": what,
                "by": "model",
                "check": check,
                "done": None,
            },
        )
        self._write(data)


# What a task has to say before it counts as written down. Short, because the bar is "somebody who
# was not here can pick this up" and not "somebody wrote an essay" — but a title with nothing under
# it is a reminder, not a brief, and the loop would hand it out as though it were one.
ENOUGH_TO_PICK_UP = 80


class IssueTasks:
    """The repository's own issues, for a list other people are meant to see.

    An open issue with the label is a task. Its title and body are `what`; a
    `<!-- check: ... -->` comment in the body is `check`; closing it is done.
    Order is by issue number, which is creation order, which is what a queue is.
    """

    label = "GitHub issues"

    def __init__(self, repo=None):
        self.repo = repo

    def _gh(self, *args, **kw):
        cmd = ["gh", *args]
        if self.repo:
            cmd += ["--repo", self.repo]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60, **kw, check=False)

    def tasks(self, after=None):
        """Open issues, in the order the loop should take them.

        Number order, which is creation order, which is what a queue is — **except** for the one
        thing issue numbers cannot express. Splitting task 5 opens issue 31, and 31 sorts last, so
        the remainder of a job would come back after everything else on the list with all its
        context gone. That is exactly the behaviour "insert below" exists to prevent.

        GitHub has the structure for it natively — `addSubIssue`, and a `parent` on every issue —
        so remainder work is a real **sub-issue** of the job it came out of rather than a sentence
        about one. Children of the task just settled go first, which is depth-first expressed in
        something queryable, visible in the interface, and impossible to get wrong by rewording.
        """
        done = self._gh(
            "issue",
            "list",
            "--label",
            LABEL,
            "--state",
            "open",
            "--limit",
            "200",
            "--json",
            "number,title,body,author,labels,parent,blockedBy",
        )
        if done.returncode != 0:
            print(
                f"task-runner: cannot reach the issues on this repository — {done.stderr.strip()}",
                file=sys.stderr,
            )
            return []
        out = []
        for issue in sorted(json.loads(done.stdout or "[]"), key=lambda i: i["number"]):
            body = issue.get("body") or ""
            found = CHECK_IN_BODY.search(body)
            out.append(
                {
                    "id": issue["number"],
                    "what": (issue["title"] + "\n\n" + CHECK_IN_BODY.sub("", body).strip()).strip(),
                    "check": found.group(1).strip() if found else None,
                    # who asked for it, which GitHub already knows better than we could
                    "by": (issue.get("author") or {}).get("login", "?"),
                    "was_red": any(l["name"] == RED_LABEL for l in issue.get("labels", [])),
                    "needs_hands": any(l["name"] == HANDS_LABEL for l in issue.get("labels", [])),
                    "stuck": sorted({l["name"] for l in issue.get("labels", [])} & STUCK_LABELS),
                    "parent": (issue.get("parent") or {}).get("number"),
                    # the relation first; the written line only for issues nobody linked up
                    "blocked_by": sorted(
                        {i["number"] for i in (issue.get("blockedBy") or {}).get("nodes", [])}
                        | {int(n) for n in BLOCKED_BY.findall(body)}
                    ),
                    "done": None,
                }
            )
        # anything still waiting on an open task is not workable yet, so it is not offered
        open_now = {t["id"] for t in out}
        for t in out:
            t["waiting_on"] = [n for n in t["blocked_by"] if n in open_now]
            if t["needs_hands"]:
                t["waiting_on"] = t["waiting_on"] + ["somebody with hands"]
            if t["stuck"]:
                t["waiting_on"] = t["waiting_on"] + t["stuck"]
        if after is not None:
            out.sort(key=lambda t: (t.get("parent") != after, t["id"]))
        return out

    def say(self, task, what):
        """Write what the check said into the issue, once per distinct thing it said.

        Chris, 2026-09-13: "I guess we should write the output of the verification step into the
        issue comments?" — yes, and it is the part a person actually wants: not that a task failed
        but *what* it said, readable without re-running anything, months later, by somebody who was
        not there.

        Once per distinct failure, though. A loop that bounces forty times against the same broken
        test would post forty identical comments and turn the issue into a wall nobody reads, which
        is the same way a warning that fires every run stops being a warning. The last thing said is
        kept beside the run's own bookkeeping, and an identical one is simply not posted again.
        """
        seen = Path(".git/task-runner-said.json")
        try:
            already = json.loads(seen.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            already = {}
        if already.get(str(task["id"])) == what:
            return
        already[str(task["id"])] = what
        try:
            seen.write_text(json.dumps(already, indent=2) + "\n", encoding="utf-8")
        except OSError:
            pass
        self._gh("issue", "comment", str(task["id"]), "--body", what)

    def mark_done(self, task, when, verified=True):
        """Closing it is done. The comment says on what evidence, because that is the part a reader
        will want and the part a state cannot carry.

        Except where the task is waiting for a person, and then it is emphatically not done.

        This closed #5 on 13 September 2026 minutes after it had been labelled `needs-feedback` and
        commented with the exact fork a person had to choose. Every label in `STUCK_LABELS` is
        documented as LEAVING THE ISSUE OPEN — that is the whole difference between "the model
        cannot do this" and "nobody should" — and then the no-check path closed it anyway on the
        model's own word. Two halves of this runner disagreeing about one fact, which is the fault
        it exists to catch, found in it.

        The label wins, because the label is the more recent and more specific statement: a task
        gets one at the moment somebody works out it cannot go on, and a close is what happens by
        default when nothing else does.
        """
        stuck = sorted({l["name"] for l in self._labels(task["id"])} & STUCK_LABELS)
        if stuck:
            print(f"task-runner: #{task['id']} stays open — {', '.join(stuck)}", file=sys.stderr)
            return
        why = (
            f"Closed by the task-runner at {when}: its check passed — `{task.get('check')}`."
            if verified and task.get("check")
            else f"Closed by the task-runner at {when} **without a check**. Nothing verified this but "
            "the model's own word; there was no mechanical condition to test it against."
        )
        self._gh("issue", "close", str(task["id"]), "--comment", why)

    def _labels(self, issue):
        """What this issue is labelled right now, asked again rather than remembered.

        The task in hand was read at the start of the turn and the label that stops it is put on
        during the turn, so a cached answer is the answer from before the thing happened.
        """
        got = self._gh("issue", "view", str(issue), "--json", "labels")
        return json.loads(got.stdout or "{}").get("labels", []) if got.returncode == 0 else []

    def insert_after(self, task, what, check=None):
        """A new issue, made a real child of the one it came out of.

        Not a sentence saying so: `addSubIssue` is a mutation, `parent` is a field, and the
        relationship shows up in the interface for whoever is reading rather than only in a regex
        the hook happens to run. The loop takes children of the task it just settled before anything
        else, which is what "insert below" meant in the file.
        """
        body = f"{what}\n"
        if check:
            body += f"\n<!-- check: {check} -->\n"
        labels = [LABEL] + ([RED_LABEL] if check else [])
        made = self._gh(
            "issue",
            "create",
            "--label",
            ",".join(labels),
            "--title",
            what.split("\n")[0][:120],
            "--body",
            body,
        )
        if made.returncode != 0:
            return
        born = re.search(r"/issues/(\d+)", made.stdout or "")
        if not born:
            return
        self._adopt(task["id"], int(born.group(1)))

    def exists(self, number):
        """Is there such an issue at all?

        The point of the report is that its flags are CLAIMS, and a claim nobody checks is worth
        exactly what an instruction nobody checks is worth — which this runner has already learned
        once. Open or closed both count: a task filed and immediately finished is still a task that
        was filed.
        """
        got = self._gh("issue", "view", str(number), "--json", "number,title,body")
        if got.returncode != 0:
            return False
        issue = json.loads(got.stdout or "{}")
        # and not empty, which is the other half of the claim. A task filed as a title and nothing
        # else satisfies "an issue exists" and is useless to whoever picks it up months later with
        # none of the context that made it obvious — so it does not count as having been filed
        return len((issue.get("body") or "").strip()) >= ENOUGH_TO_PICK_UP

    def evidenceOn(self, number, since):
        """What exists in git or GitHub, tied to this task, that was not there when it was handed out.

        Not a report. Not a status. Not a sentence anybody wrote about their own turn — facts that
        had to be *created*, and that a person can go and look at afterwards:

          - a commit since hand-out whose message names the issue
          - a pull request that references it
          - the issue closed
          - the issue labelled with a state that stops it
          - a sub-issue of it that did not exist before

        Every previous check in this runner asked the model to describe its own turn and then
        checked the description was well formed. This asks the world instead. It cannot be answered
        by writing anything.
        """
        found = []
        # Uncommitted work counts, and leaving it out was the fault that made the first real run
        # useless: three attempts each wrote a test file and sixty lines of source, and every one
        # was reported as having left nothing, because nothing had been *committed* yet. A turn that
        # writes a failing test and stops has done the most valuable part of the job.
        dirt = subprocess.run(
            ["git", "status", "--porcelain"], capture_output=True, text=True, check=False
        ).stdout.strip()
        if dirt:
            found.append(f"{len(dirt.splitlines())} file(s) changed and not yet committed")
        try:
            log = subprocess.run(
                ["git", "log", f"{since}..HEAD", "--format=%h %s"],
                capture_output=True,
                text=True,
                check=False,
            )
            for line in (log.stdout or "").splitlines():
                if f"#{number}" in line:
                    found.append(f"commit {line.split(' ')[0]}")
        except FileNotFoundError:
            pass

        got = self._gh("issue", "view", str(number), "--json", "state,labels")
        if got.returncode == 0:
            issue = json.loads(got.stdout or "{}")
            if issue.get("state") != "OPEN":
                found.append("the issue is closed")
            stuck = {l["name"] for l in issue.get("labels", [])} & STUCK_LABELS
            if stuck:
                found.append(f"labelled {', '.join(sorted(stuck))}")

        prs = self._gh(
            "pr", "list", "--state", "all", "--limit", "20", "--json", "number,title,body"
        )
        if prs.returncode == 0:
            for pr in json.loads(prs.stdout or "[]"):
                if f"#{number}" in (pr.get("title", "") + pr.get("body", "") or ""):
                    found.append(f"pull request #{pr['number']}")
                    break

        # a sub-issue filed against it, which is the remainder case and the commonest honest
        # outcome of a turn: the work was split rather than finished
        sub = self._gh(
            "issue",
            "list",
            "--search",
            f"parent-issue:{number}",
            "--state",
            "all",
            "--limit",
            "5",
            "--json",
            "number",
        )
        if sub.returncode == 0 and json.loads(sub.stdout or "[]"):
            found.append("a sub-issue of it exists")

        return found

    def isChildOf(self, number, parent):
        """Is this issue actually a sub-issue of that one, as GitHub records it?

        Asked of the relation rather than of the report, because the report is the claim. A
        remainder that is not a child is the rest of a job floating free of the job — it sorts by
        number instead of coming next, so the context it was split out of is gone by the time
        anybody reaches it.
        """
        got = self._gh("issue", "view", str(number), "--json", "parent")
        if got.returncode != 0:
            return False
        held = (json.loads(got.stdout or "{}").get("parent") or {}).get("number")
        return held == parent

    def add(self, what, check=None, labels=()):
        """A task with no parent: a hole found next door, which belongs to nobody's job.

        `insert_after` is for the REMAINDER of a job and makes a sub-issue. This is the other case,
        and they must not be the same call: a hole filed as somebody's child claims a relationship
        that does not exist, and the loop takes children first — so an unrelated task would jump the
        queue on the strength of a wrong parent.
        """
        body = what + ("" if not check else f"\n\n<!-- check: {check} -->\n")
        names = [LABEL] + ([RED_LABEL] if check else []) + list(labels)
        made = self._gh(
            "issue",
            "create",
            "--label",
            ",".join(names),
            "--title",
            what.split("\n")[0][:120],
            "--body",
            body,
        )
        if made.returncode != 0:
            return None
        born = re.search(r"/issues/(\d+)", made.stdout or "")
        return int(born.group(1)) if born else None

    def relabel(self, task, add=(), remove=()):
        """Put a state on a task or take one off. See STUCK_LABELS for what they mean."""
        args = ["issue", "edit", str(task["id"])]
        for name in add:
            args += ["--add-label", name]
        for name in remove:
            args += ["--remove-label", name]
        if len(args) > 3:
            self._gh(*args)

    def reopen(self, task, why=""):
        """Un-close something that should not have been closed, saying why on the issue itself.

        Needed the day `mark_done` closed a task that was labelled for a person to answer. A reopen
        with no reason on it is a state change nobody can account for six months later.
        """
        args = ["issue", "reopen", str(task["id"])]
        if why:
            args += ["--comment", why]
        self._gh(*args)

    def unblock(self, task, on):
        """It was not waiting on that after all.

        Needed within an hour of `block` existing, because the first thing anybody does with a
        relation is get one backwards — a remainder was recorded as blocked by the item it is the
        remainder OF, which is the dependency upside down. Without this the fix was a hand-written
        mutation, which is the thing this vocabulary exists to stop.
        """
        ids = {}
        for number in (task["id"], on):
            got = self._gh("issue", "view", str(number), "--json", "id")
            if got.returncode != 0:
                return
            ids[number] = json.loads(got.stdout)["id"]
        self._gh(
            "api",
            "graphql",
            "-f",
            "query=mutation($i:ID!,$b:ID!){removeBlockedBy(input:{issueId:$i,blockingIssueId:$b}){clientMutationId}}",
            "-f",
            f"i={ids[task['id']]}",
            "-f",
            f"b={ids[on]}",
        )

    def said(self, task):
        """Everything written on this task since, oldest first.

        Chris, 2026-09-13: *"if we find that label, we read not just the issue, but all the comments
        too as a list of things in time based order, so claude can understand the full context"*.

        Asked of every task handed out rather than only the labelled ones, and that is deliberately
        wider than asked for. A label says why the model stopped; it does not say whether anybody has
        since written the answer. Gate on the label and the one case that gets missed is exactly the
        one that matters — somebody replying on a ticket nobody marked.

        It is also the hole this closes on the runner's own side: `say()` and `mark_done` have always
        WRITTEN comments, and nothing has ever read one back. A record you only write to is a record
        that is not part of the conversation.

        One call, and only for the task about to be handed over. The list fetch cannot carry comments
        and fetching them for the whole queue would be one call per issue for answers nobody is going
        to read this turn.
        """
        got = self._gh("issue", "view", str(task["id"]), "--json", "comments")
        if got.returncode != 0:
            return []
        out = []
        for c in json.loads(got.stdout or "{}").get("comments", []):
            who = (c.get("author") or {}).get("login", "?")
            out.append(
                {"by": who, "when": c.get("createdAt", ""), "what": (c.get("body") or "").strip()}
            )
        return out

    def block(self, task, on):
        """Record that this task waits on another, with the relation GitHub already has.

        The read side of this has been here since the day the mistake about it was corrected —
        `blockedBy` is queried on every issue and a blocked task is not offered. The write side was
        not, so the only way a blocker got recorded was a person adding it in the interface, or a
        `Blocked by #25` line in the body that a reword could quietly undo. A relation the loop
        obeys and cannot create is a relation that mostly does not exist.
        """
        ids = {}
        for number in (task["id"], on):
            got = self._gh("issue", "view", str(number), "--json", "id")
            if got.returncode != 0:
                return
            ids[number] = json.loads(got.stdout)["id"]
        self._gh(
            "api",
            "graphql",
            "-f",
            "query=mutation($i:ID!,$b:ID!){addBlockedBy(input:{issueId:$i,blockingIssueId:$b}){clientMutationId}}",
            "-f",
            f"i={ids[task['id']]}",
            "-f",
            f"b={ids[on]}",
        )

    def _adopt(self, parent, child):
        """Make one issue the child of another, by node id, which is what the mutation wants."""
        # `gh issue view --json id` gives the node id without this having to know owner or name
        ids = {}
        for number in (parent, child):
            got = self._gh("issue", "view", str(number), "--json", "id")
            if got.returncode != 0:
                return
            ids[number] = json.loads(got.stdout)["id"]
        self._gh(
            "api",
            "graphql",
            "-f",
            "query=mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){clientMutationId}}",
            "-f",
            f"p={ids[parent]}",
            "-f",
            f"c={ids[child]}",
        )


def isGitHub():
    """Does this repository live on GitHub? Asked of the remote, not of the network.

    Chris, 2026-09-13: "perhaps we can detect IS_GITHUB based on whether the remote has github.com
    in it? and if yes, we use github issues as a task source, otherwise we use our own
    .task-list.json file instead."

    Better than the first version, which asked `gh repo view` and so needed auth and a network to
    answer. That fails the wrong way: on a GitHub repository with `gh` logged out it would decide
    there was no GitHub and quietly start a private list beside a public issue tracker — the exact
    mistake this is meant to prevent.

    A remote URL is a statement of intent, it is instant, and it is true on a train. So the remote
    decides *which* store, and if `gh` then cannot be reached that is an error worth saying out loud
    rather than a reason to go quiet and local.
    """
    try:
        remotes = subprocess.run(
            ["git", "remote", "-v"], capture_output=True, text=True, timeout=10, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return "github.com" in remotes.stdout


def source():
    """Whichever store this repository is using. Issues where there are issues to be had.

    Chris, 2026-09-13, on being told the file is faster: "I think perhaps it's better to use github
    issues and be a tiny bit slower, than it is to create an opaque task list that only exists on my
    computer and can't be shared and gives me no public information about things that are filed for
    the project as tasks and stores them for free whilst also allowing others to add their own
    ideas."

    That settles it, and the half second was never the point. A queue only one machine can see is
    worse than a queue anybody can read, comment on and add to — and the storage is somebody else's
    problem. So **the remote decides**: a repository whose remote is on github.com uses its issues,
    and anything else uses the file. Not "whether GitHub answered just now", which would silently
    start a private list beside a public tracker on any machine that happened to be logged out.

    `TASK_SOURCE=file` forces the file for anybody who wants it, and `TASK_SOURCE=github` forces the
    other way so a misconfigured machine fails loudly rather than quietly writing a private list.
    """
    want = os.environ.get("TASK_SOURCE", "").lower()
    if want in ("file", "json", "local"):
        return FileTasks(os.environ.get("TASK_LIST", ".task-list.json"))
    if want in ("github", "issues", "gh"):
        return IssueTasks(os.environ.get("TASK_REPO"))
    return (
        IssueTasks(None)
        if isGitHub()
        else FileTasks(os.environ.get("TASK_LIST", ".task-list.json"))
    )
