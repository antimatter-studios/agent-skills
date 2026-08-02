# agent-skills

A monorepo of reusable agent skills (Claude Code today, agent-agnostic where it
can be). Each skill lives under `.claude/skills/<name>/` with a `SKILL.md`.

## Skills

- **[github-guard](.claude/skills/github-guard/README.md)** — composable
  git-hook guards that stop silly mistakes (linear history, branch protection,
  squash-only merges, Rust fmt/clippy). A run-parts dispatcher per hook; guards
  are single-purpose scripts you drop in or delete.
- **install-skill** — promotes a skill from a repo's `.claude/skills/<name>/`
  into `~/.claude/skills/<name>/` so it works across all projects. Records a
  manifest + a registry under `~/.config/install-skill/` (per-skill source
  commit, install locations) so upgrades can detect drift.
- **dev-loop** — iterative development cycle built on a baseline test contract:
  capture every passing test by name before touching anything, then require that
  exact set to still pass after each change. Coverage floor, one concern per
  iteration, static analysis at the end.
- **human-code** — refactors for human readability. Finds magic numbers, god
  functions, duplication, dense expressions and deep nesting, triages them by
  severity, and hands the confirmed list to **dev-loop** so every fix is
  test-gated. Writes a before/after report.
- **commit** — turns an uncommitted working tree into small, topic-focused
  commits, one logical unit each. Installs the repo's git hooks first, refuses
  files that should never be committed, and never bundles unrelated changes.
- **pr** — takes working-tree changes or existing commits and lands them as pull
  requests, using **commit** for the grouping. Multi-repo aware: parent project
  and vendored submodules each get their own PRs, opened in dependency order.

## Use

Clone this repo, then promote a skill with **install-skill** (run it from here;
it lists the skills under `.claude/skills/` and installs the one you pick).

Bootstrap: on a fresh machine, copy `install-skill` into `~/.claude/skills/`
once by hand, then use it to install the rest.
