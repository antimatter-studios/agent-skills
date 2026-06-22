# github-guard

Composable **git-hook guards** that stop silly mistakes from creeping into a
repo while you — or an agent — work in it. Install it once as a Claude skill,
then ask Claude to drop it into any project.

Each git hook is a thin **dispatcher** that runs every executable script in its
`<hook>.d/` directory, in order. A guard is a single-purpose script you drop in
or delete. Add behaviour by adding a file; remove misbehaving behaviour by
deleting it. Nothing monolithic.

```
.githooks/
  pre-commit                       # dispatcher → runs pre-commit.d/* in order
  pre-commit.d/
    github-merge-squash-only.sh    # GitHub: squash+rebase only
    github-protect-main.sh         # GitHub: require PRs, no direct pushes to default branch
    rust-fmt.sh                    # cargo fmt + re-stage (Cargo projects only)
    rust-clippy.sh                 # cargo clippy -D warnings (Cargo projects only)
  pre-merge-commit.d/git-block-merge-commit.sh
  pre-push.d/git-block-merge-commits.sh
  lib/common.sh   lib/run-guards.sh
  <documented stub for every other safe client-side hook>
```

## Install

**1. As a Claude skill (once per machine).** This repo ships the skill at
`.claude/skills/github-guard/`. Promote it into Claude with the `install-skill`
flow (clone this repo, then ask Claude to install the skill from it).

**2. Into a project (any time).** Ask Claude *"install github-guard into this
project"*, or run the installer directly:

```sh
bash .claude/skills/github-guard/install.sh /path/to/repo   # or no arg = cwd
```

Commit the resulting `.githooks/` so it travels with the repo. `core.hooksPath`
is per-clone local config, so each fresh clone re-runs the installer (or
`git config core.hooksPath .githooks`).

### Self-hosting (this repo)

github-guard guards itself, but it does **not** use a copied `.githooks/` — its
canonical hooks already live in `.claude/skills/github-guard/githooks/`, so a
copy would just drift every time we edit a guard (the exact silly error this
tool exists to stop). Instead, point git straight at the source:

```sh
git config core.hooksPath .claude/skills/github-guard/githooks
```

Run that once per clone. Editing a guard then takes effect immediately — no
re-install. (Every *other* repo gets the standard `install.sh` layout above.)

## Guards it ships

| Guard | Hook | Blocks? | What |
|---|---|---|---|
| `github-merge-squash-only` | pre-commit | no (fail-open) | Heals the GitHub repo to **squash+rebase only** (`allow_merge_commit=false`). Owner-only. |
| `github-protect-main` | pre-commit | no (fail-open) | Protects the **default branch**: require a PR, enforced for admins, linear history, no force-push/deletion. Owner-only. |
| `git-block-merge-commit` | pre-merge-commit | yes | Refuses to **create** a merge commit locally. |
| `git-block-merge-commits` | pre-push | yes | Refuses to **push** a range containing a merge commit. |
| `git-block-bad-files` | pre-commit | yes | Refuses staged keys/certs, credential blobs, env files, OS junk, merge cruft. Conservative (no broad `*secret*`; `.env.example` allowed). |
| `git-no-trailing-whitespace` | pre-commit | yes | Blocks staged changes that add trailing whitespace / space-before-tab. |
| `git-block-large-files` | pre-commit | yes | Blocks staged files over a limit (default 10 MiB, `GITHUB_GUARD_MAX_FILE_MB`) unless LFS-tracked. |
| `git-changelog` | pre-push | yes | On a version-tag push, requires the release documented in CHANGELOG.md / README changelog (≤10 in README + link). Self-gates if no changelog. |
| `rust-fmt` | pre-commit | no | `cargo fmt` then re-stage. Cargo projects only. |
| `rust-clippy` | pre-commit | yes | `cargo clippy --all-targets -- -D warnings`. Cargo projects only. |

Every guard **self-gates**: `rust-*` skip without a `Cargo.toml`; `github-*`
skip on repos you don't own or non-GitHub remotes. So the same set installs
everywhere and each guard decides if it's relevant.

### Add / remove / disable

- **Add:** drop a `<topic>-<name>.sh` (executable) into the right `<hook>.d/`.
- **Remove:** delete it.
- **Disable without deleting:** `chmod -x` it.

### Knobs

- Emergency bypass for the hard blocks: `git … --no-verify`.
- `github-*` guards need [`gh`](https://cli.github.com) authed with repo admin;
  without it they print a notice and skip (never block).

## Git hook reference

github-guard ships a documented dispatcher stub for every **client-side** hook
that is safe to no-op (present-and-exit-0 behaves the same as absent), so the
`.githooks/` directory doubles as a catalog you can learn from. Open any stub to
read when it fires and what it's for.

**Shipped as dispatchers:** `applypatch-msg`, `pre-applypatch`,
`post-applypatch`, `pre-commit`, `prepare-commit-msg`, `commit-msg`,
`post-commit`, `pre-merge-commit`, `post-merge`, `pre-rebase`, `post-checkout`,
`post-rewrite`, `pre-push`, `pre-auto-gc`, `sendemail-validate`.

**Deliberately not shipped** (documented here instead):

| Hook | Why not a stub |
|---|---|
| `push-to-checkout` | If the hook exists, git delegates the checkout to it — a no-op would break the push. |
| `fsmonitor-watchman` | Only invoked when `core.fsmonitor` points at it, and speaks a specific protocol; a generic stub would break fsmonitor. |
| `proc-receive` | Speaks a version-negotiation protocol over stdin/stdout; not a no-op-safe guard point. |
| `reference-transaction`, `post-index-change` | Fire on nearly every ref/index update — too hot to host a per-event dispatcher by default. Add one yourself if you truly need it. |
| `pre-receive`, `update`, `post-receive`, `post-update` | **Server-side** — they run on the receiving repo, not via a local `core.hooksPath`, so a local file would never fire. |

## Why a hook (and not only a GitHub ruleset)

A GitHub **org ruleset** is the strongest server-side enforcement, but a
portable hook fills its gaps: rulesets are per-org and a **new org you create
doesn't inherit them**; **personal accounts** have no account-wide ruleset; and
a ruleset needs org-admin and can be silently turned off. This hook travels with
you regardless of org/account tier, and the `github-*` guards self-heal the
server settings on accounts you own as you work.
