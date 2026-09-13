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
# how a remainder issue says which job it came out of, so the loop can take it next
SPLIT_OF = re.compile(r"Split out of #(\d+)")
LABEL = os.environ.get("TASK_LABEL", "task-runner")
# a check that was seen to fail when the task was written is a different object from one that was
# not, and a label is the only thing on an issue that is visible at a glance and queryable
RED_LABEL = os.environ.get("TASK_RED_LABEL", "check-was-red")


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

    def mark_done(self, task, when, verified=True):
        data = self._read()
        for t in data.get("tasks", []):
            if t.get("id") == task["id"]:
                t["done"] = when
                if not verified:
                    t["unverified"] = True
        self._write(data)

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

        Nothing needs an ordering field to fix it. Remainder issues say `Split out of #5` in their
        body — the hook writes it and a reader wants it there anyway — so an issue that came out of
        the task just finished goes to the front. Depth-first, expressed in the only thing issues
        have, which is words.
        """
        done = self._gh("issue", "list", "--label", LABEL, "--state", "open",
                        "--limit", "200", "--json", "number,title,body,author,labels")
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
                "split_of": SPLIT_OF.search(body).group(1) if SPLIT_OF.search(body) else None,
                "done": None,
            })
        if after is not None:
            out.sort(key=lambda t: (t.get("split_of") != str(after), t["id"]))
        return out

    def mark_done(self, task, when, verified=True):
        """Closing it is done. The comment says on what evidence, because that is the part a reader
        will want and the part a state cannot carry."""
        why = (f"Closed by the task-runner at {when}: its check passed — `{task.get('check')}`."
               if verified and task.get("check") else
               f"Closed by the task-runner at {when} **without a check**. Nothing verified this but "
               "the model's own word; there was no mechanical condition to test it against.")
        self._gh("issue", "close", str(task["id"]), "--comment", why)

    def insert_after(self, task, what, check=None):
        """A new issue, cross-referenced to the one it came out of.

        Issues cannot be reordered, so "below" is expressed the way issues express
        everything — in words, and by number. The next one handed out is the lowest
        open number, so remainder work opened now lands *after* its parent and before
        anything anybody opens later, which is the behaviour the file gives by position.
        """
        body = f"Split out of #{task['id']}, which could not be finished in one turn.\n\n{what}\n"
        if check:
            body += f"\n<!-- check: {check} -->\n"
        labels = [LABEL] + ([RED_LABEL] if check else [])
        self._gh("issue", "create", "--label", ",".join(labels),
                 "--title", what.split("\n")[0][:120], "--body", body)


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
