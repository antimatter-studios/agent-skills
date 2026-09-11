#!/usr/bin/env bash
# Tests for rust-deps-pinned part 5 — the lock must record the sibling version
# the workflows PIN.
#
#   tests/rust-deps-pinned-sibling-lock.sh [path-to-githooks-dir]
#
# WHY THIS FILE EXISTS. Part 5 was written in a project's `.git/hooks`, which is
# not version-controlled, and sat there for months in six repositories while the
# skill's own copy did without it. Nobody could see it and nothing tested it.
# Passing a different githooks dir runs these cases against another version of
# the guard, which is how the missing check was shown to be missing (the skill's
# pre-rescue copy fails cases 2 and 3 by passing them).
#
# The guard needs no network for part 5 — it reads Cargo.toml, Cargo.lock and
# .github/workflows — so each case is a throwaway git repo with those three
# things and an assertion on the exit status.
set -uo pipefail

src=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
[ -f "$src/pre-commit.d/rust-deps-pinned.sh" ] || { echo "not a githooks dir: $src" >&2; exit 2; }

root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
pass=0; fail=0

# A repo with one path dep on ../am-sibling, a lock recording $lockver, and
# whatever workflow content the case supplies.
make_case() {
  local dir="$1" lockver="$2" workflow="$3"
  mkdir -p "$dir/.github/workflows" && cd "$dir"
  git init -q . && git config user.email t@t && git config user.name t
  cat > Cargo.toml <<TOML
[package]
name = "consumer"
version = "0.1.0"
[dependencies]
am-sibling = { path = "../am-sibling", version = "0.4" }
TOML
  cat > Cargo.lock <<LOCK
[[package]]
name = "am-sibling"
version = "$lockver"

[[package]]
name = "consumer"
version = "0.1.0"
LOCK
  printf '%s\n' "$workflow" > .github/workflows/ci.yml
  git add -A >/dev/null 2>&1
}

run_guard() {
  ( cd "$1" && bash "$src/pre-commit.d/rust-deps-pinned.sh" >"$1/out.txt" 2>&1; echo $? )
}

check() {
  local name="$1" want="$2" got="$3" dir="$4"
  if [ "$got" = "$want" ]; then
    printf 'ok    %s\n' "$name"; pass=$((pass+1))
  else
    printf 'FAIL  %s: exit %s, expected %s\n' "$name" "$got" "$want" >&2
    sed -n '1,6p' "$dir/out.txt" 2>/dev/null | sed 's/^/        /' >&2
    fail=$((fail+1))
  fi
}

# 1. the lock agrees with the one pin — must pass
d="$root/c1"; make_case "$d" "0.4.1" '
jobs:
  test:
    steps:
      - run: git clone --branch v0.4.1 https://github.com/x/am-sibling.git ../am-sibling'
check "a lock matching the only pin is allowed" 0 "$(run_guard "$d")" "$d"

# 2. the lock disagrees — must block. This is the whole point: cargo rewrote the
#    lock when a sibling was bumped, and CI would fail minutes later on --locked.
d="$root/c2"; make_case "$d" "0.4.9" '
jobs:
  test:
    steps:
      - run: git clone --branch v0.4.1 https://github.com/x/am-sibling.git ../am-sibling'
check "a lock ahead of the pin is blocked" 1 "$(run_guard "$d")" "$d"

# 3. TWO pins for the same sibling, only one matching — must block.
#    The guard's own comment records this as a defect it used to have: the check
#    was existential, so ci.yml at the lock's version satisfied it while
#    release.yml sat elsewhere and only failed on a tag, during publish.
d="$root/c3"; make_case "$d" "0.4.1" '
jobs:
  test:
    steps:
      - run: git clone --branch v0.4.1 https://github.com/x/am-sibling.git ../am-sibling
  release:
    steps:
      - run: git clone --branch v0.3.7 https://github.com/x/am-sibling.git ../am-sibling'
check "one matching pin does not excuse a second disagreeing one" 1 "$(run_guard "$d")" "$d"

# 4. the same sibling cloned SOMEWHERE ELSE at another version — must pass.
#    A workflow may clone a sibling into RUNNER_TEMP at the version a DIFFERENT
#    crate needs; flagging that is a false positive, and a guard that cries wolf
#    gets bypassed.
d="$root/c4"; make_case "$d" "0.4.1" '
jobs:
  test:
    steps:
      - run: git clone --branch v0.4.1 https://github.com/x/am-sibling.git ../am-sibling
      - run: git clone --branch v0.2.0 https://github.com/x/am-sibling.git "$RUNNER_TEMP/am-sibling"'
check "a clone into another slot is not this crate's business" 0 "$(run_guard "$d")" "$d"

# 5. nothing pinned for this sibling at all — not this check's business.
d="$root/c5"; make_case "$d" "0.4.1" '
jobs:
  test:
    steps:
      - run: cargo test'
check "no pin for the sibling means nothing to compare" 0 "$(run_guard "$d")" "$d"

# 6. the tag given as a WORKFLOW VARIABLE, not a literal — must still compare.
#    The guard's comments record that the fix for an earlier drift replaced a
#    literal with a variable, so a literal-only reader went blind on the very
#    commit that repaired the thing it was watching for.
d="$root/c6"; make_case "$d" "0.4.9" '
env:
  SIBLING_REF: v0.4.1
jobs:
  test:
    steps:
      - run: git clone --branch "$SIBLING_REF" https://github.com/x/am-sibling.git ../am-sibling'
check "a pin held in a workflow variable is resolved and compared" 1 "$(run_guard "$d")" "$d"

# 7. the tag declared in chores.yml — the tidier design, and the one the
#    resolver could not see until it learned to read that file. This case also
#    pins the FILENAME discriminator: before it, /dev/null contributing zero
#    records made `FNR == NR` true for the whole workflow, so every repository
#    WITHOUT a chores.yml had this entire section silently disabled.
d="$root/c7"; make_case "$d" "0.4.9" '
jobs:
  test:
    steps:
      - run: git clone --branch "$SIBLING_REF" https://github.com/x/am-sibling.git ../am-sibling'
printf 'version: "3"\nSIBLING_REF: v0.4.1\n' > "$d/chores.yml"
( cd "$d" && git add chores.yml >/dev/null 2>&1 )
check "a pin declared in chores.yml is resolved and compared" 1 "$(run_guard "$d")" "$d"

echo
if [ "$fail" = 0 ]; then
  echo "rust-deps-pinned-sibling-lock: all $pass checks passed"
else
  echo "rust-deps-pinned-sibling-lock: $fail of $((pass+fail)) failed" >&2
fi
exit $(( fail > 0 ))
