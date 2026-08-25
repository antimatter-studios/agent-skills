---
name: commit
description: Create tightly focused, grouped git commits from the current working tree changes
user-invocable: true
---

# Grouped Commit Workflow

Create small, topic-focused commits from the current uncommitted changes. Each commit should be a single logical unit of work.

## Step 0: Ensure git hooks are installed

Before doing anything else, make sure the repo's hooks will actually fire on the commits you are about to create. Two conventions exist in the wild; handle both.

**1. The repo ships an installer.** Run whichever exists:

```bash
./scripts/install-hooks.sh 2>/dev/null || .githooks/install-hooks.sh 2>/dev/null || true
```

Check `scripts/install-hooks.sh` first, then `.githooks/install-hooks.sh`.

**2. The repo ships a committed `.githooks/` with no installer** (github-guard's layout — its `install.sh` lives in the skill directory, not in the repos it guards). Here the guards travel with the repo but `core.hooksPath` is *per-clone local config*, so a fresh clone has every hook on disk and none of them active. Point git at them:

```bash
[ -d .githooks ] && [ -z "$(git config --get core.hooksPath)" ] && git config core.hooksPath .githooks
```

Only set it when unset — if `core.hooksPath` already points somewhere else, that is a deliberate choice and overwriting it would disable the hooks the user actually wants.

Both steps are idempotent, so run them every time. Together they ensure pre-commit checks (fmt, clippy, lint, secret scans) fire rather than silently no-op.

If there is no `.githooks/` and no installer, skip silently and continue.

## Step 1: Analyse the diff

Run `git diff` and `git status` to understand all uncommitted changes. Read the recent `git log --oneline -20` to match the existing commit message style.

### Step 1a: Check for pre-staged files (critical)

Before planning any commits, inspect the index. `git status --short` shows two columns — the first is the index (staged), the second is the working tree. Any entry with a non-space, non-`?` character in column 1 is already staged.

`git commit` commits **everything in the index**, not just what you `git add` afterwards. If the index already contains files from the user's in-progress work, they will be silently swept into your commit even if you only `git add` a narrow set of files.

If pre-staged files exist that are NOT part of what the user asked you to commit:

1. Stop and tell the user which files are pre-staged.
2. Ask whether to:
   - Include them in this commit (if they're logically related),
   - Create a separate commit for them (if they're a different topic), or
   - Unstage them with `git restore --staged <files>` so they stay in the index for the user's own later commit.

Do not proceed to committing until the index reflects only what you intend to commit.

### Step 1b: Worktree out if another agent's WIP is present

The pre-stage check (1a) catches files in the **index**. The harder
case is unstaged modifications you didn't author this session —
typically a parallel agent (e.g. Cascade) is mid-task in the same
working tree, and `git status` shows files you don't remember
touching. Committing the union silently mixes two topics into one
commit and obscures authorship.

Signals to look for:

- Branch name doesn't match the topic you've been working on
  (`git rev-parse --abbrev-ref HEAD`).
- `git status` shows files outside the set you remember editing.
- The user mentions "another agent", "Cascade", or a parallel
  in-flight task.

If detected, **do NOT** `git stash`, `git reset`, or `git checkout --`
the other work — that destroys their unfinished state. Instead,
isolate via a `git worktree`:

```bash
git fetch origin
git worktree add ../.wt-<short-name> origin/<default-branch> -b <your-feature-branch>
cd ../.wt-<short-name>
```

Pick a path outside the current repo's working tree (sibling
directory, or a hidden `.wt-*` name) so the parent project's git
doesn't try to track it.

Then re-apply **only your changes** in the worktree:

- New files you authored: `cp` them in from the original tree.
- Edits where your change is a small slice of a larger pre-existing
  edit (e.g. one new line in `Cargo.toml`): re-do the edit manually
  in the worktree.

Verify the worktree's `git status` shows only your intended files,
then continue this skill from Step 2 inside the worktree.

After the commit (and any subsequent `/pr`), leave the worktree if
follow-up commits are likely; otherwise clean up with
`git worktree remove <path>`. The other agent's tree in the original
directory stays untouched throughout.

### Step 1c: Reject files that should never be committed

After 1a/1b have settled the index, scan the proposed commit set
(staged + working-tree files you intend to add) against the
never-commit list below. These are files that almost always end up
in a repo by accident — usually because `.gitignore` was forgotten
or incomplete — and silently sneak into the commit if you stage
broadly. The skill's job here is to be the safety net the missing
`.gitignore` would have been.

| Category | Patterns |
|---|---|
| Editor scratch / local-only state | `.history/`, `*.swp`, `*.swo`, `*~`, `.vs/`, `.idea/workspace.xml` |
| OS metadata clutter | `.DS_Store`, `Thumbs.db`, `desktop.ini` |
| Secrets / credentials | `.env`, `.env.*`, `*.key`, `*.pem`, `*.p12`, `*.pfx`, `*.keystore`, `*.jks`, `id_rsa*`, `id_ed25519*`, `id_dsa*`, `id_ecdsa*`, `*credentials*`, `*secret*`, `.aws/credentials`, `*-adminsdk-*.json`, `service-account*.json` |
| Crash dumps / runtime debris | `core`, `core.*`, `*.core`, `*.dmp`, `*.pid` |
| Merge / edit backups | `*.orig`, `*.rej`, `*.bak` |

`.vscode/` is **not** on the hard list — some teams ship
`extensions.json` or `launch.json` for shared dev experience. If you
see anything under `.vscode/` in the dirty set, ask the user whether
it's the intentional shared kind before deciding.

For every match, surface it to the user with its category, and
offer three options (skip is the default — never silently commit a
match):

1. **Skip + gitignore** (preferred): append the matching pattern to
   `.gitignore` and create a separate `chore: gitignore <category>`
   commit BEFORE the user's intended commits, so the offending file
   stops showing up in `git status` for the rest of the session.
   Already-tracked files also need `git rm --cached <file>`.
2. **Skip + delete locally**: for crash dumps, log files, and
   `*.orig` / `*.rej` left by a merge — just `rm` and move on. No
   gitignore entry needed because there's no risk of the same file
   reappearing.
3. **Force include**: only when the user explicitly wants the file
   committed (the typical case is shared `.vscode/extensions.json`,
   the rare exception). Note the override in the commit message body
   so it's auditable.

Secrets warrant an extra step: if a `secrets / credentials` match
is already tracked (i.e. previously committed), tell the user
explicitly — `git rm --cached` removes future tracking but the
secret is still in history and may need rotation. Don't try to
rewrite history yourself.

## Step 2: Group changes by topic

Mentally group the changes into the smallest logical commits. Each commit should:

- Cover exactly one concern (e.g. "add dns list command", "extract shared render functions", "add probe tests")
- Be independently understandable from its diff alone
- Not mix unrelated changes (e.g. don't combine a refactor with a new feature)
- Not be so granular that each commit is a single line — a commit should be a complete thought

Good groupings: by feature, by package/layer, by concern (tests separate from implementation, refactors separate from features).

## Step 3: Identify the commit order

Order commits so that earlier commits don't depend on later ones. Typically:
1. Refactors and extractions first
2. New shared code / interfaces
3. Feature implementation
4. Tests
5. Documentation / config changes

## Step 4: Present the plan

Before creating any commits, show the user a numbered list of the planned commits. For each commit, show:
- The commit message (type prefix + description)
- The key files included

Wait for the user to confirm or adjust before proceeding.

## Step 5: Create each commit

For each group, stage only the relevant files and create a commit:

- Use `git add <specific files>` — never `git add .` or `git add -A`
- Before `git commit`, run `git diff --cached --name-only` and confirm the list matches exactly the files you planned to commit. If extra files appear (e.g. pre-staged from Step 1a), `git restore --staged <file>` to remove them from the index before committing.
- Write a concise commit message: type prefix + short description (under 70 chars)
- Use conventional prefixes: `feat:`, `fix:`, `refactor:`, `test:`, `chore:`, `docs:`
- Add a blank line then 1-2 sentence body only if the "why" isn't obvious from the title
- Do NOT add `Co-Authored-By: Claude` trailers, `🤖 Generated with...` lines, or any other AI-agent attribution. Do NOT add a meta-note explaining the omission. Commits are the user's; AI involvement is not part of the message.
- Do NOT mention unrelated projects, downstream consumers, private workspaces, or "this library is used in X" provenance. Each commit message stands on the change in this repo only — the upstream maintainer doesn't care where else the user uses the library, and the noise just pollutes the history.
- After each commit, run `git status` to verify the right files were committed
- Use a HEREDOC for the commit message to ensure correct formatting

### Step 5a: Update CHANGELOG.md / README changelog (if applicable)

Before staging the commit's source files, check whether the repo
keeps a user-facing changelog. The two conventions to look for:

- A top-level `CHANGELOG.md` (Keep-a-Changelog style or similar)
- A `## Changelog` / `## Recent changes` section inside `README.md`

If either exists, this commit may need a changelog entry. Decide
by the conventional-commit prefix:

| Prefix | Add changelog entry? |
|---|---|
| `feat:` | yes — user-visible feature |
| `fix:` | yes — bug fix the consumer would care about |
| `refactor:` | only if user-visible behavior changes (rare) |
| `chore(release):` / `chore(vendor):` | yes — version bumps and dep moves are exactly what users skim the changelog for |
| `chore:` (gitignore, hook setup, lockfile sync, CI config) | no |
| `docs:` | no — the entry would just say "updated the docs" |
| `style:` / `test:` | no |

When an entry is warranted:

1. **`CHANGELOG.md`**: under the appropriate version heading. If
   there is no in-progress unreleased section and this is not a
   release commit, add the entry under `## [Unreleased]` at the
   top, creating that heading if it doesn't exist. If the commit
   is itself a `chore(release):`, create a new dated section with
   the version number and move the previous `[Unreleased]` items
   into it.
2. **README changelog section**: cap at **10 entries** (or 10
   dated sub-sections, depending on the format the repo uses).
   When adding a new one, evict the oldest until the section is
   back to 10 or fewer. This keeps the README scannable; the
   exhaustive history stays in `CHANGELOG.md`.

Stage the changelog edit alongside the source files in the same
commit. The intent and the documentation of the intent land
together — never as a follow-up "docs: update changelog" commit.

If the repo has neither file, skip this step.

## Step 6: Verify

Run `task test` after the final commit to confirm nothing is broken. Then show the user the final list of commits created by running `git log --oneline -<N>` (where N = number of commits created).

## Rules

- Do NOT create a single monolithic commit for all changes
- Do NOT push to remote unless explicitly asked
- Do NOT amend existing commits
- If unsure whether to split or combine, prefer smaller commits
- If a file has changes belonging to two topics, use `git add -p` is NOT available — instead, split the work across commits by committing related files together and noting in the message if a file spans concerns
