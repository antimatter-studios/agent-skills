# Future: distribute agent-skills as a plugin marketplace

**Status:** not started. Deliberately deferred — see [When to revisit](#when-to-revisit).

This repo hand-rolls skill distribution via the **install-skill** skill. Claude
Code ships a plugin/marketplace system that does most of the same job, and does
it mechanically. This note records what was compared, what would actually be
replaced, what would not, and the trigger for doing the work — so the analysis
doesn't have to happen twice.

## The problem this would solve

Getting a skill from this repo onto a machine currently takes a bootstrap step
that can't be automated away:

> Bootstrap: on a fresh machine, copy `install-skill` into `~/.claude/skills/`
> once by hand, then use it to install the rest.

That is a chicken-and-egg problem inherent to a self-hosted installer. The
plugin system doesn't have it — the client already knows how to fetch a
marketplace:

```
/plugin marketplace add antimatter-studios/agent-skills
```

Everything else below is secondary to that.

## What the plugin system already does

Verified against the plugin state on a machine with plugins installed, not from
memory. Three moving parts:

**1. Marketplace manifest** — `.claude-plugin/marketplace.json` at repo root,
listing one or more plugins:

```json
{
  "name": "antimatter-skills",
  "owner": { "name": "..." },
  "plugins": [
    { "name": "antimatter-skills", "source": "./", "description": "..." }
  ]
}
```

`source` is either a relative path in the same repo (`"./plugins/foo"`) or a
cross-repo pin:

```json
"source": {
  "source": "git-subdir",
  "url": "https://github.com/owner/repo.git",
  "path": "plugins/thing",
  "ref": "v1.5.5",
  "sha": "30287f5e3f122a646d1ac5ca3ab96e130c52a3ad"
}
```

**2. Plugin manifest** — `<plugin>/.claude-plugin/plugin.json`:

```json
{
  "name": "superpowers",
  "version": "6.2.0",
  "description": "Core skills library for Claude Code: ...",
  "author": { "name": "...", "email": "..." },
  "repository": "https://github.com/obra/superpowers",
  "license": "MIT",
  "keywords": ["skills", "tdd", "debugging"]
}
```

**3. Skills** — `<plugin>/skills/<name>/SKILL.md`. Note `skills/`, not
`.claude/skills/`. The `superpowers` plugin declares no explicit skills path and
relies on that convention; a sibling manifest in the same package spells it out
as `"skills": "./skills/"`, so an explicit key exists if the default ever proves
ambiguous. Confirm before relying on the implicit form.

The client then handles fetch, version resolution, and update, caching to
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` and recording each
install in `~/.claude/plugins/installed_plugins.json`:

```json
"superpowers@claude-plugins-official": [
  {
    "scope": "user",
    "installPath": ".../cache/claude-plugins-official/superpowers/6.2.0",
    "version": "6.2.0",
    "installedAt": "...",
    "lastUpdated": "...",
    "gitCommitSha": "2cd88e7947b7382e045666abee790c7f55f669f3"
  }
]
```

**`superpowers` is the exact precedent**: a plugin whose entire payload is a
skills library. This repo is that, with a different directory name.

## What would be replaced

| install-skill responsibility | Plugin equivalent |
|---|---|
| Registry at `~/.config/install-skill/<name>.json` | `installed_plugins.json` + `known_marketplaces.json` |
| `source_commit` per skill | `gitCommitSha` per plugin install |
| Copy into `~/.claude/skills/<name>/` | Versioned cache, client-managed |
| Upgrade + drift detection vs source | `/plugin` update against a pinned sha |
| **Hand-copy bootstrap** | **`/plugin marketplace add`** |

Maintained by Anthropic rather than by us, which is the durable win — this is
distribution plumbing, and we gain nothing by owning it.

## What would NOT be replaced

**Project payload deployment.** install-skill's second job is copying a payload
*into an individual repo* and remembering it did:

> Some skills don't just live in `~/.claude/skills/` — they copy a payload into
> individual projects.

github-guard is the whole reason this exists. It copies a `.githooks/` tree into
a target repo, sets `core.hooksPath`, and records the deployment so
"upgrade all github-guard deployments" can re-sync every project later.

The plugin system makes a skill *available to Claude*. It does not write files
into arbitrary repositories, and it does not track which repositories received
them. **No part of that is replaced.**

So the outcome is not "delete install-skill." It is "cut install-skill in half":
the distribution half goes, the deployment half stays and probably gets renamed
to something honest like `deploy-payload`.

## The real cost: it changes the authoring loop

The current workflow is edit-in-place:

1. Edit `~/.claude/skills/<name>/SKILL.md` directly.
2. Use it live; iterate until it's right.
3. Push upstream when it settles.

install-skill's per-file sha256 drift detection exists *specifically* to support
step 3 — it notices the installed copy moved ahead of source and offers to
reconcile.

The plugin cache is version-stamped and client-managed. Editing inside it fights
the tool and gets clobbered on update. Post-migration the loop becomes: edit in
the repo clone, bump `version` in `plugin.json`, reinstall to exercise it.

That is strictly worse while a skill is being actively written, and strictly
better once it is stable. **This trade — not any technical blocker — is why the
work is deferred.**

## When to revisit

Convert when the answer to all of these is yes:

- [ ] The skills are edited **monthly rather than daily** — the edit-in-place
      loop is no longer load-bearing.
- [ ] There is a **second machine** that needs them, making the bootstrap step a
      recurring cost rather than a one-off.
- [ ] Nobody outside is depending on the current `.claude/skills/<name>/` paths.

Any "no" means the marketplace is distribution value we aren't yet collecting,
paid for with authoring friction we would feel immediately.

## Migration sketch

Roughly, when the time comes:

1. **One plugin, not one per skill.** `antimatter-skills` containing all of
   them. Per-skill granularity means a `plugin.json` per skill for no benefit
   while we are the only consumer. Revisit only if someone wants `github-guard`
   without the rest.
2. Move `.claude/skills/<name>/` → `skills/<name>/`. Keeping a project-level
   `.claude/skills/` in this repo as well is possible but means two copies to
   keep in sync — prefer moving outright.
3. Add `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.
4. Adopt semver in `plugin.json`. The client keys its cache on version, so
   bumping it is what makes an update visible.
5. Strip install-skill down to payload deployment + deployment tracking; delete
   the registry, source-resolution and drift-detection code the client now owns.
6. Rewrite the README `## Use` section around `/plugin marketplace add` and
   delete the bootstrap paragraph.
7. Verify the CI script sweep still finds `github-guard`'s hooks after the move
   — it collects by shebang under any path, so it should, but it is the one
   thing the restructure could plausibly break.

## Open questions

- Does a plugin-provided skill resolve a cross-reference to a skill installed by
  a *different* mechanism? Several skills here name each other
  (`human-code` → `dev-loop`, `pr` → `commit`). If resolution is scoped per
  plugin rather than global across `~/.claude/skills/`, migrating a subset
  breaks those references and the migration has to be all-or-nothing.
- Can a plugin ship `install.sh`-style executables that the user runs directly,
  the way `github-guard/install.sh` is run today, given the cache path contains
  a version number?
- Is there a per-machine override for a plugin's install scope, or is `user`
  scope always `~/.claude/plugins/cache/`?

## Background

Analysis done 2026-08-02, alongside the PR promoting `dev-loop`, `human-code`,
`commit` and `pr` into this repo. That PR is what surfaced the question: those
four had no registry entry and no manifest, so they are tracked by nothing at
all today — which prompted asking whether the tracking mechanism should be ours
in the first place.
