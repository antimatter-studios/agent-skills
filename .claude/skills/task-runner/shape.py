#!/usr/bin/env python3
"""Is the tracker in the shape a reader can follow? Run it; it prints what is wrong and nothing else.

    shape.py

Three things go wrong silently and all three were found by a person reading issues rather than by
anything here:

  - **A parent whose body does not name its children.** The sub-issue relation is real and lives in
    a panel; a reader of the text sees "three smaller things, none fixed" and no way to them. That
    is not a broken link, it is an invisible one.
  - **A dependency written in prose with no relation behind it.** "Blocked by #25" in a body sorts
    nothing and stops nothing. The relation is what takes a task out of the workable queue; the
    sentence is what a reword can quietly undo.
  - **A remainder filed as a blocker, or the reverse.** Containment and ordering are different
    claims. A parent recorded as blocked by its own child is a parent that can never be worked.

None of this checks whether the issues are any good. It checks that what one part of GitHub knows,
the other parts and a human reader know too.
"""

import json
import re
import subprocess
import sys

SAYS = re.compile(
    r"(?:blocked by|blocked on|waits on|waiting on|requires)\s*\**#?(\d+)", re.IGNORECASE
)

QUERY = """query { repository(owner:"%s",name:"%s"){ issues(first:100, states:OPEN){ nodes{
  number title body
  parent { number }
  subIssues(first:20){ nodes{ number } }
  blockedBy(first:20){ nodes{ number } }
} } } }"""


def main():
    where = subprocess.run(
        ["gh", "repo", "view", "--json", "owner,name"], capture_output=True, text=True, check=False
    )
    if where.returncode != 0:
        print("not a GitHub repository", file=sys.stderr)
        return 1
    repo = json.loads(where.stdout)
    got = subprocess.run(
        ["gh", "api", "graphql", "-f", "query=" + QUERY % (repo["owner"]["login"], repo["name"])],
        capture_output=True,
        text=True,
        check=False,
    )
    if got.returncode != 0:
        print(got.stderr.strip(), file=sys.stderr)
        return 1
    issues = json.loads(got.stdout)["data"]["repository"]["issues"]["nodes"]

    wrong = []
    for issue in issues:
        body = issue.get("body") or ""
        kids = [k["number"] for k in issue["subIssues"]["nodes"]]
        waits = [b["number"] for b in issue["blockedBy"]["nodes"]]

        for kid in kids:
            if f"#{kid}" not in body:
                wrong.append(
                    f"#{issue['number']} has sub-issue #{kid} and never names it in the body"
                )
        # only lines about THIS issue: a body that lists its children and says which of them is
        # blocked reads as the parent being blocked, which it is not. The bullet naming a child is
        # the child's business, and this used to report it as a missing relation on the parent
        own = "\n".join(
            line for line in body.splitlines() if not line.lstrip().startswith(("-", "*"))
        )
        for said in {int(n) for n in SAYS.findall(own)} - set(waits):
            wrong.append(f"#{issue['number']} says it waits on #{said} with no blocked-by relation")
        for kid in set(kids) & set(waits):
            wrong.append(
                f"#{issue['number']} is blocked by its own sub-issue #{kid},"
                " so it can never become workable"
            )

    for line in wrong:
        print(line)
    print(
        f"\n{len(wrong)} to fix across {len(issues)} open issues"
        if wrong
        else f"{len(issues)} open issues, all in shape"
    )
    return 1 if wrong else 0


if __name__ == "__main__":
    sys.exit(main())
