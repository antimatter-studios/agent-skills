---
name: github-guard
description: Install github-guard's composable git-hook guards into a repository. Ships a run-parts dispatcher for every safe client-side git hook plus a catalog of drop-in guards — linear history (squash+rebase only, block local merge commits), protect the default branch (require PRs, no direct pushes), and auto-fmt + clippy + reproducible-release dependency-pinning for Rust. Use when the user asks to install/add github-guard or merge-guard, protect a repo from merge commits or direct pushes to main, enforce linear history or squash-only merges, or add pre-commit fmt/clippy guards.
---

# github-guard

A composable set of **git-hook guards** that stop silly mistakes from creeping
into a repo while you (or an agent) work in it. Each git hook is a thin
**dispatcher** that runs every executable script in its `<hook>.d/` directory;
each guard is a single-purpose script you drop in or delete.

```
.githooks/
  pre-commit                 # dispatcher → runs pre-commit.d/* in order
  pre-commit.d/
    github-merge-squash-only.sh
    github-protect-main.sh
    rust-fmt.sh
    rust-clippy.sh
    rust-deps-pinned.sh
  pre-merge-commit  + pre-merge-commit.d/git-block-merge-commit.sh
  pre-push          + pre-push.d/git-block-merge-commits.sh
  lib/common.sh  lib/run-guards.sh
  required-checks            # optional: the status checks main must require
  …documented stubs for every other safe client-side hook (no-op until you add guards)
```

**Naming:** guards are `<topic>-<name>.sh`. The topic prefix groups them and
shows the domain at a glance (`github-*`, `git-*`, `rust-*`, …). They run in
lexical order; wedge a number (`rust-05-…`) if order matters.

**Convention every guard follows:** self-gate, then no-op if it doesn't apply
(`rust-*` skip without a `Cargo.toml`; `github-*` skip on repos you don't own
or non-GitHub remotes). So the whole set is uniform to install and
self-selecting at runtime — no per-project config.

## Shipped guards

- **`github-merge-squash-only`** (pre-commit, fail-open) — heals the GitHub repo
  to squash+rebase only (`allow_merge_commit=false`). Owner-only; never blocks.
- **`github-protect-main`** (pre-commit, fail-open) — protects the default
  branch: require a PR, enforced for admins, linear history, no force-push or
  deletion. Owner-only; never blocks. Also keeps **required status checks** in
  sync — auto-discovered from recent `pull_request` runs, or declared explicitly
  (see below).
- **`git-block-merge-commit`** (pre-merge-commit) — hard-blocks creating a merge
  commit locally.
- **`git-block-merge-commits`** (pre-push) — hard-blocks pushing any range that
  contains a merge commit.
- **`git-block-bad-files`** (pre-commit) — refuses to commit staged keys/certs,
  credential blobs, env files, OS junk, and merge cruft. Conservative (no broad
  `*secret*` globs; `.env.example` etc. allowed).
- **`git-no-trailing-whitespace`** (pre-commit) — blocks staged changes that add
  trailing whitespace / space-before-tab (`git diff --cached --check`).
- **`git-block-large-files`** (pre-commit) — blocks staged files over a size
  limit (default 10 MiB, `GITHUB_GUARD_MAX_FILE_MB`) unless Git-LFS-tracked. A
  backstop for accidents; `.gitignore`/LFS is the real home for big assets.
- **`git-changelog`** (pre-push) — when pushing a version tag, requires the
  release to be documented: a section for the tag in CHANGELOG.md and/or the
  README changelog section (≤10 versions in the README + a link to
  CHANGELOG.md). Self-gates via `gg_has_changelog` — repos with no changelog are
  unaffected.
- **`git-tags-on-main`** (pre-push) — hard-blocks pushing a tag whose target
  commit is not contained in the default branch (`main`); release tags must mark
  a commit that landed on main, never one stranded on a feature or pre-squash
  line. Purely local (ancestry check; peels annotated tags); fail-open only if
  `main` can't be resolved locally. Git has no `git tag` creation hook, so the
  push is the enforcement point.
- **`rust-fmt`** (pre-commit) — runs `cargo fmt` and re-stages the staged files;
  Cargo projects only; never blocks (auto-fixes layout).
- **`rust-clippy`** (pre-commit) — `cargo clippy --all-targets -- -D warnings`;
  Cargo projects only; blocks on lint failures. Skips (never blocks) when a
  `path=` sibling dependency isn't checked out — CI, which has every sibling,
  is the backstop.
- **`rust-deps-pinned`** (pre-commit) — reproducible-release gate; Cargo projects
  only; blocks on: a workflow that floating-clones or `actions/checkout`s a
  **same-owner sibling repo** without a pinned `--branch`/`ref:`; a `Cargo.lock`
  that's tracked-but-missing, version-drifted from `Cargo.toml`, or reported
  stale by `cargo metadata --locked`. Fail-open when cargo or a path-dep sibling
  isn't available (fresh clone / empty offline cache) — CI's `--locked` is the
  final backstop.

The rust guards run cargo via the **rustup shim** (`~/.cargo/bin/cargo`), so a
repo's `rust-toolchain.toml` pin is honored and local fmt/clippy/metadata match
CI — a bare `cargo` may be Homebrew's, which ignores the pin.

## Declaring the required status checks (`.githooks/required-checks`)

`github-protect-main` requires status checks **by check-run name**, discovered
from recent `pull_request` runs. Discovery is additive and self-healing, but it
is still a guess at what gates a PR, and one wrong guess is unrecoverable
without admin: a required check that never reports reads as *pending* forever,
and with `enforce_admins` on, nobody can merge and there is no failure to click.

