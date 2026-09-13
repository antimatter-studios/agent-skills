#!/usr/bin/env bash
# Tests for task-runner's two task sources.
#
#   tests/source.sh
#
# Both sources have to answer the same questions, because the hook does not know which one it is
# talking to. That is exactly the kind of agreement that rots quietly: a method added to the GitHub
# source and forgotten on the file one fails only on a repository nobody is testing on, and a method
# copied from one to the other keeps the body it had in the place it came from.
#
# Two faults found on 13 September 2026 are pinned here. `FileTasks.say` was a copy of the GitHub
# one, calling a `_gh` it does not have, shadowed by a second definition of the same name further
# down — dead, wrong, and reading as authoritative. And `addBlockedBy` was documented as the way to
# record that one task waits on another, with nothing anywhere able to write one.
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0

check() {
  local what="$1"; shift
  if "$@"; then
    printf 'ok   %s\n' "$what"
  else
    printf 'FAIL %s\n' "$what"
    fails=$((fails + 1))
  fi
}

run() { python3 -c "$1" "$here"; }

check "no class defines the same method twice" run '
import ast, pathlib, sys
tree = ast.parse((pathlib.Path(sys.argv[1]) / "source.py").read_text())
bad = []
for node in ast.walk(tree):
    if not isinstance(node, ast.ClassDef):
        continue
    seen = set()
    for item in node.body:
        if isinstance(item, ast.FunctionDef):
            if item.name in seen:
                bad.append(f"{node.name}.{item.name}")
            seen.add(item.name)
if bad:
    print("shadowed, so the first body is dead and wrong:", ", ".join(bad))
    sys.exit(1)
'

check "both sources answer the same questions" run '
import ast, pathlib, sys
tree = ast.parse((pathlib.Path(sys.argv[1]) / "source.py").read_text())
classes = {n.name: {i.name for i in n.body if isinstance(i, ast.FunctionDef)}
           for n in tree.body if isinstance(n, ast.ClassDef)}
wanted = {"tasks", "say", "mark_done", "insert_after", "block"}
for name in ("FileTasks", "IssueTasks"):
    missing = wanted - classes.get(name, set())
    if missing:
        print(f"{name} cannot answer: {sorted(missing)}")
        sys.exit(1)
'

check "a blocker is recorded with the relation, not a sentence" run '
import pathlib, sys
body = (pathlib.Path(sys.argv[1]) / "source.py").read_text()
if "addBlockedBy(input:" not in body:
    print("addBlockedBy is documented and nothing writes one")
    sys.exit(1)
# the field is blockingIssueId. The first version of this said blockedByIssueId, which reads
# correctly, matches the mutation name, and is rejected by the API — a mutation nobody ran once
if "blockingIssueId" not in body:
    print("addBlockedBy takes blockingIssueId; blockedByIssueId is rejected")
    sys.exit(1)
'

check "the file source keeps blockers somewhere the sort can see" run '
import json, pathlib, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
from source import FileTasks
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "list.json"
    path.write_text(json.dumps({"tasks": [
        {"id": 1, "what": "first", "done": None},
        {"id": 2, "what": "second", "done": None},
    ]}))
    source = FileTasks(path)
    source.block(source.tasks()[0], 2)
    waiting = [t for t in source.tasks() if t["id"] == 1][0]
    if waiting.get("waiting_on") != [2]:
        print("blocked task is still being offered:", waiting)
        sys.exit(1)
'

check "a task carries the conversation that has happened on it" run '
import ast, pathlib, sys
tree = ast.parse((pathlib.Path(sys.argv[1]) / "source.py").read_text())
classes = {n.name: {i.name for i in n.body if isinstance(i, ast.FunctionDef)}
           for n in tree.body if isinstance(n, ast.ClassDef)}
for name in ("FileTasks", "IssueTasks"):
    if "said" not in classes.get(name, set()):
        print(f"{name} cannot hand back what has been said on a task")
        sys.exit(1)
'

check "the brief read out includes it" run '
import pathlib, sys
body = (pathlib.Path(sys.argv[1]) / "hook.py").read_text()
if "store.said(" not in body:
    print("the hook hands out a task without the answers written on it")
    sys.exit(1)
'

check "a fork for a person is not the same state as work wanting hands" run '
import pathlib, sys
body = (pathlib.Path(sys.argv[1]) / "source.py").read_text()
if "needs-feedback" not in body:
    print("needs-feedback is not one of the states a task can stop in")
    sys.exit(1)
'

check "a task stopped for a person is never closed behind their back" run '
import ast, pathlib, sys
src = (pathlib.Path(sys.argv[1]) / "source.py").read_text()
tree = ast.parse(src)
body = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "IssueTasks":
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == "mark_done":
                body = ast.get_source_segment(src, item)
if body is None:
    print("IssueTasks has no mark_done")
    sys.exit(1)
if "STUCK_LABELS" not in body and "stuck" not in body:
    print("mark_done closes a task whatever label says it is waiting for somebody")
    sys.exit(1)
'

check "every way of touching the tracker is a command, not a thing to compose" run '
import ast, pathlib, sys
here = pathlib.Path(sys.argv[1])
tree = ast.parse((here / "source.py").read_text())
classes = {n.name: {i.name for i in n.body if isinstance(i, ast.FunctionDef)}
           for n in tree.body if isinstance(n, ast.ClassDef)}
wanted = {"tasks", "said", "add", "insert_after", "block", "label", "done_or_not", "reopen", "say"}
wanted = wanted - {"done_or_not"} | {"mark_done"}
for name in ("FileTasks", "IssueTasks"):
    missing = wanted - classes.get(name, set())
    if missing:
        print(f"{name} cannot: {sorted(missing)}")
        sys.exit(1)
cli = (here / "task.py").read_text()
for verb in ("list", "show", "add", "split", "block", "label", "done", "reopen", "say"):
    if "what == " + chr(34) + verb + chr(34) not in cli:
        print(f"task.py has no {verb} command, so it will be written by hand instead")
        sys.exit(1)
'

check "filing a hole is not the same call as filing a remainder" run '
import ast, pathlib, sys
src = (pathlib.Path(sys.argv[1]) / "source.py").read_text()
tree = ast.parse(src)
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "IssueTasks":
        add = next((i for i in node.body if isinstance(i, ast.FunctionDef) and i.name == "add"), None)
        if add is None:
            print("no add(): a hole would have to be filed as somebody child")
            sys.exit(1)
        body = ast.get_source_segment(src, add)
        if "addSubIssue" in body or "_adopt" in body:
            print("add() makes a child, which claims a relationship that does not exist")
            sys.exit(1)
'

exit $((fails > 0))
