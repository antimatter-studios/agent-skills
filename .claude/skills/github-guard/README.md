# github-guard

Composable **git-hook guards** that stop silly mistakes from creeping into a
repo while you — or an agent — work in it. Install it once as a Claude skill,
then ask Claude to drop it into any project.

Each git hook is a thin **dispatcher** that runs every executable script in its
`<hook>.d/` directory, in order. A guard is a single-purpose script you drop in
or delete. Add behaviour by adding a file; remove misbehaving behaviour by
deleting it. Nothing monolithic.

```
.git/hooks/                        # per-clone, OUTSIDE the working tree
  pre-commit                       # dispatcher → runs pre-commit.d/* in order
  pre-commit.d/
    github-auto-merge.sh           # GitHub: allow auto-merge when .github-guard says so
    github-merge-squash-only.sh    # GitHub: squash only
    github-protect-main.sh         # GitHub: require PRs, no direct pushes to default branch
    rust-fmt.sh                    # cargo fmt + re-stage (Cargo projects only)
    rust-clippy.sh                 # cargo clippy -D warnings (Cargo projects only)
    rust-deps-pinned.sh            # reproducible-release dep pinning (Cargo projects only)
  pre-merge-commit.d/git-block-merge-commit.sh
  pre-push.d/git-block-merge-commits.sh
  lib/common.sh   lib/run-guards.sh
  <documented stub for every other safe client-side hook>

.github-guard                      # in the repo: what the guards should enforce (git-config)
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

The guards land in `<repo>/.git/hooks`, and the installer clears
`core.hooksPath` (which would otherwise override them). Nothing to commit and
nothing to review — the hooks are per-clone, so each fresh clone re-runs the
installer.

Per-clone also means each copy can drift where `git status` cannot see it, so
there is a read for that:

```sh
bash .claude/skills/github-guard/status.sh -v /path/to/repo   # or no arg = cwd
```

It reports each repo as `current`, `behind` (matching an earlier release, named
by its commit), `customised` (matching no release — someone improved it in
place), `stranded` (a tracked `.githooks/` still holding guards that no longer
run), `unread` (a `.github-guard` the guards cannot parse, or a declaration
left in the old one-file-per-fact layout) or `inert` (`core.hooksPath`
overriding the lot), and exits non-zero unless everything named is current.
With `-v` it also shows what the repo's `.github-guard` declares.

**Why not an in-tree `.githooks/`?** Git resolves a hook path when it runs the
hook, which for a checkout is *after* the working tree has been rewritten. With
the hooks inside the tree, `git checkout some-forks-pr` replaces the hook that
runs on your next commit: their code, your credentials, your checkout. Reviewing
contributions locally is the normal case, so the guards live where no ref can
reach them.

## Declarations: `.github-guard`

A repo tells the guards about itself in **one file at its root**, in git-config
format (the syntax of `.git/config`; the guards read it with `git config -f`,
so there is no parser to install):

```ini
# .github-guard — declarations github-guard reads (see the skill's README)
[checks]
	required = CI                # repeat the key for more checks; `none` = require none
[merge]
	auto = true                  # allow auto-merge (see below)
[paths]
	private = tmp                # never committed; repeat for more
	generated = frontend/bindings  # machine output: whitespace tidied, never blocked
```

- **`checks.required`** — the status checks `github-protect-main` requires on the
  default branch. Overrides discovery exactly; `none` requires none; an empty
  or comment-only `[checks]` is ignored with a warning.
- **`merge.auto`** — `true` lets `github-auto-merge` turn on *Allow auto-merge*
  (only once the default branch requires status checks); `false` turns it off;
  absent changes nothing.
- **`paths.private`** / **`paths.generated`** — paths `git-block-private-paths`
  refuses to commit, and paths `generated-normalise` tidies.

`checks.required` and `merge.auto` change what GitHub enforces, so they are read
from the **default branch on the server**, never from whatever is checked out: an
edit takes effect once it is merged. The paths are read from the **working
tree**, so they work offline in a fresh clone. A clone can override the paths
with `git config --add github-guard.paths.private <path>` (and
`github-guard.paths.generated`); **per-clone config wins** where both exist.

Two syntax rules: **double-quote any value containing `#` or `;`** (both start a
comment otherwise — `required = "C# build"`), and check the file with
`git config -f .github-guard --list`. A file git cannot parse is never read as
"nothing declared": protection falls back to discovery, auto-merge is left
alone, and `git-block-private-paths` blocks until the file is fixed.

> Upgrading from the old layout — one file per fact under `.github-guard/`
> (or `.githooks/`) — means converting those files into this one; the guards no
> longer read the old paths. `install.sh` names any it finds, and renames the
> old per-clone keys `github-guard.private-path` / `generated-path` to
> `github-guard.paths.private` / `paths.generated`.

## Auto-merge

GitHub needs two things: the repository must **allow** auto-merge, and each pull
request must **ask** for it.

1. `merge.auto = true` in `.github-guard` — the `github-auto-merge` guard turns
   *Allow auto-merge* on at your next commit, and **refuses** (warning on every
   commit) while the default branch requires no status checks, because then an
   auto-merge PR would merge before CI ran. It leaves `delete_branch_on_merge`
   alone.
2. A workflow that asks, using the action in this repository:

