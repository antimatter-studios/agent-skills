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
check that have a record of going red.

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

**`by` records who wrote it**, and this is the part to keep honest. A check written by the person
who wants the work is a specification. A check written by the model that will be graded on it is a
hypothesis about itself — worth having, because it is committed in advance and in a file anybody can
read, and not worth the same. Tasks the model splits out in the verify step are `by: "model"` and
its own checks come with it. Read those before believing them.

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

## Installing it

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
