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

**GitHub issues when the remote is GitHub**, decided by reading `git remote -v` for `github.com`
rather than by asking whether GitHub answered just now. The difference matters: a check that needs
auth and a network fails the wrong way, and on a GitHub repository with `gh` logged out it would
quietly start a private list beside a public tracker. The remote is a statement of intent, it is
instant, and it is true on a train; if `gh` then cannot be reached, that is worth saying out loud
rather than going quiet and local. Open issues labelled `task-runner` are the queue,
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

### How each field maps

Most of it lands on something GitHub already has, which is the test of whether the mapping is real
or invented:

| the task's | on an issue | |
|---|---|---|
| `id` | issue **number** | a stable identity already |
| `what` | **title and body** | title is the brief, body the detail |
| `done` | **closed** | canonical; nothing to invent |
| `by` | issue **author** | GitHub knows this better than we could |
| `check` | `<!-- check: … -->` in the body | no native field; invisible when rendered |
| `was_red` | label **`check-was-red`** | visible at a glance and queryable |
| remainder of a task | native **sub-issue** | `addSubIssue`; containment — *part of* |
| must happen after | native **`blockedBy`** | `addBlockedBy`; ordering, which is not containment |
| ticked with no check | **closing comment** saying so | a state cannot carry *why* |
| `handed`, `asked`, `at` | nothing — stays in `.git/` | belongs to the run, not to the repository |

**Order looks like the one that does not map, and it does.** Issue numbers are creation order, so
splitting task 5 opens issue 31 and 31 sorts last — the remainder of a job would come back after
everything else with its context gone, which is what "insert below" exists to prevent.

GitHub has the structure natively: `addSubIssue`, a `parent` on every issue, and even
`reprioritizeSubIssue` for ordering among children. So remainder work becomes a real **sub-issue**
of the job it came out of, the loop takes children of the task it just settled before anything else,
and the relationship is visible in the interface to whoever is reading rather than living in a regex
the hook happens to run.

### Checks that are more than one line

There is **no attachment API** — issue attachments are drag-and-drop in the browser and nothing
else, so a validation script cannot be attached programmatically. That is no loss, because a file in
the repository beats an attachment on every count: it is versioned, it is reviewed in the pull
request that changes it, it diffs, and it runs without anybody downloading anything.

    checks/95.sh                          a script of any length
    <!-- check: sh checks/95.sh -->       which is still one shell command

So the same field carries `test -f done.txt` and a hundred lines of setup, teardown and assertions.
Nothing about the mechanism changes; only the length of what it points at.

Name it for the **issue** number, which is what the loop keys on. The worklist or design number, if
there is one, lives in the issue title where a person reads it.

### And take the scaffolding down again

A check script outlives its task by nothing at all. The moment the issue closes the task-runner will
never ask for it again, and what is left is a file that looks live, runs never, and rots against
code that moved underneath it — which is the exact fault `chore reachable` exists to count. Starting
a fresh pile of dead files in a new directory is no way to answer a report of forty-three of them.

Two honest endings when a task goes green, and both end the same way:

- **the property should stay true** — then it belongs in the test suite, where something runs it on
  every build. Promote it, then delete the script.
- **it was a one-off** — `! grep -q maybeNum`, `test -f report.md` — it has nothing left to say.
  Delete it.

Worth enforcing rather than remembering: a test that lists `checks/*.sh` against the open issues and
fails on any script whose issue is closed. Then the scaffolding cannot quietly become furniture.

### And this skill's own

`tests/source.sh` runs the same discipline on the runner itself. Both task sources have to answer
the same questions, because the hook does not know which one it is talking to, and that agreement is
exactly the kind that rots without being noticed: a method added to one source and forgotten on the
other fails only on a repository nobody is testing on. Two faults found on 13 September 2026 are
pinned there — a `say` copied from the GitHub source into the file one, keeping a `_gh` call the
file source has not got and shadowed by a second definition of the same name below it; and
`addBlockedBy`, documented as the way to record ordering, with nothing anywhere able to write one.

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

## Work that cannot be done

A queue that hands back a task the model cannot do, every time it comes round, is a queue somebody
stops reading. But the fix is **not** to close it — and that distinction is the whole of this
section. Chris, 13 September 2026:

> *"we might not want that issues vanish from the tracker, it's just that claude can't fix them,
> which is a different thing."*

Exactly so. *The model cannot do this* and *nobody is going to do this* are unrelated statements, and
conflating them silently abandons wanted work and makes it look like somebody decided to. Almost
everything here stays **open**:

**Tried and could not — `needs-respec`, with the attempt written down.** The commonest of these
and the one worth getting right. Chris, on the same afternoon:

