---
name: issue-consolidation
description: Consolidate a repository's sprawl of open issues and pull requests into a few replacement issues, each with numbered acceptance criteria and one replacement branch/PR that carries every source change. Migrates source records verbatim, maps every source PR to a replacement, proves each criterion with tests (red before, green after), publishes the whole batch at once, and only then retires the originals as "superseded — migration, not completion". Use when a repo has many overlapping issues/PRs, a stack too tangled to merge, or one-issue-per-PR churn that wastes CI slots.
user-invocable: true
---

# issue-consolidation: many issues and PRs become a few provable ones

Turn N overlapping issues and their PRs into a small set of **replacement issues**, each owning:
- a clear outcome,
- numbered acceptance criteria (AC),
- one **replacement branch/PR** that carries all the source work for it,
- an evidence map proving each AC.

Nothing is lost: every source record is migrated verbatim and every source commit is ported. Nothing is closed until the replacements are published and verified.

## Args

- `<repo>`: `owner/name`. Required. Work in that repo's local clone.
- `--scope <query>`: limit to issues/PRs matching a `gh` search (label, milestone, path area). Default: all open.
- `--slug <name>`: short name for this run, such as `guest-reliability`. Default: the scope's main label, or `all`.
- `--plan-only`: stop after the plan document (step 3).
- `--base <branch>`: base for replacement branches. Default: the repo's default branch.

## Run folder

Every run writes only inside its own folder:

`RUN=.work/consolidation/<owner>__<repo>/<YYYY-MM-DD>-<slug>/`

- `.work/` is the scratch folder of the clone you are working in. Make sure git ignores it (`.git/info/exclude`). Never commit it.
- If `$RUN` already exists, append `-2`, `-3`, … instead of overwriting. A previous run's files are evidence.
- The files are `$RUN/inventory.md` (step 1), `$RUN/plan.md` (step 3), `$RUN/port-map.md` (step 5) and `$RUN/result.md` (step 9).
- Every replacement issue's hidden marker names the run: `<!-- issue-consolidation:<owner>/<repo>:<YYYY-MM-DD>-<slug>:<group-slug> -->`. A later run can then find and skip groups that an earlier run already published.

## Hard rules: refuse rather than violate

1. **The owner approves the plan before anything is created or closed.** Steps 1–3 are read-only.
2. **Never close or retire anything before the whole replacement batch is published and verified.** Publish everything first, then retire originals.
3. **Closing a source issue records migration, not completion.** Its closing comment must say so. A replacement issue closes only when every AC has evidence and its replacement PR has merged.
4. **Never weaken a test to get green.** No removed assertions, new skips, relaxed tolerances, reduced coverage, or a timeout turned into a pass. Every source test survives into a replacement branch.
5. **Never base a replacement branch on an original PR branch.** Replacements start from `--base`, or from each other in dependency order.
6. **Never touch a PR that is in the merge queue or has auto-merge on.** Let it merge, and fold it in as "already merged". Or ask the owner to dequeue it. Closing it silently removes it from the queue.
7. **External contributors' PRs and issues are never closed or rewritten without the owner's explicit yes.** Map them, credit them, and leave them open.
8. **Keep every source branch and commit.** Do not delete branches. Record each source PR's head SHA, and push an archive tag when the repo allows it.
9. **Never use `--no-verify`, never force-push a branch someone else owns, and add no AI attribution.** Follow the repo's AGENTS.md / CLAUDE.md for PR titles, changelog fragments and release rules.
10. **No restacking churn.** Once published, push to a replacement layer only to fix that layer's own failure. GitHub retargets stacks itself.

## Step 1: Inventory (read-only)

Collect into `$RUN/inventory.md`:
- Every open issue: number, title, labels, author, linked PRs, AC checkboxes and their states, last activity.
- Every open PR: number, head branch, head SHA, base, author, draft, mergeable state, required checks, merge-queue status, auto-merge, linked issues, commits (`git log --oneline base..head`), files touched.
- Stacks: which PR is based on which, and whether lower layers are merged.
- Overlap matrix: PRs and issues that touch the same files, and issues that describe the same symptom.
- Baseline: on `--base`, record test counts per tier, coverage, pinned fixtures and known failures. This is the bar replacements must meet.

## Step 2: Group

Choose groups by what grouping **buys**. If it buys nothing, it is not a group.
- **By file**, when the cost avoided is a conflict, a rebase or a CI slot. Example: ten PRs editing one module or translation file become one branch and one CI run.
- **By topic**, when the cost avoided is a divided argument. Example: three issues describing one failure mode become one outcome with one set of AC.
- Both often coincide. Use whichever fits each cluster.

Verify every group before acting:
- File groups: do the PRs' changes really interact, or do they only share a file name?
- Topic groups: is it one root cause, or two that look alike?

Split any group whose members would need contradictory fixes. Leave unrelated issues alone: consolidation is not a reason to sweep everything.

Aim for few groups, roughly 3–10 per repo. Each group becomes one replacement issue and one replacement PR. Dependent groups form a stack.

## Step 3: Plan document, then owner approval

Write `$RUN/plan.md` with, per group:
- **Replacement issue title**: an outcome sentence, not a task list.
- **AC with stable IDs** (`RUN-01`, `FIX-03`, …). Each AC is one observable, testable statement. Also list every source issue's own requirements as `<GROUP>-SRC-nn` items, so nothing a source promised disappears.
- **Source issues** it absorbs, and **source PRs** whose commits it carries, with head SHAs.
- **Replacement branch name** and its base: `--base` or the previous replacement.
- **Port method** per source PR (see step 5) and expected conflicts.
- **What stays open and why**: external PRs, items needing the owner, out-of-scope issues.
- **PR title type** per the repo's release rules: `fix:` / `feat:` / `chore:` …

