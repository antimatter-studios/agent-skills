#!/usr/bin/env bash
# Shared helpers for github-guard guards. Source this file; it defines
# functions only and never exits the calling shell.
#
# Fail-open by design: a guard that blocks your work because gh/network/perms
# are unavailable is worse than the mistake it prevents. The local hard-block
# guards (merge commits) are the exception — they need no network.

# Echo the GitHub "owner/repo" slug for origin, or nothing if origin is missing
# or not on github.com.
gg_repo_slug() {
  local url rest host path
  url=$(git remote get-url origin 2>/dev/null) || return 0
  url=${url%.git}
  case "$url" in
    ssh://*|https://*|http://*)
      # scheme://[user@]host[:port]/owner/repo (incl. GitHub SSH-over-443,
      # ssh://git@ssh.github.com:443/owner/repo).
      rest=${url#*://}; rest=${rest#*@}
      host=${rest%%/*}; host=${host%%:*}
      path=${rest#*/}
      ;;
    *:*)
      # scp-style [user@]host:owner/repo (git@github.com:owner/repo).
      host=${url%%:*}; host=${host#*@}
      path=${url#*:}
      ;;
    *)
      return 0 ;;
  esac
  # Only claim a slug for a real GitHub host — never a substring match like
  # https://evil.com/github.com/owner/repo or ssh://git@github.com.example.org/…,
  # which would otherwise let the GitHub guards act on an unrelated repo.
  case "$host" in
    github.com|ssh.github.com) ;;
    *) return 0 ;;
  esac
  printf '%s' "$path"
}

# True if gh is installed and authenticated.
gg_have_gh() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }

# Echo the authenticated GitHub login, or nothing.
gg_login() { gh api user --jq '.login' 2>/dev/null; }

# Return 0 only if the authenticated user OWNS this account: it is their
# personal account, or an org where their membership role is "admin" (owner).
# We change settings only on accounts we own — never other people's orgs, even
# where we happen to have repo-admin. A new org you create matches (you own it).
gg_user_owns() {
  local owner="$1" me role
  me=$(gg_login); [ -n "$me" ] || return 1
  [ "$owner" = "$me" ] && return 0
  role=$(gh api "user/memberships/orgs/$owner" --jq '.role' 2>/dev/null) || return 1
  [ "$role" = "admin" ]
}

# NOTE: deliberately no throttling. The network guards run only on commit/push
# — sparse, event-driven, a few calls each, nowhere near the 5000/hour API
# limit — so the ~1-2s they add to the occasional commit isn't worth a
# stamp-file/TTL mechanism.

# True if this repo keeps a changelog — a root CHANGELOG.md, or a "Changelog"
# (release notes / history) section in the root README.md. Guards that enforce
# changelog discipline self-gate on this: no changelog convention → they no-op,
# so projects without one are unaffected.
gg_has_changelog() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -f "$root/CHANGELOG.md" ] && return 0
  [ -f "$root/README.md" ] \
    && grep -qiE '^#{2,}[[:space:]]+(change ?log|release notes|recent changes|releases|history)\b' "$root/README.md" \
    && return 0
  return 1
}

# --- Declarations a repo makes to the guards ---------------------------------

# Echo the path prefixes a repo declared for <key>, one per line, or nothing.
#
#   gg_declared_paths private-path private-paths
#                     ^ git config github-guard.<key> (repeatable)
#                                   ^ .githooks/<file>, one path per line
#
# Two sources because they answer different needs. Per-clone git config cannot
# be rewritten by a branch, which is the arrangement the whole hooks layout
# exists to get (see install.sh). An in-tree file TRAVELS with the repo, which
# is what a "do not publish this directory" rule actually wants — a fresh clone
# must inherit it or the wall is only as good as whoever remembered to set it
# up. So config wins where both are present, and the in-tree file is read as
# data only: it names paths, it is never executed, and a branch that edits it
# can only weaken a guard that protects its own author from an accident.
#
# Both empty means the guard has nothing to act on and no-ops — a guard that
# guesses which directories are private would block the wrong commits.
gg_declared_paths() {
  local key="$1" file="$2" root out path
  out=$(git config --get-all "github-guard.$key" 2>/dev/null) || out=
  if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  # .github-guard/ is where a declaration belongs: the hooks themselves live in
  # .git/hooks, so a directory called .githooks/ holding no hooks invites
  # someone to drop an executable in and expect it to run, which it never will.
  # The old path still works, with a warning, so no repo has a flag day.
  if [ -f "$root/.github-guard/$file" ]; then
    path="$root/.github-guard/$file"
  elif [ -f "$root/.githooks/$file" ]; then
    path="$root/.githooks/$file"
    echo "github-guard: read .githooks/$file — move it to .github-guard/$file (the hooks are in .git/hooks; nothing in .githooks/ runs)" >&2
  else
    return 0
  fi
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$path" \
    | grep -v '^$' || true
}

# The notice every format-then-restage guard owes a partially-staged file.
#
# Formatting rewrites a file's FULL on-disk content, so `git add`-ing it after
# formatting would also stage the unstaged edits sitting in it — sweeping
# work-in-progress into a commit nobody asked to include it in. The file is
# left alone instead, which means its staged snapshot commits unformatted, and
# that trade is worth saying out loud rather than doing silently.
gg_partial_notice() {
  local guard="$1" file="$2" hint="$3"
  echo "github-guard: $guard left '$file' unformatted in this commit — it has unstaged" >&2
  echo "             changes, and re-staging after format would mix them in. Stage it" >&2
  echo "             fully (git add '$file'), or $hint yourself." >&2
}

# --- Rust helpers (shared by the rust-* guards) ------------------------------

# True if the repo root holds a Cargo.toml (i.e. it's a Cargo project).
gg_is_rust() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -f "$root/Cargo.toml" ]
}

# Run cargo via the rustup SHIM (`~/.cargo/bin/cargo`) so a repo's
# rust-toolchain.toml pin is honored automatically — local fmt/clippy then use
# the same toolchain as CI. A bare `cargo` can be Homebrew's, which ignores the
# pin entirely; the shim is the rustup proxy and respects it (installing the
# pinned toolchain on first use, as rustup intends). Falls back to whatever
# `cargo` is on PATH if the shim isn't present; returns 2 if there's no cargo
# at all (callers treat that as "skip, don't block").
gg_cargo() {
  local shim="$HOME/.cargo/bin/cargo"
  if [ -x "$shim" ]; then
    "$shim" "$@"
  elif command -v cargo >/dev/null 2>&1; then
    cargo "$@"
  else
    return 2
  fi
}
