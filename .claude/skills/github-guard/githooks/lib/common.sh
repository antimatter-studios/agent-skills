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
#
# A repo declares facts about itself in ONE tracked file at its root,
# `.github-guard`, in git-config format — read with `git config -f`, so the
# guards need no parser beyond the git they already run under:
#
#   [checks]
#   	required = CI              # repeat the key for more; `none` = require none
#   [merge]
#   	auto = true
#   [paths]
#   	private = tmp              # repeat the key for more
#   	generated = frontend/bindings
#
# `#` and `;` start a comment anywhere outside double quotes, so a value that
# contains either must be quoted: required = "C# build".
#
# The file is DATA. It is never executed, and it is always read with
# --no-includes, so an `[include]` in it cannot pull in a file from elsewhere.

# The declarations file's name, relative to a repo root.
GG_DECL_FILE=.github-guard

# git config, restricted to one declarations file and nothing else.
gg_decl_config() {
  local file="$1"; shift
  git config --file "$file" --no-includes "$@"
}

# True if <file> is a readable, well-formed git-config file. A directory (the
# layout this file replaced), a syntax error, or an unreadable file all fail —
# and a caller must treat that as "cannot tell", never as "nothing declared".
gg_decl_valid() {
  [ -f "$1" ] && gg_decl_config "$1" --list >/dev/null 2>&1
}

# Fetch the DEFAULT BRANCH's `.github-guard` from the SERVER into <out>.
#
#   gg_fetch_server_decl <owner/repo> <branch> <out>
#     0  fetched: <out> holds the committed file
#     1  unreachable or absent (404, offline, no permission)
#     2  something is there that is not a file (e.g. the old directory)
#
# The privileged declarations (checks.required can strip branch protection,
# merge.auto lets a PR merge unattended) are read from here and NEVER from the
# working tree: these guards run pre-commit against whatever happens to be
# checked out, and an untrusted branch must not be able to rewrite the policy
# that protects the default branch just by being checked out while the owner
# commits. A policy change takes effect once it is merged.
#
# The contents API is asked for JSON rather than the raw media type, because
# the raw type answers a DIRECTORY with a JSON listing and a 200.
gg_fetch_server_decl() {
  local slug="$1" branch="$2" out="$3" raw
  raw=$(gh api "repos/$slug/contents/$GG_DECL_FILE?ref=$branch" \
    --jq 'if type == "object" and .type == "file" and .encoding == "base64"
          then "file:" + (.content | gsub("\n"; "") | @base64d)
          else "other" end' 2>/dev/null) || return 1
  case "$raw" in
    file:*) printf '%s\n' "${raw#file:}" > "$out" ;;
    *) return 2 ;;
  esac
}

# Echo the path prefixes a repo declared for <kind> (private | generated), one
# per line, or nothing.
#
#   gg_declared_paths private
#     1. git config github-guard.paths.private      (per clone; repeatable)
#     2. .github-guard  [paths] private = ...       (in the working tree)
#
# The per-clone keys mirror the file's: `[paths] private` in .github-guard is
# `[github-guard "paths"] private` in .git/config.
#
# Two sources because they answer different needs. Per-clone git config cannot
# be rewritten by a branch, which is the arrangement the whole hooks layout
# exists to get (see install.sh). The in-tree file TRAVELS with the repo, which
# is what a "do not publish this directory" rule actually wants — a fresh clone
# must inherit it or the wall is only as good as whoever remembered to set it
# up. So config wins where both are present, and the file is read as data only:
# a branch that edits it can only weaken a guard that protects its own author
# from an accident. That is also why these, unlike checks.required, are read
# from the working tree: they must work in a clone with no network.
#
# Returns 0 with the list (possibly empty: nothing declared), or 2 when
# .github-guard exists but is not a readable git-config file. On 2 the caller
# cannot know what was declared and must not read it as "nothing".
gg_declared_paths() {
  local kind="$1" root out file
  out=$(git config --get-all "github-guard.paths.$kind" 2>/dev/null) || out=
  if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  file="$root/$GG_DECL_FILE"
  [ -e "$file" ] || return 0
  gg_decl_valid "$file" || return 2
  gg_decl_config "$file" --get-all "paths.$kind" 2>/dev/null \
    | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' \
    | grep -v '^$' || true
}

# Why gg_decl_valid failed, in git's own words, for a message worth acting on.
gg_decl_error() {
  if [ -d "$1" ]; then
    printf '%s is a directory, not a git-config file' "$GG_DECL_FILE"
  else
    gg_decl_config "$1" --list 2>&1 >/dev/null | sed -n '1s/^fatal: //p'
  fi
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

# The Cargo projects in this repo, one repo-relative manifest path per line: every
# tracked Cargo.toml that is not inside the directory of another tracked one, and
# is on disk. A repo whose crate is at the root prints `Cargo.toml` and nothing
# else, because every other manifest is under it (workspace members, a fuzz/
# crate) and cargo run at the root already reaches what it should. A repo whose
# crate lives in a subdirectory -- a tool repo with its Rust code in `runner/` --
# prints `runner/Cargo.toml`, where testing only the root saw no Cargo project at
# all and every rust-* guard skipped without a word.
gg_rust_manifests() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  # Shallowest first, so an outer manifest is seen before anything under it.
  git -C "$root" ls-files -- 'Cargo.toml' '*/Cargo.toml' \
    | awk -F/ '{ print NF "\t" $0 }' | LC_ALL=C sort -n -k1,1 -k2 | cut -f2- \
    | awk -v root="$root" '
    {
      dir = $0; sub(/\/?Cargo\.toml$/, "", dir)
      nested = 0
      for (i = 1; i <= n; i++) {
        if (outer[i] == "" || index(dir "/", outer[i] "/") == 1) { nested = 1; break }
      }
      if (nested) next
      if ((getline line < (root "/" $0)) < 0) next   # tracked but deleted: skip
      close(root "/" $0)
      outer[++n] = dir
      print $0
    }'
}

# True if the repo holds a Cargo project anywhere (see gg_rust_manifests).
gg_is_rust() {
  [ -n "$(gg_rust_manifests)" ]
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
