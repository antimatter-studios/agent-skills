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

## Use

Clone this repo, then promote a skill with **install-skill** (run it from here;
it lists the skills under `.claude/skills/` and installs the one you pick).

Bootstrap: on a fresh machine, copy `install-skill` into `~/.claude/skills/`
once by hand, then use it to install the rest.
