---
name: pr
description: Turn working-tree changes (or existing commits) into a sequence of pull requests across one or more git repositories. Composes with the commit skill, pushes branches, opens PRs using each repo's PR template. Multi-repo aware — handles parent project + vendor submodules in dependency order.
user-invocable: true
---

# pr — commits to pull requests

Take whatever's in the working tree (or already committed) and land it as PRs. Cross-repo aware: the parent project and any vendor subdirectories that are independent git repositories each get their own PRs.

This skill **calls** the `commit` skill — it does not duplicate commit-grouping logic. Run `/pr` and it produces commits + PRs in one go; run `/pr --no-commit` and it only pushes existing commits.

## Args

Parse from the user's invocation:

- `--no-commit` — skip the commit step. Use only when commits already exist on a feature branch.
- `--split` — one PR per logical commit. Default is one PR per repo bundling all of that repo's commits.
- `--draft` — open PRs as drafts.
- `--base <branch>` — override the inferred base branch.
- `--respond` — fetch review feedback on the current branch's PR and address it (edits + replies + thread resolution). See "Step 6 — handling review feedback" below. Composes with `--no-commit`: with that flag, only post replies and resolve threads; do not edit code or push.

Anything else: ignore, do not invent flags.

## Hard rules — refuse rather than violate

