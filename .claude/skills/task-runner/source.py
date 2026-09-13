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

CHECK_IN_BODY = re.compile(r"<!--\s*check:\s*(.+?)\s*-->", re.S)
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
STUCK_LABELS = {l.strip() for l in os.environ.get(
    "TASK_STUCK_LABELS", "cant-fix,wont-fix,blocked,needs-respec").split(",") if l.strip()}


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
        return out                            # position is the order; insert_after already placed it

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
        tasks.insert(at, {
            "id": max((t.get("id", 0) for t in tasks), default=0) + 1,
            "what": what, "by": "model", "check": check, "done": None,
        })
        self._write(data)


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
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60, **kw)

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
        done = self._gh("issue", "list", "--label", LABEL, "--state", "open",
                        "--limit", "200", "--json", "number,title,body,author,labels,parent,blockedBy")
        if done.returncode != 0:
            print(f"task-runner: cannot reach the issues on this repository — {done.stderr.strip()}",
                  file=sys.stderr)
            return []
        out = []
        for issue in sorted(json.loads(done.stdout or "[]"), key=lambda i: i["number"]):
            body = issue.get("body") or ""
            found = CHECK_IN_BODY.search(body)
            out.append({
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
                "blocked_by": sorted({i["number"] for i in (issue.get("blockedBy") or {}).get("nodes", [])}
                                     | {int(n) for n in BLOCKED_BY.findall(body)}),
                "done": None,
            })
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
        will want and the part a state cannot carry."""
        why = (f"Closed by the task-runner at {when}: its check passed — `{task.get('check')}`."
               if verified and task.get("check") else
               f"Closed by the task-runner at {when} **without a check**. Nothing verified this but "
               "the model's own word; there was no mechanical condition to test it against.")
        self._gh("issue", "close", str(task["id"]), "--comment", why)

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
        made = self._gh("issue", "create", "--label", ",".join(labels),
                        "--title", what.split("\n")[0][:120], "--body", body)
        if made.returncode != 0:
            return
        born = re.search(r"/issues/(\d+)", made.stdout or "")
        if not born:
            return
        self._adopt(task["id"], int(born.group(1)))

    def _adopt(self, parent, child):
        """Make one issue the child of another, by node id, which is what the mutation wants."""
        # `gh issue view --json id` gives the node id without this having to know owner or name
        ids = {}
        for number in (parent, child):
            got = self._gh("issue", "view", str(number), "--json", "id")
            if got.returncode != 0:
                return
            ids[number] = json.loads(got.stdout)["id"]
        self._gh("api", "graphql", "-f", "query=mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){clientMutationId}}",
                 "-f", f"p={ids[parent]}", "-f", f"c={ids[child]}")


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
        remotes = subprocess.run(["git", "remote", "-v"], capture_output=True, text=True, timeout=10)
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
    return IssueTasks(None) if isGitHub() else FileTasks(
        os.environ.get("TASK_LIST", ".task-list.json"))
