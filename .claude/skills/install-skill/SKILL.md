---
description: Install or upgrade a project-local Claude Code skill from the current repo's `.claude/skills/<name>/` into `~/.claude/skills/<name>/` so it works system-wide. Copies files (does not symlink) and records a manifest so future upgrades can detect when the user has hand-modified the installed copy. Use when the user says "install this skill", "promote skill to user level", "upgrade my installed <name> skill", or similar.
user-invocable: true
---

# Install Skill (project → user)

Promote a skill that ships inside a project repo (`<repo>/.claude/skills/<name>/`) to the user-level skills directory (`~/.claude/skills/<name>/`) so it is available across all projects.

Skills are **copied**, not symlinked, so the user-level install is self-contained. A manifest is written alongside the install so subsequent upgrades can detect when the user has modified the installed copy (a "drifted" install).

## Inputs

- Skill name (optional). If omitted, list every directory under `.claude/skills/` in the current working tree and ask which one.
- `--force` style intent from the user (overwrite drift without asking). If not given, default to **stop and ask** on drift.

## Step 1: Locate the source

1. From the current working directory, walk up to the git root (`git rev-parse --show-toplevel`).
2. Confirm `<repo_root>/.claude/skills/` exists. If not, tell the user this command must be run from inside a repo that ships a skill, and stop.
3. If the user named a skill, confirm `<repo_root>/.claude/skills/<name>/` exists. Otherwise, list `ls <repo_root>/.claude/skills/` and ask which to install.
4. Confirm the source contains a `SKILL.md`. If not, refuse — it isn't a valid skill.

Capture for the manifest:
- `source_remote`: `git -C <repo_root> remote get-url origin` (may be empty — that's fine)
- `source_commit`: `git -C <repo_root> rev-parse HEAD`
- `source_dirty`: `git -C <repo_root> status --porcelain -- .claude/skills/<name>/` — if non-empty, warn the user that the source has uncommitted changes; ask whether to proceed.

## Step 2: Check the target

Target is `~/.claude/skills/<name>/`.

Three cases:

**A. Target does not exist** → fresh install. Proceed to Step 3.

**B. Target exists with a manifest** at `~/.claude/skills/<name>/.install-manifest.json` → upgrade path. Compute drift:

```bash
# For each file in the manifest, hash the current installed version and compare.
# Report any path where the live hash != manifest hash. Those are user-modified.
```

If drift is detected:
- List the drifted files.
- Show the user a diff between each drifted file and the new source version (`diff -u`).
- Ask: **overwrite** (lose local changes), **skip these files** (keep local, upgrade the rest), or **abort**.
- If the user is unsure, suggest aborting and either committing their local changes upstream (into the project repo) or saving them aside (`cp <file> <file>.local`) before re-running.

If no drift, proceed to Step 3 silently.

**C. Target exists with NO manifest** → installed by some other means (manual copy, older version of this skill, different repo). Stop and tell the user. Offer: **overwrite** (treat as fresh install), or **abort**. Do not silently clobber.

## Step 3: Copy

1. `mkdir -p ~/.claude/skills/<name>/`
2. Copy every file under `<repo_root>/.claude/skills/<name>/` to `~/.claude/skills/<name>/`, preserving the relative tree. Exclude any `.install-manifest.json` in the source (shouldn't be there, but guard against it).
3. Use `cp -R` or `rsync -a --delete` so that files removed in the new source are also removed from the target. `rsync -a --delete --exclude=.install-manifest.json` is the cleanest.
4. If the user chose "skip drifted files" in Step 2, exclude those paths from the copy (`--exclude=<path>` for each).

## Step 4: Write the manifest

Write `~/.claude/skills/<name>/.install-manifest.json`:

```json
{
  "name": "<name>",
  "source_remote": "<git remote url or empty>",
  "source_commit": "<sha>",
  "source_path": "<absolute path to the repo at install time, informational only>",
  "installed_at": "<ISO 8601 UTC timestamp>",
  "skipped_drifted": ["<path>", ...],
  "files": {
    "<relative path>": "<sha256 hex>",
    ...
  }
}
```

Hash each file with `shasum -a 256`. Use paths relative to the skill root. Do not hash the manifest itself.

## Step 5: Write the XDG registry entry

The registry lives at `${XDG_CONFIG_HOME:-$HOME/.config}/install-skill/`. Create the directory if it does not exist.

Write `<registry_dir>/<name>.json`:

```json
{
  "name": "<name>",
  "source_path": "<absolute path to repo skill dir at install time>",
  "source_remote": "<git remote url or empty>",
  "source_commit": "<sha>",
  "source_dirty": true | false,
  "install_path": "<absolute path to ~/.claude/skills/<name>>",
  "installed_at": "<ISO 8601 UTC — set once on first install, never changed on upgrade>",
  "updated_at": "<ISO 8601 UTC — set on every install or upgrade>",
  "skipped_drifted": ["<relative path>", ...]
}
```

- `installed_at` is set **once** on the first install. On upgrades, read the existing value and preserve it.
- `updated_at` is always the current timestamp.
- `source_dirty` mirrors the warning from Step 1.

This registry enables listing all installed skills (`ls <registry_dir>` or reading each JSON), detecting which skills can be upgraded (compare `source_commit` to current HEAD of the source repo), and locating the original source repo for each skill.

## Step 6: Report

Tell the user:
- What was installed (name + source commit short SHA).
- How many files copied, how many skipped (if any).
- Path to the installed skill.
- If this was an upgrade, the previous `installed_at` and `source_commit` for reference.

Keep it terse — one short block.

## Notes on conflicts (for when the user asks)

This skill records a manifest so it can *detect* drift but does not do three-way merges. If the user has both modified their installed copy AND the source has moved on, the only resolutions are:

1. **Push local changes upstream** — copy their modifications into the project's `.claude/skills/<name>/`, commit, then re-run install. This is the right move if the change is generally useful.
2. **Stash local changes** — `cp -R ~/.claude/skills/<name> ~/.claude/skills/<name>.local-backup`, install fresh, then re-apply local edits by hand from the backup.
3. **Skip on upgrade** — use the "skip these files" option to keep local edits and only upgrade non-drifted files. Risk: the skipped files may reference moved/renamed bits from the rest of the skill. Tell the user this when offering the option.

## What this skill does NOT do

- Does not install from a remote URL — the user clones the repo themselves, then runs this from inside it.
- Does not install `.claude/commands/`, `.claude/agents/`, or hooks — only `.claude/skills/<name>/`.
- Does not auto-upgrade — must be re-run manually after `git pull` in the source repo.
- Does not uninstall — `rm -rf ~/.claude/skills/<name>/` removes the skill, but also remove `${XDG_CONFIG_HOME:-$HOME/.config}/install-skill/<name>.json` to keep the registry clean.