- **Never force-push** (`--force`, `--force-with-lease`) unless the user explicitly asks for it in this conversation.
- **Never merge a PR**. Stop at "PR opened". The user reviews and merges.
- **Never use `--no-verify`**. If a pre-commit hook fails, surface the failure verbatim and let the user fix the underlying issue.
- **Never cross repo boundaries when grouping commits.** A commit in `vendor/<crate>/` is a commit in *that* repo. The parent's submodule-pointer change is a separate commit in the parent.
- **Never push to `main`** (or whichever branch is the repo's default). Always go through a feature branch + PR.
- **Never auto-bump submodules in the parent** until the vendor PR has merged. See "Submodule pointer bumps" below.
- **Never commit a file that looks like a secret** without flagging it: `.env`, `.env.*`, `*.key`, `*.pem`, `*credentials*`, `*secret*`, `*.p12`, `*.keystore`. If one of these is dirty, stop and tell the user.
- **Never resolve a review thread without replying.** Resolving silently is hostile to the reviewer. Every resolved thread must have at least one explanatory reply.
- **Never disagree with a reviewer without citing evidence** — a file:line, a behaviour, a test, a memory entry. "I disagree" is not a reply.

## Step 1 — preflight

Run these checks in parallel before doing any work:

1. `gh auth status` — must be authenticated to GitHub. If not, stop and tell the user to `gh auth login`.
2. `git rev-parse --show-toplevel` — confirm we're inside a git repo.
3. Scan `git status --porcelain` (and per-submodule equivalents) for any of the secret-looking patterns above. Stop if found.

## Step 2 — discover repos with changes

A "repo boundary" is any directory containing a `.git` file or directory. Walk the working tree:

1. The current top-level (always a repo).
2. Each `vendor/*/` directory that has its own `.git`.
3. Any other obvious sub-project directory with `.git`.

For each candidate, classify:

- **Has working-tree changes** — `git status --porcelain` is non-empty *inside that repo*.
- **Has unpushed commits** — `git log @{u}..HEAD --oneline` is non-empty (handle the case where there's no upstream yet).

In default mode (`/pr`), include any repo with working-tree changes OR unpushed commits.
In `--no-commit` mode, include only repos with unpushed commits.

If no repo qualifies, say so and stop.

## Step 3 — sequence the repos

Land in dependency order, lowest in the chain first:

1. `vendor/rust-fs-core` (foundation for every other Rust crate in this family)
2. Other vendor crates that depend on fs-core: `rust-img-qcow2`, `rust-partitions`, `rust-fs-ext4`, `rust-fs-ntfs`, future `rust-fs-*` / `rust-img-*`. These are mutually independent — order among them doesn't matter.
3. Other vendor sub-projects (e.g. `vendor/go-networkfs`).
4. The parent project last.

The reason: if the parent's submodule-bump PR lands before the vendor PR, parent CI breaks. Always merge vendor first.

If the user has an unfamiliar layout, use this heuristic: anything in `vendor/` lands before the parent, and within `vendor/` anything named `*-core` or `*-base` lands first.

## Step 4 — per-repo workflow

For each repo in sequence order:

1. `cd` to the repo root (use absolute paths).
2. **Check current branch.** If on the default branch (`main`, `master`, etc. — see step 6 for detection), we'll move new commits to a feature branch in step 5 (after commit) or right now (if `--no-commit`). If already on a feature branch, stay there.
3. **Create commits** (skip if `--no-commit`):
   - Invoke the `commit` skill via the Skill tool. The commit skill handles grouping, message style, pre-staged-file checks, secret scanning. Do not duplicate its work.
   - After it returns, re-check `git log @{u}..HEAD --oneline` to see the new commits.
4. **Determine the commits to ship.** These are the commits ahead of the upstream branch, OR if there's no upstream, all commits ahead of the default branch.
5. **Move to a feature branch if still on default.** From the (first) new commit's subject, generate the branch name per "Branch naming" below. Then:
   ```
   git branch <new-branch>
   git reset --hard <upstream-or-default-branch>
   git checkout <new-branch>
   ```
   If `--split`, do this per commit-group (cherry-pick into per-commit branches) — see "Split mode" below.
6. **Detect the default base branch** (unless `--base` provided): `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`. Cache it per repo.
7. **Push:** `git push -u origin <branch>`. Honour pre-push hooks; if they fail, stop and surface the error.
8. **Build the PR body** per "PR body" below.
9. **Open the PR:** `gh pr create --base <default-branch> --title "<commit subject>" --body-file <tempfile> [--draft]`. Capture the URL it prints.
10. **Record** the PR URL keyed by repo.

## Step 5 — finalize

Print a summary in this shape:

```
PRs opened:
  rust-fs-core      → https://github.com/antimatter-studios/rust-fs-core/pull/12
  rust-img-qcow2    → https://github.com/antimatter-studios/rust-img-qcow2/pull/8
  rust-partitions   → https://github.com/antimatter-studios/rust-partitions/pull/6

Parent project deferred — re-run `/pr` after the vendor PRs above have merged.
```

If the parent had changes that are *only* submodule-pointer bumps (no other parent edits), say so and don't open a parent PR yet. If it has independent edits too, open a parent PR for those alone (filter the staged set to exclude the gitlink updates).

## Step 6 — handling review feedback (`--respond`)

Triggers only when the user passes `--respond`. The current branch must have an open PR; if not, stop and tell the user to open one first.

The expected scenario: AI reviewers (Greptile preferred per user memory; CodeRabbit secondary) and/or humans have left review comments and the user wants those addressed in one pass.

### 6.1 — fetch the review state

```
gh pr view --json number,headRefName,reviewThreads,comments,reviews,url
```

Fields you'll use:

- `reviewThreads[]` — line-level threads. Each has `id` (GraphQL thread ID), `isResolved`, `isOutdated`, and a list of `comments`. Each comment has `id` (GraphQL comment ID), `author.login`, `body`, `path`, `line`.
- `comments[]` — top-level (issue-style) PR comments.
- `reviews[]` — submitted reviews with summary `body`.

### 6.2 — prioritise reviewers

Address feedback in this order:

1. **Greptile** (`@greptile-apps[bot]`) — user's preferred AI reviewer, default to its suggestions when AI reviewers conflict.
2. **CodeRabbit** (`@coderabbitai[bot]`).
3. **Other AI reviewers** (`@cursor-ai`, `@sourcery-ai`, etc.).
4. **Human reviewers** — always read carefully; reply in human-friendly tone, less terse than for bots.

Skip threads where `isResolved == true` or `isOutdated == true` (the latter means the lines no longer exist on the branch).

### 6.3 — classify each thread

For each unresolved, non-outdated thread, read every comment in it and classify into one of these verdicts:

| Verdict | Action | Resolve thread? |
|---|---|---|
| **Already addressed** in a later commit on this branch | Reply pointing to the SHA + line | Yes |
| **Valid suggestion needing code change** | Edit code (in worktree if appropriate), commit + push, then reply citing the new commit SHA | Yes (after push) |
| **Wrong / not applicable** in this codebase | Reply with respectful, evidence-backed explanation (cite file:line, behaviour, test, or memory) | Yes |
| **Needs more discussion** | Reply with a clarifying question | **No** — leave open for the reviewer |
| **Out of scope** for this PR | Reply explaining and offering to file a follow-up issue | Yes |
| **Adding tests / docs the reviewer wants** | Add them, commit + push, reply | Yes (after push) |

If a thread has multiple sub-comments mixing topics, address each topic separately with its own reply.

### 6.4 — make code changes BEFORE replying

If any threads require code edits, do all of them first, then push, then reply. This ordering matters because each reply should cite the exact SHA that addresses the comment.

Workflow:

1. Group review-driven changes by topic. Invoke the `commit` skill so the changes land as focused commits, not one giant "address review" commit.
2. `git push` to the same branch (no rebase, no force-push — review threads anchor to commit SHAs and force-push breaks them).
3. Capture each new commit's SHA from `git log @{u}..HEAD --oneline` taken before vs after, or from the `git push` output.

### 6.5 — reply

For each thread, post a reply via GraphQL using the thread's `id` from step 6.1:

```
gh api graphql -f query='
  mutation($threadId:ID!, $body:String!) {
    addPullRequestReviewThreadReply(input:{
      pullRequestReviewThreadId:$threadId,
      body:$body
    }) {
      comment { id }
    }
  }' -f threadId="<thread-id>" -f body="<reply-text>"
```

For top-level PR comments (review summaries, general questions), use:

```
gh pr comment <pr#> --body "<reply-text>"
```

**Reply expectations.** The reply has to *detail the solution*, not just point at a SHA. The reviewer should be able to confirm the fix is sound from the reply alone, without opening the diff. This is the standard GitHub PR-review workflow: code change → push → reply explaining what was done → resolve thread. The skill enforces this order via 6.4 → 6.5 → 6.6; never resolve a thread without a reply that demonstrates how the suggestion was addressed.

**Reply shape:**

- For valid suggestions: `"Done in <SHA> — <one-to-two sentences describing what the fix does>"`. State the mechanism, not just the outcome ("wrapped the offline window in its own try/finally so the restore is unconditional" beats "fixed it"). If your implementation differed from the reviewer's suggestion (different mechanism, narrower scope, additional safety), call that out and say *why* — silent deviation reads as either ignored feedback or a bug.
- For wrong suggestions: explain *why* in 1–2 sentences, citing a file:line, a test, or a memory entry. No defensive tone.
- For deferred items: `"Captured as follow-up — <reason>"` only if the user has authorised the deferral. Otherwise treat as "needs discussion" and don't resolve.
- Concise but never empty: one to three sentences. Padding bad, terseness that hides the *what* and *why* also bad.

**Never:**

- Reply with bare "thanks" or "ok" — every reply must add information.
- Use marketing language or padding ("great catch!", "appreciate it!").
- Mark a thread resolved without an explanatory reply that demonstrates the solution.
- Cite a SHA without saying what's in it.

### 6.6 — resolve threads

After replying, mark each addressed thread resolved via GraphQL:

```
gh api graphql -f query='
  mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) {
      thread { isResolved }
    }
  }' -f threadId="<thread-id>"
```

The `threadId` comes from `reviewThreads[].id`.

Threads classified as "needs more discussion" stay unresolved. The reviewer drives the next step.

### 6.7 — update the PR description with the review-fix mapping

After all replies are posted and threads resolved, update the PR's body to include a **"Review feedback addressed"** section that lists each review point and the specific fix that landed for it. This is *additive to* the per-thread replies in 6.5 — replies live with the reviewer's comment in the thread; the PR body summarises all of them in one place for someone reading the PR fresh.

Why both:

- Per-thread replies are buried in collapsible review threads on the GitHub UI; reviewers see them but a future reader doing `git log` / blame won't.
- The PR body is what shows up in the merged-commit message and in any history viewer that pulls PR descriptions.
- A reviewer who comes back later can scan one section to see what changed in response to their feedback without expanding every thread.

Append (don't replace) a section like this to the PR body via `gh pr edit --body-file <tempfile>`:

```markdown
## Review feedback addressed

| Reviewer | Path:line | Verdict | Fix |
|---|---|---|---|
| greptile-apps | .gitmodules:3 | wrong | SSH URL is project convention; reply explains; no code change |
| coderabbitai | scripts/run-cycle.sh:31 | partial | Added executable pre-checks + dropped `2>/dev/null`; kept `\|\| true` (claim's exit-1 is the normal end-of-loop signal). Commit cb64ce7. |
| coderabbitai | scripts/run-cycle.sh:87 | adopt | Both update-status calls now use `\|\| true` for consistent best-effort policy. Commit 653feac. |
```

Columns:

| Column | Content |
|---|---|
| Reviewer | The bot/user handle, no `@`. |
| Path:line | The thread anchor as `gh api graphql` returned it. |
| Verdict | One of: `adopt` (code changed as suggested), `partial` (some of the suggestion adopted), `wrong` (pushed back with evidence), `discussion` (left open), `deferred` (filed as follow-up). Match the verdict you used in 6.3. |
| Fix | One sentence + the SHA (or "no code change" / "follow-up issue #X" / "left open"). Mirrors the per-thread reply, terse — the per-thread reply has the full context. |

If a "Review feedback addressed" section already exists from an earlier `--respond` round, **append a new round under it** rather than replacing — don't lose the prior round's record:

```markdown
## Review feedback addressed

### Round 1 (cb64ce7…653feac)
| ... |

### Round 2 (4bdcd69)
| ... |
```

Then print the run summary:

```
Review feedback addressed (PR #<n>):
  resolved threads:    <N>
  open threads:        <M> (awaiting reviewer reply)
  follow-up commits:   <K> pushed
  unaddressed reviews: <P> (top-level summaries)
  PR body updated:     review-fix mapping appended

PR: <url>
Re-run /pr --respond after the next round of review.
```

If `--no-commit` was passed alongside `--respond`, skip the "follow-up commits" line and add `(no-commit mode: code changes deferred)`.

## Branch naming

Derive from the (first) commit's Conventional Commits subject. Format:

```
<type>/<scope>-<slug>     ← when a scope is present
<type>/<slug>             ← no scope
```

Slug rules:
- Take the subject text after the `:`.
- Lowercase, replace any non-`[a-z0-9]` run with `-`, strip leading/trailing `-`.
- Cap branch name at 60 chars total. Truncate the slug, never the type or scope.
- Collision: if `git ls-remote origin <branch>` returns a match, append `-2`, `-3`, ... until free.

Examples:

| Subject | Branch |
|---|---|
| `feat(qcow2): add zlib compression` | `feat/qcow2-add-zlib-compression` |
| `fix: null deref in caching device` | `fix/null-deref-in-caching-device` |
| `chore(submodule): bump ntfs to a1b2c3d` | `chore/submodule-bump-ntfs-to-a1b2c3d` |

Multi-commit PRs use the **first** commit's subject. In `--split`, every commit yields its own branch.

## PR body

For each repo, look for a template in this order:

1. `.github/PULL_REQUEST_TEMPLATE.md`
2. `.github/pull_request_template.md`
3. `PULL_REQUEST_TEMPLATE.md`

If a template exists, prepend an auto-generated **Summary** section listing the commit subjects, then the template content as-is.

If no template, generate this default body:

```markdown
## Summary
- <first commit subject>
- <second commit subject (if multi-commit)>
- ...

## Test plan
- [ ] <repo-specific test command — see below>
- [ ] <repo-specific lint command — see below>
```

Do NOT add `🤖 Generated with...`, `Co-Authored-By: Claude`, or any other AI-agent attribution to PR titles or bodies. Do NOT add a meta-note explaining the omission. Upstream maintainers routinely require these to be removed; never write them in the first place.

Do NOT mention unrelated projects, downstream consumers, private workspaces, or "originally built for X / used by Y" provenance in PR titles or bodies. The reviewer cares about the change in *this* repo, not where else the user uses the library. No "this came from <other-repo>", no "developed against <downstream-app>", no "migrated from a private fork". Cut the Provenance/Background sections entirely if they would otherwise carry that content. License notes are unnecessary too — the repo's own LICENSE governs contributions; restating it is noise.

### Detecting the test + lint commands per repo

In each repo root:

| Marker | Test command | Lint command |
|---|---|---|
| `Cargo.toml` | `cargo test` | `cargo clippy --all-targets -- -D warnings` |
| `package.json` with `scripts.test` | `npm test` | `npm run lint` (only if defined) |
| `go.mod` | `go test ./...` | `go vet ./...` |
| `Makefile` with `test` target | `make test` | `make lint` (only if defined) |
| (none of the above) | leave a `<TODO: describe how to test>` placeholder | omit the lint line |

Detect by checking file existence + grepping for the script/target. Don't guess.

## Split mode

`/pr --split` creates one branch + PR per commit. Workflow:

1. Determine the new commits as in Step 4.4.
2. For each commit `<sha>` in chronological order:
   - Generate branch name from that commit's subject.
   - `git checkout -b <branch> <upstream>` then `git cherry-pick <sha>`.
   - Push, open PR with `--base <default>`. The body summarises just this one commit.
3. After all PRs, restore the user's original HEAD: `git checkout <original-branch>`.

Split mode does **not** create a stack — every PR is independent of every other. If two split PRs are logically dependent, the user takes responsibility for the merge order.

## Submodule pointer bumps (parent repo)

When a vendor PR has been opened but not merged, the parent project's `vendor/<crate>` gitlink points at a SHA that doesn't exist on the vendor's `main` yet. Opening a parent PR with that pointer would fail CI (the vendor commit isn't on the default branch).

So:

- After vendor PRs are opened, **stop**. Tell the user to merge the vendor PRs first, then re-run `/pr`.
- On the next `/pr` run, the vendor commits are on `main`; the parent's gitlink update is now legitimate. The skill commits the gitlink bumps as a `chore(submodule): bump <crates>` commit and opens a parent PR.

If the parent has independent changes (not just gitlink bumps) AND the gitlink bumps point at unmerged vendor SHAs: split the parent into two — open a PR for the independent changes only, defer the gitlink bumps to after vendor merges.

## When to ask the user

Stop and ask, do not guess:

- `gh` is not authenticated.
- Multiple plausible base branches and `gh repo view` doesn't disambiguate.
- A change crosses what looks like a repo boundary (e.g. a single hunk modifies parent + submodule files in a way the commit skill couldn't split).
- A modified file matches the secret-pattern list.
- After 5 collision retries the branch name is still taken.
- (`--respond` only) A reviewer asks for something the user has previously rejected (check memory) — confirm before complying.
- (`--respond` only) A review thread asks for changes that would touch files outside the PR's diff — confirm scope.
- (`--respond` only) The classification of a thread is genuinely ambiguous between "wrong" and "needs discussion" — ask which.

## What this skill does not do

- **Stacked PRs.** No PR-N-depends-on-unmerged-PR-M chains. Solo workflow + cross-repo independence means stacks aren't needed today. If the use case appears, layer Graphite (`gt`) on top — don't extend this skill.
- **Auto-merge.** Always stops at "PR opened" (or, in `--respond` mode, at "threads addressed"). The user reviews and merges.
- **Force-push.** See "Hard rules".
- **Squash decisions.** The PR's merge strategy is a repo setting; this skill doesn't override it.
- **Issue / project linking.** The user adds those manually if they want.
- **Approve PRs** in `--respond` mode. The skill never submits an approving review on its own — replying to comments is the limit.
- **Bulk-resolve threads.** Each resolution requires its own per-thread reply and judgement. No "resolve all".
