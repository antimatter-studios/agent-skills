#!/usr/bin/env bash
# Tests for WHERE the rust-* guards run: which Cargo projects they find.
#
#   tests/rust-guards.sh [githooks-dir]   (default: the sibling githooks/)
#
# The guards used to ask one question -- is there a Cargo.toml at the repo
# root? -- and skip in silence when there was not. A repository whose crate
# lives in a subdirectory (a tool with its Rust code under runner/) therefore
# got no fmt and no clippy at all, and nothing said so. gg_rust_manifests
# answers the question properly: the outermost tracked Cargo.toml files.
#
# cargo is a stub that records the directory it ran in and its arguments. What
# is under test is where the guards call it, not what cargo does. HOME points
# at an empty directory so gg_cargo cannot find the real rustup shim.
set -uo pipefail

G=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
[ -d "$G/pre-commit.d" ] || { echo "no githooks tree at $G" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
bin="$root/bin"; home="$root/home"; calls="$root/calls"
mkdir -p "$bin" "$home"
pass=0; fail=0; n=0

ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
is()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got: ${1//$'\n'/ | }; want: ${2//$'\n'/ | })"; }

# `cargo <sub> ...` appends "<dir relative to the repo> <sub>" to $calls, and
# fails a clippy run in any directory named in CLIPPY_FAILS.
cat > "$bin/cargo" <<'STUB'
#!/usr/bin/env bash
rel=${PWD#"$REPO"}; rel=${rel#/}; [ -n "$rel" ] || rel=.
printf '%s %s\n' "$rel" "$1" >> "$CALLS"
[ -z "${CARGO_ARGS:-}" ] || printf '%s\n' "$*" >> "$CARGO_ARGS"
if [ "$1" = clippy ]; then
  if [ -n "${MUTATE_LOCK:-}" ]; then
    locked=0
    for arg in "$@"; do [ "$arg" != --locked ] || locked=1; done
    [ "$locked" = 1 ] || printf 'rewritten by unlocked cargo\n' > "$MUTATE_LOCK"
  fi
  for d in ${CLIPPY_FAILS:-}; do [ "$d" = "$rel" ] && { echo "warning: stub lint in $rel"; exit 101; }; done
  [ "${CLIPPY_EXIT:-0}" = 0 ] || { echo "warning: cargo exited ${CLIPPY_EXIT}"; exit "$CLIPPY_EXIT"; }
fi
# FMT_REWRITE: format like the real thing does — every .rs file in the crate,
# staged or not — by appending a marker line to each.
if [ "$1" = fmt ] && [ -n "${FMT_REWRITE:-}" ]; then
  find . -name '*.rs' -type f | while IFS= read -r f; do printf '// formatted\n' >> "$f"; done
fi
if [ "$1" = metadata ] && [ "${METADATA_EXIT:-0}" != 0 ]; then
  echo 'the lock file needs to be updated' >&2
  exit "$METADATA_EXIT"
fi
exit 0
STUB
chmod +x "$bin/cargo"

repo=
setup() {
  n=$((n + 1)); repo="$root/repo$n"
  git init -q "$repo"
  git -C "$repo" config user.email github-guard-tests@example.invalid
  git -C "$repo" config user.name 'github-guard tests'
  git -C "$repo" config commit.gpgsign false
  : > "$calls"
}
crate() {  # crate DIR -- a tracked Cargo.toml and one staged .rs file under DIR
  mkdir -p "$repo/$1/src"
  printf '[package]\nname = "c%s"\nversion = "0.1.0"\n' "$n" > "$repo/$1/Cargo.toml"
  printf 'fn main() {}\n' > "$repo/$1/src/main.rs"
  git -C "$repo" add "$1/Cargo.toml" "$1/src/main.rs"
}
run() {
  ( cd "$repo" && HOME="$home" PATH="$bin:$PATH" REPO="$(pwd -P)" CALLS="$calls" \
      CLIPPY_FAILS="${CLIPPY_FAILS:-}" MUTATE_LOCK="${MUTATE_LOCK:-}" \
      CARGO_ARGS="${CARGO_ARGS:-}" FMT_REWRITE="${FMT_REWRITE:-}" "$G/$1" 2>&1 )
}
manifests() { ( cd "$repo" && . "$G/lib/common.sh" && gg_rust_manifests ); }

printf 'rust guards (%s)\n' "$G"

# --- the root crate: unchanged ------------------------------------------------
setup; crate .; crate fuzz; crate member/inner
is "$(manifests)" "Cargo.toml" "a root crate is the only project; fuzz/ and members are under it"
run pre-commit.d/rust-clippy.sh >/dev/null; rc=$?
is "$rc $(cat "$calls")" "0 . clippy" "clippy runs once, at the root, as before"

# An unlocked cargo invocation may re-resolve a path dependency and rewrite
# Cargo.lock before rust-deps-pinned runs. The stub reproduces that side effect.
setup; crate .
printf 'the staged lock\n' > "$repo/Cargo.lock"
git -C "$repo" add Cargo.lock
args="$root/cargo-args"; : > "$args"
MUTATE_LOCK="$repo/Cargo.lock" CARGO_ARGS="$args" run pre-commit.d/rust-clippy.sh >/dev/null; rc=$?
is "$rc" 0 'clippy accepts a locked Cargo project'
is "$(cat "$repo/Cargo.lock")" 'the staged lock' 'clippy does not rewrite an unstaged lock'
is "$(cat "$args")" 'clippy --locked --all-targets -- -D warnings' 'clippy asks cargo to keep the lock fixed'

: > "$calls"; run pre-commit.d/rust-fmt.sh >/dev/null
is "$(cat "$calls")" ". fmt" "fmt runs once, at the root, as before"

# --- a crate only in a subdirectory: the case that used to skip --------------
setup; crate runner
is "$(manifests)" "runner/Cargo.toml" "a crate under runner/ is found"
run pre-commit.d/rust-clippy.sh >/dev/null; rc=$?
is "$rc $(cat "$calls")" "0 runner clippy" "clippy runs in runner/, where it used to skip"
: > "$calls"; run pre-commit.d/rust-fmt.sh >/dev/null
is "$(cat "$calls")" "runner fmt" "fmt runs in runner/"
: > "$calls"; out=$(run pre-commit.d/rust-deps-pinned.sh); rc=$?
is "$rc|$out|$(cat "$calls")" "0||" "deps-pinned has no root manifest to read and says nothing"

# --- two crates side by side ---------------------------------------------------
setup; crate a; crate b; crate b/nested
is "$(manifests)" "a/Cargo.toml
b/Cargo.toml" "sibling crates are both projects; b/nested is under b"
out=$(CLIPPY_FAILS=a run pre-commit.d/rust-clippy.sh); rc=$?
is "$rc" "1" "a lint failure in one project blocks the commit"
is "$(cat "$calls")" "a clippy
b clippy" "and the other project is still linted"
case "$out" in *"clippy found issues"*) ok "the verdict is printed once" ;; *) bad "no verdict (output: $out)" ;; esac

# A running cargo can itself exit 2; only absence of cargo may skip clippy.
setup; crate .
out=$(CLIPPY_EXIT=2 run pre-commit.d/rust-clippy.sh); rc=$?
is "$rc" "1" "cargo clippy exit 2 blocks rather than looking absent"
case "$out" in *"clippy found issues"*) ok "the cargo failure is reported" ;; *) bad "cargo exit 2 was hidden (output: $out)" ;; esac