```yaml
# .github/workflows/auto-merge.yml
name: auto-merge
on:
  pull_request:
    types: [opened, reopened, ready_for_review, synchronize]
permissions:
  contents: write
  pull-requests: write
jobs:
  auto-merge:
    runs-on: ubuntu-latest
    steps:
      - uses: antimatter-studios/agent-skills/.github/actions/auto-merge@<full commit sha> # pin by SHA
```

The action runs `gh pr merge --auto --squash` only for a pull request from the
**same repository** (never a fork), into the **default branch**, not a draft,
and only when `.github-guard` **on the default branch** says `merge.auto = true`
— a PR cannot enable it for itself by editing the file. Pin it by full SHA: it
runs with write permissions. A merge made by the default `GITHUB_TOKEN` does not
trigger `on: push` workflows; pass `with: github-token:` an App or fine-grained
token if something must run after the merge.

### Release notes in CI

`git-changelog` refuses to push a version tag the changelog does not document.
The same extraction produces the release body, exposed as an action so a CI
checkout needs no copy of the guard:

```yaml
      - id: notes
        uses: antimatter-studios/agent-skills/.github/actions/changelog-notes@<sha>
        with:
          tag: ${{ github.ref_name }}
      - run: gh release create "$TAG" --notes-file '${{ steps.notes.outputs.file }}'
```

### Self-hosting (this repo)

github-guard guards itself the same way every other repo does:

```sh
bash .claude/skills/github-guard/install.sh .
```

Re-run it after editing a guard. This repo used to point `core.hooksPath`
straight at `.claude/skills/github-guard/githooks` so an edit took effect with no
re-install — but that is the in-tree arrangement above, and here it is the worst
case of it: the hooks git executes would be whatever the branch under review says
they are, in the repo whose job is guarding all the others. The drift that recipe
avoided is gone anyway, since the installed copy is no longer a committed one.

## Guards it ships

| Guard | Hook | Blocks? | What |
|---|---|---|---|
| `github-auto-merge` | pre-commit | no (fail-open) | Reconciles *Allow auto-merge* with `merge.auto` in `.github-guard` (server copy); refuses to enable it while the default branch requires no status checks. Owner-only. |
| `github-merge-squash-only` | pre-commit | no (fail-open) | Heals the GitHub repo to **squash only** (`allow_merge_commit=false`, `allow_rebase_merge=false`). Owner-only. |
| `github-protect-main` | pre-commit | no (fail-open) | Protects the **default branch**: require a PR, enforced for admins, linear history, no force-push/deletion. Owner-only. |
| `git-block-merge-commit` | pre-merge-commit | yes | Refuses to **create** a merge commit locally. |
| `git-block-merge-commits` | pre-push | yes | Refuses to **push** a range containing a merge commit. |
| `git-block-bad-files` | pre-commit | yes | Refuses staged keys/certs, credential blobs, env files, OS junk, merge cruft. Conservative (no broad `*secret*`; `.env.example` allowed). |
| `git-no-trailing-whitespace` | pre-commit | yes | Blocks staged changes that add trailing whitespace / space-before-tab. |
| `git-block-private-paths` | pre-commit | yes | Refuses to commit anything under `paths.private`. No declaration, no opinion; an unparseable `.github-guard` blocks. |
| `generated-normalise` | pre-commit | no | Strips trailing whitespace under `paths.generated` and re-stages. |
| `git-block-large-files` | pre-commit | yes | Blocks staged files over a limit (default 10 MiB, `GITHUB_GUARD_MAX_FILE_MB`) unless LFS-tracked. |
| `git-changelog` | pre-push | yes | On a version-tag push, requires the release documented in CHANGELOG.md / README changelog (≤10 in README + link). Self-gates if no changelog. |
| `git-tags-on-main` | pre-push | yes | Blocks pushing a **tag** whose commit isn't on the default branch (`main`) — release tags must mark a commit that landed on main, not one stranded on a feature/pre-squash line. Purely local; peels annotated tags. |
| `rust-fmt` | pre-commit | no | `cargo fmt` then re-stage. Cargo projects only. |
| `rust-clippy` | pre-commit | yes | `cargo clippy --all-targets -- -D warnings`. Cargo projects only; skips (doesn't block) when a `path=` sibling dep isn't checked out. |
| `rust-deps-pinned` | pre-commit | yes | Reproducible-release gate: blocks a floating workflow clone/`checkout` of a same-owner sibling repo (no `--branch`/`ref:`), and a `Cargo.lock` that's missing/version-drifted/stale. Cargo projects only; fail-open when cargo/siblings unavailable. |

Every guard **self-gates**: `rust-*` skip without a `Cargo.toml`; `github-*`
skip on repos you don't own or non-GitHub remotes; the path guards do nothing
without a declaration. So the same set installs everywhere and each guard
decides if it's relevant.

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
shipped `githooks/` payload doubles as a catalog you can learn from. Open any stub to
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
| `pre-receive`, `update`, `post-receive`, `post-update` | **Server-side** — they run on the receiving repo, not from a local hooks directory, so a local file would never fire. |

## Why a hook (and not only a GitHub ruleset)

A GitHub **org ruleset** is the strongest server-side enforcement, but a
portable hook fills its gaps: rulesets are per-org and a **new org you create
doesn't inherit them**; **personal accounts** have no account-wide ruleset; and
a ruleset needs org-admin and can be silently turned off. This hook travels with
you regardless of org/account tier, and the `github-*` guards self-heal the
server settings on accounts you own as you work.
