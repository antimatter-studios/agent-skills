#!/usr/bin/env bash
# Tests for the report the model has to end a verification turn with.
#
#   tests/report.sh
#
# The flags are CLAIMS, not evidence. What makes them worth having is that the hook checks them
# against the tracker: an unfinished task that filed nothing is caught, a number named that does
# not exist is caught, and a remainder that is not actually a sub-issue is caught — that last one
# being the mistake made four times in a single afternoon before any of this existed.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
check() {
  local what="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$what"; else printf 'FAIL %s\n' "$what"; fails=$((fails+1)); fi
}
run() { python3 -c "$1" "$here"; }

check "working on it and filing nothing is fine, because the job is not handed back" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return True
    def isChildOf(self, n, p): return True
wrong = hook.brokenPromises({"status": "working", "did": "wrote the failing test", "filed": "none"},
                            Store(), {"id": 13})
if wrong:
    print("objected to a turn spent halfway through a job:", wrong)
    sys.exit(1)
'

check "handing it back stopped, with nothing filed, is a failure" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return True
    def isChildOf(self, n, p): return True
wrong = hook.brokenPromises({"status": "needs-feedback", "did": "hit a fork", "filed": "none"},
                            Store(), {"id": 13})
if not wrong:
    print("a reason that exists only in this turn was accepted")
    sys.exit(1)
'

check "a turn that says nothing about what it did is a failure" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return True
    def isChildOf(self, n, p): return True
wrong = hook.brokenPromises({"status": "working", "filed": "none"}, Store(), {"id": 13})
if not any("did" in w for w in wrong):
    print("a turn ended with no record of what happened in it")
    sys.exit(1)
'

check "finished must say filed-none outright rather than leaving it blank" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return True
    def isChildOf(self, n, p): return True
if not hook.brokenPromises({"status": "finished", "did": "shipped it", "filed": ""}, Store(), {"id": 13}):
    print("an unanswered line read as an answer")
    sys.exit(1)
if hook.brokenPromises({"status": "finished", "did": "shipped it", "filed": "none"}, Store(), {"id": 13}):
    print("saying none outright was rejected")
    sys.exit(1)
'

check "an unfinished task that filed nothing is a failure" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return True
    def isChildOf(self, n, p): return True
wrong = hook.brokenPromises({"status": "needs-respec", "did": "tried and could not",
                             "filed": "none"}, Store(), {"id": 13})
if not wrong:
    print("it said unfinished and filed nothing, and nothing objected")
    sys.exit(1)
'

check "an unfinished task that filed two is fine" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return True
    def isChildOf(self, n, p): return True
wrong = hook.brokenPromises({"status": "finished", "did": "split it", "remainder": "#112 #113"}, Store(), {"id": 13})
if wrong:
    print("objected to a turn that did exactly the right thing:", wrong)
    sys.exit(1)
'

check "a finished task that filed nothing is fine" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return True
    def isChildOf(self, n, p): return True
if hook.brokenPromises({"status": "finished", "did": "shipped it", "filed": "none"}, Store(), {"id": 13}):
    print("a job that is actually done has nothing left to file")
    sys.exit(1)
'

check "a number that does not exist is caught" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return False
    def isChildOf(self, n, p): return True
if not hook.brokenPromises({"status": "blocked", "did": "hit a wall", "holes": "#999"}, Store(), {"id": 13}):
    print("it named an issue that was never created and nothing objected")
    sys.exit(1)
'

check "a remainder that is not a sub-issue is caught" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
class Store:
    def exists(self, n): return True
    def isChildOf(self, n, p): return False
wrong = hook.brokenPromises({"status": "finished", "did": "split it", "remainder": "#41"}, Store(), {"id": 13})
if not any("sub-issue" in w for w in wrong):
    print("the rest of a job was left floating free of the job")
    sys.exit(1)
'

check "no transcript is not a missing report" run '
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
# a loop that cannot be escaped by doing the right thing is the worst kind there is
if hook.whatTheModelSaid({}) != "unreadable":
    print("it would accuse the model of omitting a block it cannot read")
    sys.exit(1)
'

check "a task waiting on a person stops being the task in hand" run '
import pathlib, sys
body = (pathlib.Path(sys.argv[1]) / "hook.py").read_text()
# it stayed held for three turns running, so the hook asked about a job nobody could finish while
# entirely different work went past
if "held.get(" + chr(34) + "stuck" + chr(34) + ")" not in body:
    print("a labelled task is still handed back every turn for ever")
    sys.exit(1)
if "held = None" not in body:
    print("it is labelled and still in hand, which is the same loop")
    sys.exit(1)
'

check "a turn that changed nothing and will not say why is refused" run '
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
same = hook.treeState()
record = {"tree": same}
wrong = hook.driftedInsteadOfWorking({"status": "working", "did": "wrote a status summary"}, record)
if not wrong:
    print("a turn spent describing the queue passed as a turn of work")
    sys.exit(1)
'

check "a turn that read or measured is accepted, because that is real and leaves no trace" run '
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
record = {"tree": hook.treeState()}
if hook.driftedInsteadOfWorking({"status": "working", "did": "read homes.ts and measured the gap"}, record):
    print("investigating was called drift")
    sys.exit(1)
'

check "two turns changing nothing is drift whatever it is called" run '
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
record = {"tree": hook.treeState()}
said = {"status": "working", "did": "read the file again"}
hook.driftedInsteadOfWorking(said, record)
wrong = hook.driftedInsteadOfWorking(said, record)
if not any("changed nothing at all" in w for w in wrong):
    print("it read a file twice and nothing objected")
    sys.exit(1)
'

check "a turn that changed something is never drift" run '
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
record = {"tree": "something-else-entirely"}
if hook.driftedInsteadOfWorking({"status": "working", "did": "wrote the failing test"}, record):
    print("real work was called drift")
    sys.exit(1)
'

check "a turn with nothing in git or the tracker to show for it is sent back" run '
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("hook", pathlib.Path(sys.argv[1]) / "hook.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
body = (pathlib.Path(sys.argv[1]) / "hook.py").read_text()
if "evidenceOn(" not in body:
    print("the hook never asks the world whether anything happened")
    sys.exit(1)
if "Nothing exists that ties this turn to task" not in body:
    print("it asks, and does nothing about the answer")
    sys.exit(1)
'

check "the evidence is things that had to be created, not things that were written" run '
import ast, pathlib, sys
src = (pathlib.Path(sys.argv[1]) / "source.py").read_text()
tree = ast.parse(src)
body = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "IssueTasks":
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == "evidenceOn":
                body = ast.get_source_segment(src, item)
if body is None:
    print("IssueTasks cannot say what exists")
    sys.exit(1)
for must in ("git", "log", "state", "labels", "pr"):
    if must not in body:
        print("evidenceOn does not look at " + must)
        sys.exit(1)
if "said" in body or "did" in body.split(chr(34))[0]:
    print("it is reading the report again, which is the thing that did not work")
    sys.exit(1)
'

check "two drivers do not work the same queue" run '
import pathlib, sys
here = pathlib.Path(sys.argv[1])
hook = (here / "hook.py").read_text()
runner = (here / "run.sh").read_text()
if "task-runner.lock" not in hook:
    print("the Stop hook hands out tasks while run.sh is working them")
    sys.exit(1)
if "task-runner.lock" not in runner:
    print("run.sh never says it is driving")
    sys.exit(1)
if "trap" not in runner:
    print("a lock that outlives the run stops the hook for ever")
    sys.exit(1)
'

exit $((fails > 0))
