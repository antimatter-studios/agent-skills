---
name: agentlock
description: Advisory worktree ownership for repositories several agents share. Installs `git agentlock` and `git worktrees`, which record who is working in a worktree and why, and list every worktree with its owner, age and whether anything would be lost by removing it. Use when agents share a checkout, when worktrees have accumulated and somebody needs to know which are abandoned, before removing or reusing any worktree, or when the user asks about agentlock, worktree ownership, stale worktrees, or who is working where.
user-invocable: true
---

# agentlock

`git worktree list` tells you a path and a branch. It never tells you **who made
one, when, why, or whether anything would be lost by removing it** — which is
the whole of what somebody sweeping stale worktrees actually needs.

That gap is harmless alone and expensive shared. A repository worked by several
agents accumulates worktrees nobody remembers creating; the ones still in use
look exactly like the ones abandoned three days ago; and the only way to tell
them apart is to guess from branch names, which is how somebody's uncommitted
evening gets deleted.

This is one advisory file, `.agentlock`, at the root of each worktree, and two
commands that write and read it.

```
git agentlock claim "rebasing the edge stack"   # take this worktree
git agentlock release                           # give it back
git worktrees                                   # who holds what
```

## Ignored once, everywhere, with no repository changed

`.agentlock` goes in the **global** excludes file, not in any project's
`.gitignore`:

```
~/.config/git/ignore          # git reads this by default when core.excludesFile is unset
```

One line, once per machine. Every repository — present and future — ignores it
without a commit, a pull request, or a protected-branch argument anywhere. A
convention that needs a PR per project to adopt is a convention that does not
get adopted.

## Reading a sweep

```
$ git worktrees
PATH                              BRANCH                      OWNER                 AGE  STATE
.                                 main                        —                     —    dirty(2)
../scratchpad/mine                restore/the-edge-comes-out  ai-world-59 [8539fc]  2h   held
./.claude/worktrees/local-prices  worktree-local-prices       ai-world-fd           7h   dirty(1), locked
./.worktrees/pr147-fix            integrate/pr147             —                     —    free
```

`STATE` is deliberately conservative, and it is the only column worth acting on:

| state | meaning |
|---|---|
| `dirty(N)` | N uncommitted paths. **Never remove on the strength of this tool.** |
| `locked` | `git worktree lock` was used. Somebody meant it. |
| `held` | an `.agentlock` names an owner. |
| `free` | clean, unlocked, unclaimed — the only state that invites removal. |

States combine, and the cautious ones win: a claimed worktree with uncommitted
work reads `dirty(1), held` and is not a candidate for anything. `free` says
only that removing the checkout loses no *uncommitted* work; whether the branch
has landed is a different question this does not answer, and `git worktrees`
deliberately removes nothing itself.

## What an agent should do

**On creating a worktree, claim it.** One line, and it is the difference between
a worktree somebody can reason about and one they have to guess at.

```bash
git worktree add ../scratch/mine -b my/branch origin/main
cd ../scratch/mine && git agentlock claim "what this is for"
```

**Before touching a worktree that is not yours, read the sweep.** `held` and
`locked` mean somebody is there. `dirty` means something would be lost. Ask the
owner — an agent name is usually addressable — rather than inferring from a
branch name that the work looks finished.

**On finishing, release it**, or remove the worktree entirely. A lock left on a
removed worktree is noise; a lock left on a live one that nobody owns is worse,
because the next sweep trusts it.

## Naming

The owner comes from `--as`, else `$AGENT_LOCK_NAME`, else a fallback of
`user@place[pid]` where *place* is `$TMUX_PANE`, the tty, or the hostname, in
that order.

A session with a name should export it once:

```bash
export AGENT_LOCK_NAME='ai-world-59 [8539fc]'
```

The fallback exists to be *distinguishing*, not decorative, and its order was
settled by a bug worth repeating: the first version used `hostname -s`, which on
one host answers `Unknown`, so every unnamed agent claimed its worktree as
`Unknown[pid]` and a sweep showed several rows that looked like one agent and
were not. A tmux pane id differs between two agents on one machine and survives
the process, which is why it is now first.

## What this is not

**Advisory, not a lock.** Nothing refuses to run because somebody else holds a
worktree. That judgement belongs to whoever is reading, and a tool that pretended
otherwise would be trusted for a guarantee it cannot give.

**It helps only agents that write it.** A worktree made by something that does
not claim shows as unowned, which is correct — it is unowned as far as anybody
can tell.

**It does not protect against the interesting failures.** The one that motivated
this was a stale *remote-tracking ref*, where `--force-with-lease` passed because
the lease matched a ref that had not been fetched, and nine commits were replaced
by one. No worktree convention would have caught that. Worth stating so this is
not sold as protection it does not offer.

## Install

Copy both scripts onto `PATH` and add the ignore line. Git treats any `git-foo`
on `PATH` as `git foo`, so there is nothing to configure per repository:

```bash
install -m 755 scripts/git-agentlock scripts/git-worktrees ~/.local/bin/
mkdir -p ~/.config/git
grep -qx '.agentlock' ~/.config/git/ignore 2>/dev/null \
  || printf '\n# advisory worktree ownership, see `git agentlock`\n.agentlock\n' >> ~/.config/git/ignore
```

Verify:

```bash
git worktrees            # lists this repository's worktrees
git agentlock show       # unclaimed, or who holds this one
```