Two ways that happens:

- a workflow whose `on: pull_request:` has **`paths:` filters** doesn't start at
  all for a PR that touches nothing it watches → **no check run, blocked**;
- a job that is renamed, or refactored into a matrix (`Build` → `Build (linux)`).

(A job skipped by a job-level `if:` is *fine* — it still reports, with
conclusion `skipped`, which satisfies protection. Only a workflow that never
starts is fatal.) The guard heals the matrix-parent case from positive evidence,
but it cannot see a workflow's path filters from the API.

So a repo can just say what its gate is — an optional, committed file, one
check-run name per line:

```
# .githooks/required-checks — what must pass before main takes a merge
CI
```

- **A declaration wins over discovery, exactly** — it is also the only way to
  *remove* a required check that discovery keeps re-adding.
- **No file → nothing changes** (additive discovery, as before).
- A declared name that has neither passed on the default branch nor is already
  required is **skipped**, and applies the first time it goes green — so a typo
  can't lock the repo. If nothing declared is eligible, the current checks stay.
- Empty / comments-only is **ignored with a warning**, never read as "require
  nothing" — a file blanked mid-edit must not silently unprotect the branch.
- The single word `none` is the explicit way to require no checks.

The idiomatic content is one always-run aggregate job that `needs:` the others:

```yaml
  ci:
    name: CI
    needs: [test, lint]
    if: always()          # runs even when a dependency skipped
    runs-on: ubuntu-latest
    steps:
      - run: |
          for r in '${{ needs.test.result }}' '${{ needs.lint.result }}'; do
            case "$r" in success|skipped) ;; *) exit 1 ;; esac
          done
```

Then jobs can be renamed, split into a matrix, made conditional or
path-filtered without ever stranding a merge.

`install.sh` merges into an existing `.githooks/`, so this file survives
upgrades.

## Tests

`tests/protect-main-required-checks.sh` covers the required-check selection —
`gh` is stubbed, and the branch-protection PUT is captured instead of sent, so
the assertions are on the checks the guard would actually require. Run it
against another copy of the guards (a worktree of an older commit) to see a
regression fail:

```sh
bash .claude/skills/github-guard/tests/protect-main-required-checks.sh [githooks-dir]
```

## How to install into a target repo

The guards are **copied** into the repo's `.githooks/` as real files and
committed — so anyone who clones the repo gets them (no symlinks, nothing
pointing outside the repo). `install.sh` deploys into **one** repo; recording the
deployment and re-syncing every project later are handled by **install-skill**,
which owns the `installed_into` registry (see *Upgrading every guarded project*).

1. **Resolve the target.** Default to the repo containing the cwd
   (`git rev-parse --show-toplevel`); if cwd isn't a git repo, ask for the path.
   State the resolved path before installing.
2. **Check for a custom pre-commit.** If the target already has a custom
   `.githooks/pre-commit` (a non-dispatcher), warn that the dispatcher replaces
   it — its behavior should move into a `pre-commit.d/` guard (fmt/clippy and
   reproducible-release dep-pinning are already covered by the `rust-*` guards).
3. **Run the installer:**
   ```sh
   bash ~/.claude/skills/github-guard/install.sh <target-repo-root>
   ```
   It copies the guards into `<repo>/.githooks/` and sets `core.hooksPath`. It
   does **not** write any registry (see the next step).
4. **Report & explain:**
   - **Commit `.githooks/` — not optional; this ACTIVATES the github-* guards.**
     `github-protect-main` and `github-merge-squash-only` live in `pre-commit.d/`,
     so they only run when a commit lands on the default branch. Until you commit,
     the GitHub-side settings are NEVER applied — squash-only stays off and the
     default branch stays unprotected; the install is only half-done. Verify:
     `allow_merge_commit` is now `false` and `branches/<default>/protection`
     returns 200 (was 404).
   - **Bootstrap caveat:** that same first commit makes the default branch require
     a PR (admin-enforced, no direct push). So the `.githooks/` commit itself can
     no longer be pushed straight to the default branch — land it via a PR.
   - **Record the deployment** so it can be re-synced later: install-skill
     appends `<repo>` to `installed_into`. Simplest path: ask install-skill to
     *"deploy github-guard into `<repo>`"*, which runs this installer **and**
     records it in one step.
   - `core.hooksPath` is per-clone local config — each fresh clone runs
     `git config core.hooksPath .githooks` (or re-runs the installer).
   - The `github-*` guards need `gh` authed with admin and only act on accounts
     the user owns; otherwise they skip silently.

## Upgrading every guarded project

After changing the guards, re-sync all recorded projects via **install-skill** —
it owns the deployment registry and the fan-out; github-guard's `install.sh` is
single-target only:

> ask install-skill to **"upgrade all github-guard deployments"**

It walks `installed_into`, re-runs this installer per project (pruning any whose
directory is gone or that isn't actually a github-guard install), preserves
project-local extra guards, and diffs+asks before overwriting a locally-edited
guard. Each project keeps its own committed copy — review and commit the updated
`.githooks/` per repo.

## Add / remove / disable a guard

- **Add:** drop a `<topic>-<name>.sh` (executable) into the right `<hook>.d/`.
- **Remove:** delete it.
- **Disable without deleting:** `chmod -x` it (the dispatcher only runs
  executable scripts).

## Notes

- Emergency bypass for the hard blocks: `git … --no-verify`.
- This skill lives in the `antimatter-studios/agent-skills` monorepo and is
  promoted to `~/.claude/skills/github-guard/` via the `install-skill` flow.
