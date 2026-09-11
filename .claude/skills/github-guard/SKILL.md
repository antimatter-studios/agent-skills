---
name: github-guard
description: Install github-guard's composable git-hook guards into a repository. Ships a run-parts dispatcher for every safe client-side git hook plus a catalog of drop-in guards — linear history (squash-only merges, block local merge commits), protect the default branch (require PRs, no direct pushes), and auto-fmt + clippy + reproducible-release dependency-pinning for Rust. Use when the user asks to install/add github-guard or merge-guard, protect a repo from merge commits or direct pushes to main, enforce linear history or squash-only merges, or add pre-commit fmt/clippy guards.
---

# github-guard

A composable set of **git-hook guards** that stop silly mistakes from creeping
into a repo while you (or an agent) work in it. Each git hook is a thin
**dispatcher** that runs every executable script in its `<hook>.d/` directory;
each guard is a single-purpose script you drop in or delete.

```
.git/hooks/                  # per-clone, OUTSIDE the working tree: no branch can rewrite it
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
  …documented stubs for every other safe client-side hook (no-op until you add guards)

.githooks/                   # the only github-guard file still IN the repo
  required-checks            # optional: the status checks main must require
```

**Where the hooks live, and why it matters.** Git resolves a hook path when it
runs the hook — for a checkout, *after* the working tree has been rewritten. An
in-tree hooks directory reached via `core.hooksPath` therefore lets any branch
you check out replace the hook that runs next, with your credentials and your
gh token. So `install.sh` writes into `<repo>/.git/hooks` and CLEARS
`core.hooksPath`. `required-checks` is the exception that stays in the tree: it
is data, not code, and `github-protect-main` reads it from the default branch on
the **server**, never from the checkout.

**Naming:** guards are `<topic>-<name>.sh`. The topic prefix groups them and
shows the domain at a glance (`github-*`, `git-*`, `rust-*`, …). They run in
lexical order; wedge a number (`rust-05-…`) if order matters.

**Convention every guard follows:** self-gate, then no-op if it doesn't apply
(`rust-*` skip without a `Cargo.toml`; `github-*` skip on repos you don't own
or non-GitHub remotes). So the whole set is uniform to install and
self-selecting at runtime — no per-project config.

## Shipped guards

- **`github-merge-squash-only`** (pre-commit, fail-open) — heals the GitHub repo
  to SQUASH ONLY — `allow_squash_merge=true`, `allow_merge_commit=false`,
  `allow_rebase_merge=false`. One commit per pull request: a branch's WIP history is
  noise once it lands, and the squash message is written deliberately instead of
  composed by GitHub from whatever the commits happened to say. Squash locally first
  when a branch is messy, so that message is yours. Owner-only; never blocks.
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

- **`go-fmt`** (pre-commit) — formats the staged Go with **gofumpt** when it is
  installed and gofmt otherwise, and re-stages it; never blocks. gofumpt is the
  strict superset a project's `.golangci.yml` may demand, and formatting to the
  weaker standard only to be failed by the linter is the outcome worth avoiding.
- **`go-vet`** (pre-commit) — `go vet ./...`, blocks on a finding. Go modules
  only, and only when the commit touches Go. Fails **open** when the module
  cannot build for a reason that is not the code — an embed directive whose
  target has not been built yet, keyed on go's own *"pattern …: no matching
  files found"* — because a fresh clone that can commit nothing is worse than a
  missed vet.
- **`go-test`** (pre-push, **ships disarmed**) — `go test ./...`, blocks the
  push on failure. Not executable in the payload: running a whole suite is a
  per-project decision. `chmod +x .git/hooks/pre-push.d/go-test.sh` arms it, and
  re-running the installer leaves that mode alone.
- **`python-fmt`** (pre-commit) — `ruff format` on the staged Python, re-staged;
  never blocks. Prefers the project's `.venv/bin/ruff`, whose version is the one
  the project pinned — a different ruff on `PATH` reformats the same file the
  other way on alternate commits.
- **`python-lint`** (pre-commit) — `ruff check` on the staged Python only, and
  **blocks**: a lint finding says the code is wrong, not untidy, and ruff is too
  fast to be worth deferring to CI. Checking only staged files means someone
  else's pre-existing finding cannot block your commit.
- **`js-fmt`** (pre-commit) — prettier on staged JS/TS/CSS/HTML/JSON (not
  Markdown: prettier rewraps prose and rebuilds tables, and quietly reflowing a
  hand-written document is a different proposition from tidying code),
  re-staged; never blocks. Uses the **nearest** `node_modules/.bin/prettier`,
  walking up from each file, so a web project in a subdirectory is formatted by
  its own prettier with its own config; a global one formats to a different
  major's defaults than the project's CI checks.
