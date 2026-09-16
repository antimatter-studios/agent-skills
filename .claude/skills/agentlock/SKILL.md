---
name: agentlock
description: Advisory worktree ownership for repositories several agents share. Adds `chore worktrees`, `chore claim` and `chore unclaim`, which record who is working in a worktree and why, and list every worktree with its owner, age and whether anything would be lost by removing it. Use when agents share a checkout, when worktrees have accumulated and somebody needs to know which are abandoned, before removing or reusing any worktree, or when the user asks about agentlock, worktree ownership, stale worktrees, or who is working where.
user-invocable: true
---

# agentlock

`git worktree list` tells you a path and a branch. It never tells you **who made
one, when, why, or whether anything would be lost by removing it** — which is
the whole of what somebody sweeping stale worktrees actually needs.

Harmless alone, expensive shared. A repository worked by several agents collects
worktrees nobody remembers creating; the live ones look exactly like the ones
abandoned three days ago; and the only way to tell them apart is to guess from
branch names, which is how somebody's uncommitted evening gets deleted.

```
chore claim "rebasing the edge stack"    # take this worktree
chore unclaim                            # give it back
chore worktrees                          # who holds what
```

## Reading a sweep

```
$ chore worktrees
PATH                              BRANCH                      OWNER                 AGE  STATE
.                                 main                        -                     -    dirty(1)
~/scratch/mine                    restore/the-edge-comes-out  ai-world-59 [8539fc]  17m  dirty(1), held
./.claude/worktrees/local-prices  worktree-local-prices       local-prices-session  9m   dirty(1), locked, held
./.worktrees/pr147-fix            integrate/pr147             -                     -    free
```

`STATE` is deliberately conservative, and it is the only column worth acting on:

| state | meaning |
|---|---|
| `dirty(N)` | N uncommitted paths. **Never remove on the strength of this tool.** |
| `locked` | `git worktree lock` was used. Somebody meant it. |
| `held` | an `.agentlock` names an owner. |
| `free` | clean, unlocked, unclaimed — the only state that invites removal. |

States combine and the cautious one wins: a claimed worktree with uncommitted
work reads `dirty(1), held` and is a candidate for nothing. `free` says only
that removing the checkout loses no *uncommitted* work — whether the branch has
landed is a different question this does not answer, and it removes nothing
itself.

## What an agent should do

**On creating a worktree, claim it.** One line, and it is the difference between
a worktree somebody can reason about and one they have to guess at.

```bash
git worktree add ../scratch/mine -b my/branch origin/main
cd ../scratch/mine && chore claim "what this is for"
```

**Before touching a worktree that is not yours, read the sweep.** `held` and
`locked` mean somebody is there; `dirty` means something would be lost. Ask the
owner — an agent name is usually addressable — rather than inferring from a
branch name that the work looks finished.

**On finishing, `chore unclaim`**, or remove the worktree entirely. A lock left
on a live worktree nobody owns is worse than no lock, because the next sweep
trusts it.

## Why `chore` and not a git subcommand

The first version shipped this as `git worktrees`, one letter from git's own
`git worktree`. Adjacent names for adjacent jobs is how a tool gets run by
accident: a typo of the built-in silently did something else. Git resolves
built-ins before `PATH`, so nothing was ever shadowed — but "it is technically
safe" is not the same as "it reads safely", and the second is what matters at a
keyboard.

So the verbs live where a project's other verbs already live. `chore worktrees`
sits beside `chore check` and `chore release` and reads as one of them, which is
the point.

## The ignore line is global, not per project

`.agentlock` goes in the **global** excludes file:

```
~/.config/git/ignore          # git reads this by default when core.excludesFile is unset
```

A line in each project's `.gitignore` is a commit per project — and for a
repository with a protected default branch, a pull request per project, with a
review and a CI run, to adopt a convention that has not proved itself. One line
per machine covers every repository, present and future. The trade is that the
rule does not travel with a clone, which is the same deal `github-guard` makes
about its hooks and for the same reason: these are per-operator facts.

## Naming

The owner comes from `--as`, else `$AGENT_LOCK_NAME`, else `user@place[pid]`
where *place* is `$TMUX_PANE`, the tty, or the hostname, in that order. A named
session should export it once:

```bash
export AGENT_LOCK_NAME='ai-world-59 [8539fc]'
```

That order was settled by a bug worth repeating: the first version used
`hostname -s`, which on one host answers `Unknown`, so every unnamed agent
claimed its worktree as `Unknown[pid]` and a sweep showed several rows that
looked like one agent and were not. A tmux pane id differs between two agents on
one machine and outlives the process.

## What this is not

**Advisory, not a lock.** Nothing refuses to run because somebody else holds a
worktree. That judgement belongs to whoever is reading, and a tool that pretended
otherwise would be trusted for a guarantee it cannot give.

**It helps only agents that write it.** A worktree made by something that does
not claim shows as unowned, which is correct — it is unowned as far as anybody
can tell.

**It does not protect against the interesting failures.** The one that prompted
it was a stale *remote-tracking ref*, where `--force-with-lease` passed because
the lease matched a ref that had not been fetched, and nine commits were replaced
by one. No worktree convention catches that. Said here so it is not sold as
protection it does not offer.

## Install

```bash
./install.sh            # copies `agentlock` to ~/.local/bin, adds the global ignore line
```

Then add the three tasks to a project's `chores.yml` — `install.sh --tasks`
prints them:

```yaml
  worktrees:
    desc: Every worktree of this repository, with who holds it and what it would cost to remove
    cmds: ['agentlock list']

  claim:
    desc: Say this worktree is yours, and what you are doing in it
    args:
      - name: doing
        desc: one line about the work
    cmds: ['agentlock claim "{{.DOING}}"']

  unclaim:
    desc: Give this worktree back
    cmds: ['agentlock release']
```

`unclaim` rather than `release`, because a project that ships software already
has a `chore release` and it means something else entirely.