Show the plan to the owner and **stop until they approve**. With `--plan-only`, stop here permanently.

## Step 4: Create the replacement issues

One issue per group, with these sections in order:

1. `## Outcome`: two to four sentences on what is true when this is done.
2. `## Source issues and existing work`: "This replacement issue owns the work previously described in: #a, #b, …". Source records are historical evidence; the AC here govern completion.
3. `## Acceptance criteria`: `- [ ] **ID**: statement`, then `### Preserved per-finding requirements` with the `-SRC-nn` items. Each SRC item links its source issue.
4. `## Replacement implementation`: a table of replacement PR, branch, preserved source work and acceptance status. Fill it in at step 7.
5. `## Source PR map`: a table of source PR, preserved head SHA and work to retain (commit count). Add: "A source PR's green check or checked box alone does not complete this issue."
6. `## Verification and completion gate`: a checklist.
   - Baseline recorded.
   - Red-before / green-after evidence per changed behaviour.
   - Every source test preserved, and overlaps accounted for.
   - All baseline tiers re-run with no skips and no coverage loss.
   - The PR maps each AC to its evidence.
   - Close only when every AC has evidence and the PR has merged.
7. The hidden run marker from **Run folder**.

Then migrate each source issue verbatim as a **comment** on its replacement, headed `## Migrated source #N: <title>`. Include:
- the original URL,
- the snapshot timestamp,
- a SHA-256 of the original body,
- the body itself, with its original checkbox states,
- its comments, each with author and date.

Verify each migrated comment against the source by hash before moving on.

## Step 5: Build the replacement branches

For each group, in dependency order:

1. Create the branch from its planned base.
2. Port each source PR's work. The default is `git cherry-pick <base>..<head>` of that PR's own commits, oldest first, keeping authorship. For a PR whose history is noise, use `git merge --squash <head>` into one commit that credits the source PR in its message. Never merge an original PR branch as a base.
3. Resolve conflicts by keeping **both intents**, then add a test proving both hold. If two sources truly contradict, stop and ask the owner. Never pick one silently.
4. Record a port map in `$RUN/port-map.md`: source commit → replacement commit, plus any correction made during integration and why.
5. Run the repo's hooks and full local gates. Compare against the step-1 baseline: same or more tests, no new skips, coverage not lower.

One branch per replacement issue. If the repo's commit rules want small commits, keep each source PR's commits distinct, so the port map stays readable.

## Step 6: Prove every acceptance criterion

For each AC ID:
- **Changed behaviour:** a test that fails on `--base` (red) and passes on the replacement branch (green). Record both runs, local or CI, with commands and output.
- **Existing correct behaviour:** independent evidence plus a negative control. The test must be shown to fail when the behaviour is broken. Never break code artificially to manufacture a red run.
- **Things only measurable** (memory, time, disk): a recorded before/after measurement with method and environment.
- **An AC you cannot prove yet:** leave it unchecked. Say what is missing.

Put an `## Acceptance and evidence map` table in each replacement PR body: AC ID, test or measurement, and red/green evidence link. Name the remaining AC under `### Remaining acceptance work`.

## Step 7: Publish the whole batch, then verify

1. Push all replacement branches in one atomic push (`git push --atomic`), so the batch appears together.
2. Open all replacement PRs together. Stack them (`gh stack` or base-on-previous) where dependent.
   - Title: one outcome sentence, typed per the repo's release rules.
   - Body sections: `## Scope` ("Contributes to #X. Replaces the implementation work from #a, #b"), the evidence map, remaining work, and a note that this PR is one of N published together.
3. Verify each remote head equals the recorded local head. Fill in the `## Replacement implementation` table on each replacement issue.
4. Link the replacement PRs to their issues ("Contributes to", or "Closes" only when the PR completes every AC).

## Step 8: Retire the originals, only now

For each source **issue**, comment and then close as "not planned / superseded":
> Superseded by #X. Its acceptance criteria own this work, and the complete source record has been migrated and verified at <link to migrated comment>. Related source PRs are mapped in #X and preserved while the replacement merges. This closure records migration; it does not assert that outstanding acceptance criteria are satisfied.

For each source **PR**, comment and then close:
> Superseded by replacement PR #Y for issue #X. All source commits are ported (map in #Y); head `<sha>` is preserved [and archived as tag `<tag>`]. This closure records migration, not completion.

Skip and leave open:
- anything in the merge queue or with auto-merge on (rule 6),
- external contributors' work (rule 7),
- anything the owner said to keep.

List what you skipped.

## Step 9: Ledger and hand-off

Write `$RUN/result.md` with:
- the groups and their replacement issue and PR numbers,
- the port maps,
- the baseline versus replacement test counts and coverage,
- which AC are proven and which remain,
- what was left open and why.

Report to the owner briefly: the replacement issues and PRs, what still needs evidence, and anything needing their decision.

## Failure modes to avoid (seen in practice)

- **Retiring a PR that was in the merge queue.** It was dequeued and the queue run was wasted. Check the queue first.
- **Treating a closed source issue as fixed.** Closure is migration. Only the replacement's AC decide completion.
- **Lost source requirements.** Fix this with the `-SRC-nn` preserved items and hashed verbatim migration.
- **Replacement branches based on original PR branches.** They drag old stack problems into the new batch.
- **Publishing replacements one by one while retiring originals in between.** Readers see a half-state. Publish all, verify, then retire.
- **Coverage or test counts quietly lower after the port.** Compare against the step-1 baseline every time.
- **Restacking every layer when a lower one moves.** It burns CI. Push a layer only to fix its own failure.
- **Two runs writing the same files.** Each run gets its own `$RUN` folder named by owner, repo, date and slug.
