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
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/Cargo.toml" ] || exit 0
command -v cargo >/dev/null 2>&1 || { echo "github-guard: cargo not found — skipping rust-fmt" >&2; exit 0; }

# Staged .rs files, and (captured BEFORE formatting) which .rs files also carry
# unstaged changes — their intersection is the "partially staged" danger set.
staged=$(git diff --cached --name-only --diff-filter=ACM -- '*.rs')
[ -n "$staged" ] || exit 0
unstaged=$(git diff --name-only --diff-filter=ACMD -- '*.rs')

( cd "$root" && cargo fmt ) || { echo "github-guard: 'cargo fmt' failed — not blocking" >&2; exit 0; }

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
