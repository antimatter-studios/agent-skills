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
from pathlib import Path

CHECK_IN_BODY = re.compile(r"<!--\s*check:\s*(.+?)\s*-->", re.S)
LABEL = os.environ.get("TASK_LABEL", "task-runner")


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

    def tasks(self):
        return [t for t in self._read().get("tasks", []) if not t.get("done")]

    def mark_done(self, task, when):
        data = self._read()
        for t in data.get("tasks", []):
            if t.get("id") == task["id"]:
                t["done"] = when
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

    def tasks(self):
        done = self._gh("issue", "list", "--label", LABEL, "--state", "open",
                        "--limit", "200", "--json", "number,title,body")
        if done.returncode != 0:
            return []
        out = []
        for issue in sorted(json.loads(done.stdout or "[]"), key=lambda i: i["number"]):
            body = issue.get("body") or ""
            found = CHECK_IN_BODY.search(body)
            out.append({
                "id": issue["number"],
                "what": (issue["title"] + "\n\n" + CHECK_IN_BODY.sub("", body).strip()).strip(),
                "check": found.group(1).strip() if found else None,
                "by": "user",
                "done": None,
            })
        return out

    def mark_done(self, task, when):
        self._gh("issue", "close", str(task["id"]),
                 "--comment", f"Done: the task-runner's check passed at {when}.")

    def insert_after(self, task, what, check=None):
        """A new issue, cross-referenced to the one it came out of.

        Issues cannot be reordered, so "below" is expressed the way issues express
        everything — in words, and by number. The next one handed out is the lowest
        open number, so remainder work opened now lands *after* its parent and before
        anything anybody opens later, which is the behaviour the file gives by position.
        """
        body = f"Split out of #{task['id']}, which could not be finished in one turn.\n"
        if check:
            body += f"\n<!-- check: {check} -->\n"
        self._gh("issue", "create", "--label", LABEL,
                 "--title", what.split("\n")[0][:120], "--body", body)


def canReachGitHub():
    """Is there a repository with issues, and are we logged in to reach it?"""
    try:
        gone = subprocess.run(["gh", "repo", "view", "--json", "name"],
                              capture_output=True, text=True, timeout=20)
        return gone.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def source():
    """Whichever store this repository is using. Issues where there are issues to be had.

    Chris, 2026-09-13, on being told the file is faster: "I think perhaps it's better to use github
    issues and be a tiny bit slower, than it is to create an opaque task list that only exists on my
    computer and can't be shared and gives me no public information about things that are filed for
    the project as tasks and stores them for free whilst also allowing others to add their own
    ideas."

    That settles it, and the half second was never the point. A queue only one machine can see is
    worse than a queue anybody can read, comment on and add to — and the storage is somebody else's
    problem. So issues are the default wherever they can be reached, and the file is what happens
    when they cannot: no `gh`, not logged in, no network, or a repository with no remote at all. The
    loop keeps working on a train; it just keeps working somewhere only that train can see.

    `TASK_SOURCE=file` forces the file for anybody who wants it, and `TASK_SOURCE=github` forces the
    other way so a misconfigured machine fails loudly rather than quietly writing a private list.
    """
    want = os.environ.get("TASK_SOURCE", "").lower()
    if want in ("file", "json", "local"):
        return FileTasks(os.environ.get("TASK_LIST", ".task-list.json"))
    if want in ("github", "issues", "gh"):
        return IssueTasks(os.environ.get("TASK_REPO"))
    return IssueTasks(None) if canReachGitHub() else FileTasks(
        os.environ.get("TASK_LIST", ".task-list.json"))