- **`git-block-private-paths`** (pre-commit) — refuses to commit anything under
  a path the repo declared private (see below). `.gitignore` covers the accident
  until someone runs `git add -f`; this is the wall for material that must not
  reach the published repo. No declaration, no opinion.
- **`generated-normalise`** (pre-commit) — strips trailing whitespace from
  staged files under a declared *generated* path and re-stages them; never
  blocks. Sorts before `git-no-trailing-whitespace` deliberately: generators
  emit trailing spaces in doc comments, and without this every regeneration
  needs `--no-verify`, which disables every other guard too.

Every formatting guard re-stages **only fully-staged files**. Formatting
rewrites a file's whole on-disk content, so `git add`-ing it afterwards would
also stage the unstaged edits sitting in it — silently sweeping
work-in-progress into a commit. A partially-staged file is left alone, with a
notice, and its staged snapshot commits unformatted.

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
- **It is read from the default branch on the server, not the working tree.**
  The file can strip required checks, and `none` strips them all, so it is a
  privileged input and must come from a trusted source. This guard runs
  pre-commit against whatever happens to be checked out; reading the working
  tree would let an untrusted branch — a contributor PR pulled down for review —
  unprotect the branch the moment the owner commits while it is checked out.
  Reading the committed default-branch copy means a policy change only takes
  effect once it is merged. Unreachable (404, offline, no `jq`) falls through to
  discovery — never to "require nothing".
- **No file → nothing changes** (additive discovery, as before).
- A declared name that has neither passed on the default branch nor is already
  required is **skipped**, and applies the first time it goes green — so a typo
  can't lock the repo. If nothing declared is eligible, the current checks stay.
- While any declared check is still skipped, the eligible ones are **unioned**
  with what is already required rather than replacing it. A half-eligible
  declaration would otherwise drop checks the full declaration never asked to
  remove, leaving a weaker gate than before it was written. The exact
  "declared wins" replace applies only once every declared check is eligible.
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

`install.sh` never writes into the working tree, so this file is untouched by an
install or an upgrade.

## Release notes from the changelog (CI)

`git-changelog` blocks a version tag whose changelog section is missing. The
same extraction writes the release body, so the thing that gates the tag and
the thing that publishes the release cannot disagree:

```sh
.git/hooks/pre-push.d/git-changelog.sh notes v1.4.0    # locally
```

A CI checkout cannot see `.git/hooks`, so the same script is exposed as a
composite action in this repository:

```yaml
      - id: notes
        uses: antimatter-studios/agent-skills/.github/actions/changelog-notes@<sha>
        with:
          tag: ${{ github.ref_name }}
      - run: gh release create "$TAG" --notes-file '${{ steps.notes.outputs.file }}'
```

Inputs: `tag` (required, leading `v` optional), `path` (the repo to read,
default `.`), `output-file` (default under `RUNNER_TEMP`). Output: `file`. A
version with no changelog section **fails the step** — a release published with
empty notes is the mistake nobody notices.

Pin the `@<sha>`, as with any third-party action. The action's own repository is
checked out by the runner, so there is no copy of the script in the caller:
two repos previously kept an entire stale hook tree in-tree purely to reach
this one file from their release workflow, and their copy of the extraction had
started to diverge from the guard's.

## Declaring private and generated paths

Two guards act only on paths the repo names, because which directories hold
unpublishable material or machine output is not something a guard can guess:

```sh
git config --add github-guard.private-path   tmp        # git-block-private-paths
git config --add github-guard.generated-path frontend/bindings   # generated-normalise
```

…or, in the tree, `.githooks/private-paths` and `.githooks/generated-paths` —
one path per line, `#` for comments. Config wins where both exist.

Both sources are offered because they answer different needs. Per-clone git
config cannot be rewritten by a branch, which is the property the whole hooks
layout exists to get. An in-tree list **travels**, which is what a "do not
publish this directory" rule actually wants: a fresh clone must inherit it, or
the wall is only as strong as whoever remembered to configure it. The in-tree
file is read as **data** — it names paths, is never executed, and a branch that
edits it can only weaken a guard protecting its own author from an accident.

A path matches on whole components: `tmp` blocks `tmp/` and a file named `tmp`,
and does not block `tmpl/`.

## Tests