# The second reader of the sentinel must still notice a real stale lock.
setup; crate .
printf '[[package]]\nname = "c%s"\nversion = "0.1.0"\n' "$n" > "$repo/Cargo.lock"
git -C "$repo" add Cargo.lock
out=$(METADATA_EXIT=2 run pre-commit.d/rust-deps-pinned.sh); rc=$?
is "$rc" "1" "cargo metadata exit 2 with a stale lock blocks"
case "$out" in *"Cargo.lock is STALE"*) ok "the stale-lock reason is reported" ;; *) bad "stale lock was hidden (output: $out)" ;; esac

# --- fmt touches only what is being committed ----------------------------------
# cargo fmt formats the whole crate. A file with no staged changes — committed
# and untouched, or edited but not staged — was rewritten on disk by a commit
# that never included it, leaving an unrelated diff behind. Only files staged
# in full are formatted and re-staged; everything else keeps its bytes.
setup; crate .
printf 'fn a() {}\n' > "$repo/src/a.rs"; printf 'fn b() {}\n' > "$repo/src/b.rs"
git -C "$repo" add src/a.rs src/b.rs; git -C "$repo" commit -qm init
printf 'fn main() { }\n' > "$repo/src/main.rs"; git -C "$repo" add src/main.rs   # staged in full
printf 'fn b() { /* wip */ }\n' > "$repo/src/b.rs"                              # unstaged edit
cp "$repo/src/a.rs" "$root/a.before"; cp "$repo/src/b.rs" "$root/b.before"
FMT_REWRITE=1 run pre-commit.d/rust-fmt.sh >/dev/null
cmp -s "$repo/src/a.rs" "$root/a.before" && ok "fmt leaves a committed, untouched file alone" \
  || bad "fmt rewrote src/a.rs, which has no changes at all"
cmp -s "$repo/src/b.rs" "$root/b.before" && ok "fmt leaves a file with only unstaged edits alone" \
  || bad "fmt rewrote src/b.rs, whose edits are not being committed"
git -C "$repo" show :src/main.rs | grep -q '^// formatted$' \
  && ok "the fully staged file is still formatted and re-staged" || bad "src/main.rs was not formatted into the commit"

# --- no Cargo project ----------------------------------------------------------
setup; printf 'x\n' > "$repo/README"; git -C "$repo" add README
is "$(manifests)" "" "no tracked Cargo.toml, no project"
run pre-commit.d/rust-clippy.sh >/dev/null; rc=$?
run pre-commit.d/rust-fmt.sh >/dev/null
is "$rc $(cat "$calls")" "0 " "neither guard calls cargo"

# --- untracked, and tracked-but-deleted ----------------------------------------
setup; mkdir -p "$repo/scratch"; printf '[package]\n' > "$repo/scratch/Cargo.toml"
printf 'x\n' > "$repo/README"; git -C "$repo" add README
is "$(manifests)" "" "an untracked Cargo.toml is not a project"
setup; crate gone; crate kept; git -C "$repo" commit -qm init; rm "$repo/gone/Cargo.toml"
is "$(manifests)" "kept/Cargo.toml" "a tracked manifest deleted from the working tree is skipped"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