> *"just cause claude can't fix it, doesn't mean the idea should be removed from the issue tracker,
> because it might be just that the issue is not well specified and we should do it again."*
> *"the issue is, claude has decided to not fix it because it tried and can't, so a human needs to
> respecify the task."*

A task nothing can act on is far more often a task that does not say enough than one that cannot be
done. But the model **should not rewrite it itself** — it is the one that could not read it, so its
version is likely wrong in the same way, and a confident respecification by the party that
misunderstood is worse than none.

So the label is the small part and the **attempt is the deliverable**: what was actually tried, what
happened, where it stopped, and a best guess at what the task does not say. A person respecifies
from that account, cheaply, because the expensive half — finding out what goes wrong when you try —
has already been paid for. Take the label off when the issue has been rewritten.

**It wants somebody's hands or eyes — `needs-hands`.** A device, a playtest, a look at the thing
running. The first task this queue ever offered was a phone layout whose remaining half was, in its
own words, *"the part that wants a real thumb on real glass rather than an emulator"*, and nothing
in the tracker could say so. **This is the common case and it is not a failure state.**

**It wants an answer — `needs-feedback`.** A fork only a person can choose, reached without anything
going wrong. Chris, 13 September 2026: *"needs-hands I guess it means I need to play it,
needs-feedback is perhaps when claude stops working on a task because it can't and needs feedback
from somebody else"*. The two were one label for a day and the conflation showed immediately: of the
four tasks marked `needs-hands` that afternoon, two were decisions — *may a farm clear only so far
from its own buildings, or does a village deforest a county over a century?* — and no hand was
wanted for either. A decision waiting on a person and a playtest waiting on a person stop the loop
the same way and are answered in completely different ways, so they are not one state.

Both leave the issue open, and **the label beats the close**. `mark_done` shut #5 minutes after it
was labelled and given the fork to choose, because the no-check path closes on the model's word —
two halves of this runner disagreeing about one fact, which is the fault it exists to catch, found
in it. A label is the more specific and more recent statement; a close is what happens when nothing
else does.

**Blocked on something outside the repository — `cant-fix`.** An upstream release, an API that does
not exist yet, a decision somebody else owes. Stays open and visible; the label comes off when the
thing it was waiting for arrives.

**Waiting on another task — GitHub's own `blockedBy` relation.** `addBlockedBy`, with `blockedBy`,
`blocking` and `issueDependenciesSummary` on every issue. Ordering rather than impossibility, and it
resolves itself when the blocker closes.

This file read a `Blocked by #25` line out of the body for a while, on an assertion that GitHub had
no such relation. It does. The mistake is worth keeping because of its shape: sub-issues were looked
up, found, and a conclusion about *dependencies* was then stated without looking — two different
relations, one of them checked. The written line still works as a fallback for issues nobody has
linked up, but the relation is read first: it is structural, it shows in the interface, and it cannot
drift from a reword.

**Three kinds of follow-up, and they are not the same thing.** The verification step asks for all
three whether or not the task finished, because a task that went green still found things and they
are gone the moment the turn ends — the model is the only one who saw them, and nobody reading the
diff later will know they were ever noticed. On 13 September 2026 one item produced all three: the
*remainder* (a sub-issue of the job), a *blocker* found by trying it (its own task, with the
original recorded as blocked by it — not a child, because it is not part of that job, it is in front
of it), and a *hole* next door found while reading (its own task, no relation at all). The wording
before that asked only on "not finished", so a clean completion that uncovered three things filed
nothing.

**Say so with `source.block`.** For a while the loop could *obey* a blocker and not *create* one, so
the only ways to record ordering were a person adding it in the interface or a body line a reword
could quietly undo — and a relation the loop obeys but cannot write is a relation that mostly does
not exist. Both sources now take it: on GitHub it is the `addBlockedBy` mutation, and in the file it
is a `blocked_by` field the sort reads. Reach for it when a task turns out to need another one first
— which is a different discovery from splitting a task, and belongs in a different relation.

**Decided against — close it, `--reason "not planned"`.** This one is rare and it is a *decision*,
not an observation about who can do the work. Reach for it only when the task should not be done by
anybody. If there is any doubt, label it and leave it open: an issue nobody can find again is worse
than one that sits in the list with a reason attached.

## The report, and why the flags are checked rather than believed

Everything above is an instruction, and an instruction is a thing the model can simply not follow
while nothing notices. So the verification turn has to end with a block the hook reads:

    <task-runner-report task="13">
    status: working|finished|blocked|needs-feedback|needs-hands|needs-respec
    did: <one line on what actually happened this turn>
    filed: #41 #42 | none
    </task-runner-report>