- `tests/protect-main-required-checks.sh [githooks-dir]` — the required-check
  selection. `gh` is stubbed and the branch-protection PUT is captured instead of
  sent, so the assertions are on the checks the guard would actually require.
- `tests/install-sh.sh [skill-dir]` — what `install.sh` lands in a target repo
  and what it must leave alone (hooks in `.git/hooks`, `core.hooksPath` cleared,
  exec bits mirrored from the payload, a repo's own `required-checks` and
  project-local extra guards untouched). It runs against every recorded project
  on upgrade, so a mistake here is multiplied by the number of guarded repos.
  Its last case is the negative control: a branch carrying a hostile
  `.githooks/pre-commit` is checked out and must not execute — and the case
  first proves the same attack DOES fire through `core.hooksPath`, so an absent
  marker means the hook was ignored rather than never run.

- `tests/rust-deps-pinned-sibling-lock.sh [githooks-dir]` — the sibling-clone
  half of `rust-deps-pinned.sh`, in both shapes of repository: with a chores file
  and without one. Each case asserts the per-file diagnostic by its own wording,
  because the section has an older existential check in front of it that fails
  for a different reason and would otherwise satisfy an exit-status assertion.
  That is not hypothetical: selecting the chores file with `FNR == NR` made the
  per-file pass inert in every repo that has no chores file, and the guard still
  looked healthy because the existential check kept firing.
- `tests/language-guards.sh [githooks-dir]` — the per-language guards, with the
  toolchains **stubbed**: what is under test is which files each guard touches,
  what it stages and when it blocks, not gofmt's or ruff's behaviour. Every
  formatting case asserts the **staged blob**, never the working tree, because
  the failure that matters is a formatted file being re-staged along with the
  unstaged edits in it — remove that check and the suite shows `WORK IN
  PROGRESS` inside the commit.
- `tests/changelog-notes.sh [githooks-dir]` — the `notes` subcommand as a
  release tool: the body is the section and nothing from the neighbouring
  version, the compare link spans the *previous* documented version, and a
  version with no section fails loudly instead of emitting an empty release
  body. The action's wiring (its `$GITHUB_ACTION_PATH` lookup, inputs, output
  and that the failure is a failure) is exercised by CI, which is the only
  place a runner can use it.
- `tests/status-sh.sh [skill-dir]` — the four answers `status.sh` has to keep
  apart (current, older, local, missing), plus the exec bit, `core.hooksPath`,
  and the stranded-in-tree-guard note. Every case denies the neighbouring
  classification as well as asserting its own, since reporting local work as
  merely *older* is what makes a sweep delete it.

All six take an optional path, so pointing them at another copy (a worktree of
an older commit, or a deployed `.git/hooks`) shows a regression fail rather than
asserting it.

```sh
for t in .claude/skills/github-guard/tests/*.sh; do bash "$t"; done
```

## How to install into a target repo

The guards are **copied** into the repo's `.git/hooks` as real files — per-clone,
outside the working tree, so no branch can rewrite the hook that runs next.
Nothing is committed. `install.sh` deploys into **one** repo; recording the
deployment and re-syncing every project later are handled by **install-skill**,
which owns the `installed_into` registry (see *Upgrading every guarded project*).

1. **Resolve the target.** Default to the repo containing the cwd
   (`git rev-parse --show-toplevel`); if cwd isn't a git repo, ask for the path.
   State the resolved path before installing.
2. **Check for a custom pre-commit.** If the target already has a custom
   `.git/hooks/pre-commit` (a non-dispatcher), warn that the dispatcher replaces
   it — its behavior should move into a `pre-commit.d/` guard (fmt/clippy and
   reproducible-release dep-pinning are already covered by the `rust-*` guards).
   The installer also NAMES any executable the repo still keeps in a tracked
   `.githooks/`: those used to run and no longer do. It refuses to import them
   for you — copying executables out of the working tree is the hole this layout
   closes — so move each into `.git/hooks/<hook>.d/`, or delete it.
3. **Run the installer:**
   ```sh
   bash ~/.claude/skills/github-guard/install.sh <target-repo-root>
   ```
   It copies the guards into `<repo>/.git/hooks` and clears `core.hooksPath`. It
   does **not** write any registry (see the next step).
