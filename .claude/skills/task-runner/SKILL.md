---
name: task-runner
description: Queue work in .task-list.json and install a Stop hook that will not let a turn end while anything on the list is unfinished — it verifies the task in hand, takes any remaining work as new tasks inserted below it, then hands out the next one. Use when the user asks to queue tasks, run a list to completion, or stop the model handing back plans instead of work.
user-invocable: true
---

# Task runner

A list of work in `.task-list.json`, and a Stop hook that will not let a turn end while anything on
it is unfinished. Between them the model keeps going without being prompted again.

It exists because of a specific failure. A model told to work through a list will hand back a plan
and a question — *"here are three candidates, which would you like?"* — and a rule saying otherwise
does not help, because a rule is text in a context window and nothing checks the output against it.
A Stop hook is not text. It runs whether the model likes it or not, and `exit 2` means the turn does
not end.

## What it does not do, first

It cannot tell work from the appearance of work. It makes **stopping hard**; it does not make the
work good. Every claim below should be read against that.

And the sharper version, from the conversation this came out of — Chris, 13 September 2026:

> *"right now you're telling me tasks are done and I'm not reading the code to verify it, I'm just
> play testing it and we're going through it together. So you're already marking your own
> homework."*

Correct, and a `check` does not change it much, because the model usually writes the check too. What
is worth knowing is which evidence has ever actually caught anything.

On the night this was written, a suite of 2,611 passing tests — nearly all of them written by the
model — caught **none** of the four worst faults in the codebase: a chunk-worker leak that stopped
the ground being painted at all, every mountain in the world having a radius of nought, a village
re-lived from its founding dating its farms wrong, and an entire injury system with no caller.

What caught them:

- **benches that are built to fail**, and did, repeatedly — an economy audit and a believability
  bench that went red on three separate features and forced real changes each time
- **a fingerprint of the world**, which caught a generation change within the hour
- **measurement** — counting which way a fallback went, reading a debug line under a screenshot
- **the person**, playtesting, asking questions, and rejecting two designs outright

A test that has never been seen to fail is a test with no evidence behind it. Prefer the kinds of
check that have a record of going red — and the tool enforces that at the point a task is written:
`add.py` **runs the check and refuses it if it already passes**. A check that is green before the
work is a claim wearing the costume of a test, and that is a fact a machine can settle in a second
rather than a matter of good faith.

## Where the findings actually come from

Chris again, on the same night: *"we're basically catching mistakes by play testing it and adding
things that failed to the pile of tasks to complete. That's a sort of verification, but not a strong
one."*

It is the best **discovery** mechanism there is and the worst **guarantee**. It exercises real
combinations nobody enumerated; absence of a finding proves nothing; and a bug found once will come
back and have to be walked into again.

What upgrades it is the conversion: **a playtest finding becomes a red test before it is fixed.**
The discovery is weak, the conversion is permanent. Three faults found by walking the game that
night can no longer come back silently, because each one left a test behind that had been seen to
fail.

And there is a category playtesting structurally cannot reach. Nobody notices that no mountain has a
radius by playing, because the eagles simply are not there — nothing looks wrong, there is no crag
to miss. Nobody notices an injury that never happens. Those are found by *counting*, not walking.

Three jobs, none of them a substitute for the others: playtesting finds combinations, a red test
locks one finding down for ever, and a bench or a sweep finds the things that are absent.

**Which suggests the division of labour that actually holds.** The person does not need to read the
code to say *"the mountain is standing in empty blue"* or *"the pot can never be full"* — and on the
night this was written, observations of exactly that kind produced a worker leak, four separate
gameplay faults, two rejected designs and most of this tool. None of them required knowing the
codebase.

So: **the person finds and describes; the model converts each finding into a red test that cannot
come back.** Build the loop around that, rather than around a verification step nobody will perform.

## The two guards

**Verify.** The turn ends with a task in hand. The hook does not advance. It runs that task's
`check` if it has one, and asks: is this finished, and if not, what is left? The answer must go in
the **file** — either the task is marked `done`, or the remaining work is added as new tasks. The
failure mode changes shape: work is no longer silently skipped, because skipping it now requires an
explicit written claim that it is complete.

**Dispatch.** Next stop, the task is settled, so the first unfinished one is handed over. Remainder
work was **inserted directly below** the task it came from, so the next thing handed out is the rest
of the same job while it is still in mind. Appending would bring it back ninety tasks later with all
the context gone. A stack, not a queue.

## Where the work is kept

**GitHub issues, wherever they can be reached.** Open issues labelled `task-runner` are the queue,
in number order; closing one is done; remainder work is opened as a new issue cross-referenced to
its parent. Issues have no custom fields — only Projects v2 does — so a check travels in the body as
an HTML comment, invisible when rendered and trivial to parse:

    <!-- check: pnpm exec vitest run src/world/purses.test.ts -->

**A JSON file when they cannot be.** No `gh`, not logged in, no network, or a repository with no
remote at all: `.task-list.json` in the root, with a `_description` at the top so anybody who finds
it knows what it is. Commit it. The loop keeps working on a train; it just keeps working somewhere
only that train can see.

`TASK_SOURCE=file` or `TASK_SOURCE=github` forces either, which is worth doing on a shared machine —
forcing `github` makes a misconfigured box fail loudly rather than quietly writing a private list.

Either way, the **run's own bookkeeping** lives in `.git/task-runner.json`: which task was handed
out, when it was asked about, what HEAD was at the time, how many times the loop has bounced. It
changes every turn and belongs to the machine doing the run. Under `.git/`, so it needs no
`.gitignore` entry and is removed when the queue empties.