Chris, 13 September 2026: *"task_complete:false, issues_created:[112,113] would be ok, because the
task is not complete and two tasks are created. But task_complete:false, issues_created:[] would be
a failure, because if the task is not complete, claude is required to create issues to fill the
gaps. But it didn't."*

Asked at **every turn end that had a task in hand**, not only at the verification step. Chris, 13
September 2026: *"each time we end a turn, we need to know, what did you work on and what the
task_status is"*.

`working` is why that is possible. A turn spent halfway through a job files nothing and has done
nothing wrong — it says so, and the same task comes straight back. Every other status **hands the
job back**, and then whatever is left in it has to be a task, or it is a reason that existed for one
turn and is now gone. `did:` is the other half of the question and is required in all of them: one
line on what actually happened, which is the only record of the turn that survives it.

**The flags are claims, not evidence.** What makes them worth having is that every one is checked
against the tracker before the turn is allowed to end, and a turn that does not hold up is sent
back:

- **handed back and nothing filed** — the case above, and the reason the block exists. Not
  `working`, which is allowed to file nothing.
- **`did:` left empty** — a turn that ends without saying what happened in it.
- **a number that does not exist** — a task can be named in a report and never created, and saying
  so is free.
- **a task that exists and is empty** — a title with nothing under it satisfies "an issue exists"
  and is useless to whoever picks it up months later with none of the context that made it obvious.
  Eighty characters of body, which is not an essay and is more than a reminder.
- **a remainder that is not a sub-issue** — the mistake made four times in one afternoon: filed
  with `add` instead of `split`, so the rest of a job floats free of the job and sorts by number
  instead of coming next.

The Stop event carries the transcript path, so the turn's own words are readable from the hook. That
is the whole difference between a hook that **asks** and a hook that **checks** — and where the
transcript cannot be read, the report is taken on trust rather than reported missing: a loop that
cannot be escaped by doing the right thing is the worst kind there is.

## Touching the tracker

**Never hand-write a `gh` command or a GraphQL mutation. Ask for the operation by name.**

    task.py list                      what is outstanding, and what each is waiting on
    task.py show <id>                 one task, with everything written on it since
    task.py add "<text>" [--check C]  a task with no parent: a hole found next door
    task.py split <id> "<text>"       the REMAINDER of that job, as a sub-issue of it
    task.py block <id> <on>           <id> cannot start until <on> is finished
    task.py label <id> +a -b          put a state on it, or take one off
    task.py done <id> [--check C]     finished; refuses if a label says it is waiting
    task.py reopen <id> "<why>"       un-close something that should not have been
    task.py say <id> "<text>"         write on it, once per distinct thing said

Chris, 13 September 2026: *"If we mechanically give claude these commands, it'll make the quality of
the responses higher since we don't rely on the agent to think of what to run. They ask for a
command, they are given a command, they execute the command exactly as given."*

The evidence is a day of getting it wrong by hand. In one session the model invented a GraphQL field
that does not exist (`blockedByIssueId`; it is `blockingIssueId`), read an array length off an
object and got the count of its keys, broke a query with an embedded newline, wrote a zsh loop that
did not split because zsh does not word-split unquoted variables, and filed four issues with raw
`gh` instead of these calls — so they are missing from the run record entirely.

Five faults, none of them interesting. The point is not that the model cannot write `gh` commands:
it is that writing them *again each time* makes every one a fresh chance to be subtly different, and
subtly different is the kind of wrong that still returns a plausible answer.

`split` and `add` are deliberately two commands. A remainder is a child of the job it came out of
and the loop takes children first; a hole found next door is nobody's child, and filing it as one
claims a relationship that does not exist *and* jumps it up the queue on the strength of it.

## Stopping it

- An empty list ends the loop on its own: that is what done looks like.
- `TASK_LOOP_MAX` (default 40) caps how many times it will bounce in one session, so a list nobody
  meant to start cannot run all night — and raising it is how you make one that does. Set it on the
  hook's own command line rather than in a profile, so it applies to this and to nothing else:

      "command": "TASK_LOOP_MAX=500 python3 \"$HOME/.claude/skills/task-runner/hook.py\""

  Worth knowing before turning it up: every bounce is a whole turn, so a long night is a real amount
  of tokens; and the queue is the other limit — when it empties the loop stops whatever the cap says.
  The thing you lose is the thing that has caught the most: on the night this was built, the worst
  errors were found by the person asking a question mid-turn, and a loop running unattended for
  hours has nobody to ask.
- Ctrl-C always wins.
- Depth-first can starve the list if a task keeps spawning children. The cap catches it; the
  discipline is that split-out tasks must be strictly smaller than the one they came from.
