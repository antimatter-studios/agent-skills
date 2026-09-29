#!/usr/bin/env bash
# guard: rust-fmt
# Auto-format staged Rust code with `cargo fmt` and re-stage it, so the commit
# goes in formatted. Only runs in a Cargo project (skips silently otherwise).
# NEVER blocks — it just fixes layout, so there's nothing to argue about.
#
# Safety (the important bit): `cargo fmt` rewrites a file's FULL on-disk
# content, so blindly `git add`-ing a formatted file would also stage any
# UNSTAGED edits sitting in that same file — silently sweeping a developer's
# work-in-progress into the commit. So we only re-stage files that were
# *fully* staged (no unstaged changes). A partially-staged file is left as-is
# (its staged snapshot commits unformatted) with a notice — never a silent
# sweep.
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

gg_is_rust || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Staged .rs files, and (captured BEFORE formatting) which .rs files also carry
# unstaged changes — their intersection is the "partially staged" danger set.
staged=$(git diff --cached --name-only --diff-filter=ACM -- '*.rs')
[ -n "$staged" ] || exit 0
unstaged=$(git diff --name-only --diff-filter=ACMD -- '*.rs')

# `cargo fmt` formats the WHOLE crate, not the staged files. Every .rs file
# this commit does not carry in full — untouched, edited but unstaged, or only
# partly staged — is snapshotted first and put back byte for byte afterwards,
# so a commit never leaves formatting edits in files it did not include.
keep=$(mktemp -d "${TMPDIR:-/tmp}/rust-fmt.XXXXXX") || exit 0
trap 'rm -rf "$keep"' EXIT
( cd "$root" && git ls-files -co --exclude-standard -- '*.rs' ) | while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$root/$f" ] || continue
  if printf '%s\n' "$staged" | grep -qxF -- "$f" && ! printf '%s\n' "$unstaged" | grep -qxF -- "$f"; then
    continue   # staged in full: this one is formatted and re-staged
  fi
  mkdir -p "$keep/$(dirname "$f")" && cp -p "$root/$f" "$keep/$f"
done
restore_unstaged() {
  ( cd "$keep" && find . -type f ) | while IFS= read -r f; do
    f=${f#./}
    cmp -s "$keep/$f" "$root/$f" || cat "$keep/$f" > "$root/$f"
  done
}

# Format via gg_cargo (the rustup shim), which honors rust-toolchain.toml so it
# matches CI. If cargo isn't available, don't block — just skip.
# Once per Cargo project -- the root crate, or each one in a subdirectory when
# there is none at the root (gg_rust_manifests). From the project's own
# directory, so its rust-toolchain.toml is the one rustup reads.
while IFS= read -r manifest; do
  ( cd "$root/$(dirname "$manifest")" && gg_cargo fmt ) \
    || { restore_unstaged
         echo "github-guard: 'cargo fmt' skipped/failed in $(dirname "$manifest") — not blocking" >&2; exit 0; }
done < <(gg_rust_manifests)
restore_unstaged

printf '%s\n' "$staged" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s\n' "$unstaged" | grep -qxF -- "$f"; then
    echo "github-guard: rust-fmt left '$f' unformatted in this commit — it has unstaged" >&2
    echo "             changes, and re-staging after format would mix them in. Stage it" >&2
    echo "             fully (git add '$f'), or run 'cargo fmt' + 'git add' yourself." >&2
    continue
  fi
  [ -f "$root/$f" ] && git add -- "$root/$f" 2>/dev/null || true
done
exit 0