### Why issues, given a file is faster

A `gh` call measures about half a second against roughly a millisecond for a file. That was the
first argument for the file and it does not survive the actual trade-off — Chris, 13 September 2026:

> *"I think perhaps it's better to use github issues and be a tiny bit slower, than it is to create
> an opaque task list that only exists on my computer and can't be shared and gives me no public
> information about things that are filed for the project as tasks and stores them for free whilst
> also allowing others to add their own ideas."*

Half a second is nothing beside a turn that takes minutes, and nobody pays for the wait. A queue
only one machine can see is a cost paid every day. So the fast thing is the fallback and the
shareable thing is the default.

**And it answers the obvious objection to this whole skill** — that it is GitHub Issues with extra
steps. Mostly it was. What is not duplicated is the file; it is the **Stop hook**, the mechanical
refusal to end a turn while work is outstanding. The store is an implementation detail of that,
which is why there are two of them and the loop cannot tell them apart.

## Adding tasks

    add.py "what has to be true when this is done"
    add.py --check "pnpm exec vitest run src/world/purses.test.ts" "..."
    add.py --mine --after 3 "the remainder of task 3"

`what` is an explanation, not a title. The hook reads it out as the whole brief and the model gets
nothing else, so "fix the tests" produces exactly what that deserves.

## Checks, and who writes them

A `check` is a shell command whose **exit code** is the verdict. It is the only mechanical evidence
in the system.

    "check": "pnpm exec vitest run src/entities/declared.test.ts"
    "check": "! grep -q 'maybeNum' src/entities/properties.ts"

**If you are already working red-green, the check writes itself.** The failing test written at the
start of a task *is* that task's acceptance condition. There is no extra work to do.

**A check only tests what it was pointed at.** A grep for one string in one file proves that string
is gone and nothing else — it can be satisfied by editing one word. Prefer the test that was red.

**Do not plan on the user writing them.** The obvious advice — have the person who wants the work
write the standard it is judged by — is usually dead advice, and it was the first thing the person
this was built for pointed out:

> *"honestly speaking, I'm not going to write those checks, because I don't have enough knowledge of
> the code to write them. So whilst it's a good idea, I'll never actually do that, better to be
> honest about that upfront."*

A design that quietly depends on something nobody will do is worse than one that admits it, because
it lets everybody believe there is an independent standard when there is not. So assume the model
writes the task and the check, and lean on the one property that survives that: **the check must be
red when the task is written**, which `add.py` enforces by running it. Self-written or not, it is
then a commitment made before the work and checkable by a machine rather than a claim made after.

`by` records who asked for the task, which is still worth knowing — a task somebody dictated and a
task the model split out of its own remainder are different things — but do not read it as a mark of
independent verification. It is not one.

A task with no check is marked `"unverified": true` when it is ticked, so every one is findable.

## When to write a check, and when not to

Write one **only where the condition is genuinely mechanical**. The rule that matters is the
negative one: *if an honest check cannot be written, write none.* A weak check is worse than no
check, because it launders a claim into something that looks like evidence — and `unverified: true`
at least tells the reader where to go and look themselves.

**A check exists when the task's outcome is a fact a command can observe:**

| the task | the check |
|---|---|
| anything with a test written for it | `pnpm exec vitest run <that file>` — the red test *is* the check |
| a type or signature change | `pnpm exec tsc --noEmit` |
| removing something | `! grep -rq '<the thing>' src` |
| a file or artifact has to exist | `test -f <path>` |
| nothing may regress | the whole suite |
| a count has to reach nought | `test "$(grep -rc … | paste -sd+ | bc)" = 0` |

**There is no check when the outcome is a judgement**, and these are common and fine:

- *make this readable*, *tidy this up* — the point is taste, and a command cannot hold it
- *write the report on X* — `test -f` proves a file exists, not that it says anything
- *decide whether to do Y*, *investigate why Z* — the output is an argument, and the reader is the
  only judge there is
- *design the interface for W* — likewise

For those, leave `check` out and say in `what` how the reader will know it is done. That sentence is
doing the same job the check would, addressed to a person instead of a shell.

**Do not reach for a proxy.** "The file got longer" is not evidence a report is good; "the build
passes" is not evidence a refactor made anything clearer. A proxy check is the failure this whole
mechanism exists to prevent, wearing the costume of the fix.

## Installing it once, not per project

There is nothing to install into a project. The skill and its hook live at user level and the
**store resolves from wherever you are** — run in a repo with a remote and it is that repo's issues,
run in one without and it is that directory's file. Nothing to remember, nothing to copy in.

### Wiring the hook

The hook is `hook.py` beside this file. Copy it somewhere stable and wire it as a **Stop** hook:

```json
"Stop": [
  { "hooks": [
      { "type": "command", "command": "python3 \"$HOME/.claude/hooks/task-runner.py\"", "timeout": 960 }
  ]}
]
```

The timeout has to exceed the slowest `check`, because the hook runs it. `TASK_CHECK_TIMEOUT`
(default 900s) caps a single check.

## Stopping it

- An empty list ends the loop on its own: that is what done looks like.
- `TASK_LOOP_MAX` (default 40) caps how many times it will bounce in one session, so a list nobody
  meant to start cannot run all night.
- Ctrl-C always wins.
- Depth-first can starve the list if a task keeps spawning children. The cap catches it; the
  discipline is that split-out tasks must be strictly smaller than the one they came from.
