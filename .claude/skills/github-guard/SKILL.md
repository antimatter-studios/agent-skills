---
name: github-guard
description: Install github-guard's composable git-hook guards into a repository. Ships a run-parts dispatcher for every safe client-side git hook plus a catalog of drop-in guards — linear history (squash+rebase only, block local merge commits), protect the default branch (require PRs, no direct pushes), and auto-fmt + clippy for Rust. Use when the user asks to install/add github-guard or merge-guard, protect a repo from merge commits or direct pushes to main, enforce linear history or squash-only merges, or add pre-commit fmt/clippy guards.
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
  pre-merge-commit  + pre-merge-commit.d/git-block-merge-commit.sh
  pre-push          + pre-push.d/git-block-merge-commits.sh
  lib/common.sh  lib/run-guards.sh
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
  deletion. Owner-only; never blocks.
- **`git-block-merge-commit`** (pre-merge-commit) — hard-blocks creating a merge
  commit locally.
- **`git-block-merge-commits`** (pre-push) — hard-blocks pushing any range that
  contains a merge commit.
- **`git-block-bad-files`** (pre-commit) — refuses to commit staged keys/certs,
  credential blobs, env files, OS junk, and merge cruft. Conservative (no broad
  `*secret*` globs; `.env.example` etc. allowed).
- **`git-no-trailing-whitespace`** (pre-commit) — blocks staged changes that add
  trailing whitespace / space-before-tab (`git diff --cached --check`).
- **`rust-fmt`** (pre-commit) — runs `cargo fmt` and re-stages the staged files;
  Cargo projects only; never blocks (auto-fixes layout).
- **`rust-clippy`** (pre-commit) — `cargo clippy --all-targets -- -D warnings`;
  Cargo projects only; blocks on lint failures.

## How to install into a target repo

The guards are **copied** into the repo's `.githooks/` as real files and
committed — so anyone who clones the repo gets them (no symlinks, nothing
pointing outside the repo). The install is **recorded** in `installed_into` so
the whole set can be upgraded later.

1. **Resolve the target.** Default to the repo containing the cwd
   (`git rev-parse --show-toplevel`); if cwd isn't a git repo, ask for the path.
   State the resolved path before installing.
2. **Check for a custom pre-commit.** If the target already has a custom
   `.githooks/pre-commit` (a non-dispatcher), warn that the dispatcher replaces
   it — its behavior should move into a `pre-commit.d/` guard (fmt/clippy is
   already covered by the `rust-*` guards).
3. **Run the installer:**
   ```sh
   bash ~/.claude/skills/github-guard/install.sh <target-repo-root>
   ```
   It copies the guards into `<repo>/.githooks/`, sets `core.hooksPath`, and
   records `<repo>` under `installed_into` in the registry.
4. **Report & explain:**
   - Commit `.githooks/` so the guards travel with the repo.
   - `core.hooksPath` is per-clone local config — each fresh clone runs
     `git config core.hooksPath .githooks` (or re-runs the installer).
   - The `github-*` guards need `gh` authed with admin and only act on accounts
     the user owns; otherwise they skip silently.

## Upgrading every guarded project

After changing the guards, refresh all recorded projects at once:

```sh
bash ~/.claude/skills/github-guard/install.sh --upgrade-all
```

It walks `installed_into` and re-copies fresh guards into each project (skipping
any whose directory is gone). Each project keeps its own committed copy — review
and commit the updated `.githooks/` per repo.

## Add / remove / disable a guard

- **Add:** drop a `<topic>-<name>.sh` (executable) into the right `<hook>.d/`.
- **Remove:** delete it.
- **Disable without deleting:** `chmod -x` it (the dispatcher only runs
  executable scripts).

## Notes

- Emergency bypass for the hard blocks: `git … --no-verify`.
- This skill lives in the `antimatter-studios/agent-skills` monorepo and is
  promoted to `~/.claude/skills/github-guard/` via the `install-skill` flow.
