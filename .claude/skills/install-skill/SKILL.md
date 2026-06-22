---
description: Install or upgrade a skill into the user-level skills directory (`~/.claude/skills/<name>/`) so it works across all projects. Resolves the skill's source from the current repo, a registered source URL, or the agent-skills home library; copies files (no symlink) and records a manifest + a registry entry (source URL, per-skill commit, install locations) so upgrades detect drift and "install <name>" knows where to fetch from. Use when the user says "install this skill", "promote skill to user level", "install <name> skill", or "upgrade my installed <name> skill".
user-invocable: true
---

# Install Skill

Promote a skill into the user-level skills directory (`~/.claude/skills/<name>/`)
so it's available across all projects. Skills are **copied**, not symlinked, so
the install is self-contained. A per-file manifest enables drift detection, and
a registry entry records **where the skill came from** (so a later "install
`<name>`" knows where to fetch) and **where it's been deployed**.

The registry lives at `${XDG_CONFIG_HOME:-$HOME/.config}/install-skill/` — one
`<name>.json` per skill.

## Where a skill is installed *from* (resolution order)

When asked to install `<name>`, resolve the source in this order:

1. **Current repo** — if the cwd is inside a git repo that ships
   `<repo_root>/.claude/skills/<name>/`, use it. (A project that owns its own
   skill — e.g. binaryfindery.)
2. **Registered source** — else read `~/.config/install-skill/<name>.json`. Its
   `source_remote` (a GitHub URL) is the canonical home. Use the recorded
   `source_path` if it's still a valid clone; otherwise `git clone` (or
   `git pull`) `source_remote` into a cache and install from there.
3. **Home library** — else read install-skill's *own* entry
   (`~/.config/install-skill/install-skill.json`) to locate the `agent-skills`
   repo it came from, and look for `<name>` under that repo's `.claude/skills/`.

If none resolve, say you can't find that skill's source and ask for a path/URL.
With no skill named, list the `.claude/skills/` of the resolved source (and the
registry's known skills) and ask which.

## Step 1 — validate & capture the source

1. Resolve `<repo_root>` (the source repo per the order above).
2. Confirm `<repo_root>/.claude/skills/<name>/SKILL.md` exists — else refuse; it
   isn't a valid skill.

Capture:
- `source_remote`: `git -C <repo_root> remote get-url origin` (the GitHub URL —
  recorded so future installs know where to fetch from; may be empty for a
  local-only repo).
- `source_commit`: the **per-skill** commit —
  `git -C <repo_root> log -1 --format=%H -- .claude/skills/<name>` (fall back to
  `rev-parse HEAD` if there's no path history). This is what makes a monorepo
  work: a skill is "out of date" only when *its own* files change, not on every
  unrelated sibling commit.
- `source_dirty`: `git -C <repo_root> status --porcelain -- .claude/skills/<name>/`
  — if non-empty, warn that the source has uncommitted changes; ask whether to
  proceed.

## Step 2 — check the target (`~/.claude/skills/<name>/`)

**A. Doesn't exist** → fresh install. Proceed.

**B. Exists with `.install-manifest.json`** → upgrade. Compute drift: re-hash
each file in the manifest and compare to the recorded hash; any mismatch is a
user-modified ("drifted") file.
- If drift: list the files, `diff -u` each against the new source, and ask —
  **overwrite** / **skip these files** / **abort**. If unsure, suggest aborting
  and pushing the local change upstream first, or saving it aside.
- If no drift: proceed silently.

**C. Exists with NO manifest** (manual copy / pre-registry install) → stop and
ask: **overwrite** (treat as fresh) or **abort**. Never silently clobber.

## Step 3 — copy

`rsync -a --delete --exclude=.install-manifest.json <repo_root>/.claude/skills/<name>/ ~/.claude/skills/<name>/`
so files removed from the source are also removed from the target. If the user
chose "skip drifted files", add `--exclude=<path>` for each.

## Step 4 — write the manifest

`~/.claude/skills/<name>/.install-manifest.json`:

```json
{
  "name": "<name>",
  "source_remote": "<git remote url or empty>",
  "source_commit": "<per-skill subtree sha>",
  "source_path": "<absolute repo path at install time>",
  "installed_at": "<ISO 8601 UTC>",
  "skipped_drifted": ["<path>", ...],
  "files": { "<relative path>": "<sha256 hex>", ... }
}
```

Hash each file with `shasum -a 256`, paths relative to the skill root. Don't
hash the manifest itself.

## Step 5 — write the registry entry

`~/.config/install-skill/<name>.json` — **read-modify-write** (preserve fields
this skill doesn't own, e.g. `installed_into`):

```json
{
  "name": "<name>",
  "source_remote": "<git remote url>",
  "source_path": "<absolute repo skill-dir path at install time>",
  "source_commit": "<per-skill subtree sha>",
  "source_dirty": true,
  "install_path": "<~/.claude/skills/<name>>",
  "installed_at": "<ISO 8601 — set once, preserved on upgrade>",
  "updated_at": "<ISO 8601 — set every time>",
  "installed_into": [],
  "skipped_drifted": []
}
```

- The registry is a **catalog**: `skill → source URL` (where to (re)install from)
  + where it's deployed. `source_remote` answers "install from where?".
- `installed_at` is set once; `updated_at` every time.
- **`installed_into`** records projects a skill's *own* installer copied it
  into (e.g. github-guard's `install.sh` appends the repo path). install-skill
  only **initializes it to `[]` if absent and preserves it on upgrade** — never
  clobber it.
- **install-skill registers itself**: installing install-skill writes its own
  entry with `source_remote` = the `agent-skills` URL. That self-entry is what
  anchors the home library (resolution #3 above).
- Upgrade detection: compare the installed `source_commit` to the source's
  current **per-skill** commit (Step 1).

## Step 6 — report

Terse: what was installed (name + short SHA), files copied/skipped, the install
path, and — on upgrade — the previous `source_commit` for reference.

## Notes on conflicts

No three-way merge — detect drift and let the user choose. If they've modified
the installed copy AND the source moved on: (1) push the local change upstream
then re-install, (2) back up the install and re-install fresh, or (3) "skip
those files" on upgrade (risk: skipped files may reference moved bits).

## What this skill does NOT do

- Installs only `.claude/skills/<name>/` — not `.claude/commands/`, `agents/`,
  or hooks.
- Does not auto-upgrade — it'll `clone`/`pull` a registered `source_remote` when
  you ask, but it won't poll.
- Does not uninstall — `rm -rf ~/.claude/skills/<name>/` and remove
  `~/.config/install-skill/<name>.json` to keep the registry clean.
