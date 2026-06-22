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
- **`rust-fmt`** (pre-commit) — runs `cargo fmt` and re-stages the staged files;
  Cargo projects only; never blocks (auto-fixes layout).
- **`rust-clippy`** (pre-commit) — `cargo clippy --all-targets -- -D warnings`;
  Cargo projects only; blocks on lint failures.

## How to install into a target repo

1. **Resolve the target.** Default to the repo containing the cwd
   (`git rev-parse --show-toplevel`). If cwd isn't in a git repo, ask for the
   path. State the resolved path before installing.
2. **Check for an existing hooks setup.** If the target already sets
   `core.hooksPath` to something *other than* `.githooks`, warn the user — the
   installer copies into `.githooks/` but won't repoint `core.hooksPath`. If the
   target already has a custom `.githooks/pre-commit` (a non-dispatcher), tell
   the user it will be replaced by the dispatcher; its behavior should move into
   a guard script in `pre-commit.d/` (e.g. fmt/clippy is already covered by the
   `rust-*` guards).
3. **Run the installer:**
   ```sh
   bash ~/.claude/skills/github-guard/install.sh <target-repo-root>
   ```
4. **Report & explain:**
   - Commit `.githooks/` so the guards travel with the repo.
   - `core.hooksPath` is per-clone local config — each fresh clone re-runs the
     installer (or `git config core.hooksPath .githooks`).
   - The `github-*` guards need `gh` authed with admin on the repo, and only act
     on accounts the user owns; otherwise they skip silently.
5. **Offer to commit** `.githooks/`.

## Add / remove / disable a guard

- **Add:** drop a `<topic>-<name>.sh` (executable) into the right `<hook>.d/`.
- **Remove:** delete it.
- **Disable without deleting:** `chmod -x` it (the dispatcher only runs
  executable scripts).

## Notes

- Emergency bypass for the hard blocks: `git … --no-verify`.
- This skill lives in the `antimatter-studios/agent-skills` monorepo and is
  promoted to `~/.claude/skills/github-guard/` via the `install-skill` flow.