4. **Report & explain:**
   - **Nothing to commit.** The hooks are per-clone by design. Assert the END
     STATE rather than the action — an install that leaves `core.hooksPath` set
     is inert, because that setting overrides `.git/hooks` and nothing says so:
     ```sh
     git -C <repo> config --get core.hooksPath   # must print nothing
     test -x <repo>/.git/hooks/pre-commit        # must succeed
     ```
   - **The github-* guards activate on the next commit.** `github-protect-main`
     and `github-merge-squash-only` live in `pre-commit.d/` and only act when a
     commit lands on the default branch. Until then the GitHub-side settings are
     NEVER applied — squash-only stays off, the default branch stays unprotected.
     Verify after that commit: `allow_merge_commit` is now `false` and
     `branches/<default>/protection` returns 200 (was 404).
   - **Bootstrap caveat:** that same commit makes the default branch require a PR
     (admin-enforced, no direct push), so land subsequent work via a PR.
   - **Record the deployment** so it can be re-synced later: install-skill
     appends `<repo>` to `installed_into`. Simplest path: ask install-skill to
     *"deploy github-guard into `<repo>`"*, which runs this installer **and**
     records it in one step.
   - A fresh clone has no hooks until someone re-runs the installer — that is the
     cost of hooks a branch cannot rewrite, and it is per-clone, not per-branch.
   - The `github-*` guards need `gh` authed with admin and only act on accounts
     the user owns; otherwise they skip silently.

## Which clones are current (`status.sh`)

The guards live outside the working tree, so `git status` says nothing about
them: each clone holds its own copy and a copy that drifted is invisible until
someone compares. `status.sh` is that comparison.

```sh
bash ~/.claude/skills/github-guard/status.sh              # this repo
bash ~/.claude/skills/github-guard/status.sh -v <repo>…    # and name the files
```

Per repo it prints one of:

| state | meaning | what to do |
| --- | --- | --- |
| `current` | every payload file matches, byte for byte | nothing |
| `behind` | a file matches an **earlier release** (named by commit), or is missing, or is not executable | re-run `install.sh` |
| `customised` | a file matches **no release** — written in place, never upstreamed | read it, upstream what is worth keeping, *then* re-install |
| `in-tree` | the repo still **tracks** a copy of the guards under `.githooks/`, the arrangement this layout replaced | commit their deletion |
| `stranded` | the installed files are right, but a tracked `.githooks/` still holds executables this layout no longer runs | move each into `.git/hooks/<hook>.d/` or delete it |
| `inert` | `core.hooksPath` overrides `.git/hooks`, so nothing in it runs | clear the setting |

A tracked in-tree copy does not run — the installer clears `core.hooksPath` —
so nothing about the repo looks wrong, which is exactly why it needs saying: it
reads as the live guards to anyone who opens the repo, it is what a branch
checkout can rewrite, and it drifts from the copy that actually runs. Only
**tracked** files count; an untracked leftover is one `rm` away and reaches
nobody else.

`inert` outranks everything else — with the override set, what the installed
files say is beside the point — and `stranded` is deliberately a separate word
from it: an override is a repo whose guards do not run, while stranded guards
are a repo whose guards run fine and whose *working tree* still carries the old
arrangement. One word for both sent a clean-up at the wrong repos.

The `behind` / `customised` split is the reason this exists. An older file is
one to overwrite; a file nobody upstreamed is work, and a sweep that overwrites
it destroys it — which is how `rust-deps-pinned.sh`'s sibling-clone section sat
in one clone and nowhere else for weeks. Exit status is 0 only when every named
repo is `current`, so the script doubles as the gate for a sweep.

Dating a file needs the payload's git history. An installed skill under
`~/.claude/skills/` has none of its own, so pass `--source <agent-skills
checkout>`; without it, files are still compared, everything differing is
reported as `local`, and the script says so on stderr rather than guessing.

## Upgrading every guarded project

After changing the guards, re-sync all recorded projects via **install-skill** —
it owns the deployment registry and the fan-out; github-guard's `install.sh` is
single-target only:

> ask install-skill to **"upgrade all github-guard deployments"**

It walks `installed_into`, re-runs this installer per project (pruning any whose
directory is gone or that isn't actually a github-guard install), preserves
project-local extra guards, and diffs+asks before overwriting a locally-edited
guard. Nothing to commit per repo — the sweep rewrites each clone's
`.git/hooks` and clears any leftover `core.hooksPath`.

## Add / remove / disable a guard

- **Add:** drop a `<topic>-<name>.sh` (executable) into the right `<hook>.d/`.
- **Remove:** delete it.
- **Disable without deleting:** `chmod -x` it (the dispatcher only runs
  executable scripts).

## Notes

- Emergency bypass for the hard blocks: `git … --no-verify`.
- This skill lives in the `antimatter-studios/agent-skills` monorepo and is
  promoted to `~/.claude/skills/github-guard/` via the `install-skill` flow.
