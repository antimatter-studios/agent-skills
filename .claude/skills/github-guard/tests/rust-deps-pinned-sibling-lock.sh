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

# A second workflow beside ci.yml, staged like the first.
add_workflow() {
  printf '%s\n' "$3" > "$1/.github/workflows/$2"
  ( cd "$1" && git add ".github/workflows/$2" >/dev/null 2>&1 )
}

# A checkout of the sibling into its slot; $1 is the ref line, $2 any with: keys
# written between repository: and path:.
checkout_wf() {
  printf 'jobs:\n  release:\n    steps:\n      - uses: actions/checkout@v4\n        with:\n          repository: x/am-sibling\n          %s\n%s          path: am-sibling\n      - run: cargo test --locked\n' "$1" "$2"
}

# ── #65: a pin the old line pre-filter could not see ─────────────────────────
# The pre-filter wanted the sibling's name and a version on ONE physical line;
# a checkout block and a continued clone never have that, so the parsers that
# could read them were never reached.
d="$root/p65a"; make_case "$d" "0.4.1" "$(checkout_wf 'ref: v0.3.7' '')"
check "#65 a stale checkout-only pin is caught with no *_REF anywhere" 1 "$(run_guard "$d")" "$d"

d="$root/p65b"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - run: |
          git clone --quiet \
            --branch v0.3.7 \
            https://github.com/x/am-sibling.git \
            ../am-sibling'
check "#65 a stale multi-line git clone is caught" 1 "$(run_guard "$d")" "$d"

d="$root/p65c"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - run: |
          git clone --quiet \
            --branch v0.4.1 \
            https://github.com/x/am-sibling.git \
            ../am-sibling'
check "#65 a matching multi-line git clone is allowed" 0 "$(run_guard "$d")" "$d"

# ── #66: env resolves by Actions scope (step > job > workflow), not file order ─
d="$root/p66a"; make_case "$d" "0.4.1" '
env:
  SIBLING_REF: v0.4.1
jobs:
  release:
    steps:
      - run: git clone --branch "$SIBLING_REF" https://github.com/x/am-sibling.git ../am-sibling
        env:
          SIBLING_REF: v0.3.7'
check "#66 a stale step-level env: written below its run: is caught" 1 "$(run_guard "$d")" "$d"

d="$root/p66b"; make_case "$d" "0.4.1" '
env:
  SIBLING_REF: v0.3.7
jobs:
  release:
    steps:
      - run: git clone --branch "$SIBLING_REF" https://github.com/x/am-sibling.git ../am-sibling
        env:
          SIBLING_REF: v0.4.1'
check "#66 a correct step-level env: below its run: overrides a stale workflow value" 0 "$(run_guard "$d")" "$d"

d="$root/p66c"; make_case "$d" "0.4.1" '
env:
  SIBLING_REF: v0.3.7
jobs:
  release:
    steps:
      - run: git clone --branch "$SIBLING_REF" https://github.com/x/am-sibling.git ../am-sibling
  later:
    env:
      SIBLING_REF: v0.4.1
    steps:
      - run: true'
check "#66 a later job redeclaring the variable does not mask the stale one" 1 "$(run_guard "$d")" "$d"

d="$root/p66d"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - run: git clone --branch "${{ env.SIBLING_REF }}" https://github.com/x/am-sibling.git ../am-sibling
    env:
      SIBLING_REF: v0.3.7
env:
  SIBLING_REF: v0.4.1'
check "#66 a stale job-level env: below the steps beats a later workflow env:" 1 "$(run_guard "$d")" "$d"

# ── #67: the index is judged, not the working tree ───────────────────────────
d="$root/p67a"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - run: git clone --branch v0.3.7 https://github.com/x/am-sibling.git ../am-sibling'
sed -i.bak 's/v0\.3\.7/v0.4.1/' "$d/.github/workflows/ci.yml" && rm -f "$d/.github/workflows/ci.yml.bak"
check "#67 a stale staged pin is caught though the working tree is fixed" 1 "$(run_guard "$d")" "$d"

d="$root/p67b"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - run: git clone --branch v0.4.1 https://github.com/x/am-sibling.git ../am-sibling'
sed -i.bak 's/v0\.4\.1/v0.3.7/' "$d/.github/workflows/ci.yml" && rm -f "$d/.github/workflows/ci.yml.bak"
check "#67 a correct staged pin is allowed though the working tree is stale" 0 "$(run_guard "$d")" "$d"

d="$root/p67c"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - run: git clone --branch v0.4.1 https://github.com/x/am-sibling.git ../am-sibling'
sed -i.bak 's/"0\.4\.1"/"0.4.9"/' "$d/Cargo.lock" && rm -f "$d/Cargo.lock.bak"
check "#67 an unstaged Cargo.lock rewrite does not block a correct commit" 0 "$(run_guard "$d")" "$d"

d="$root/p67d"; make_case "$d" "0.4.9" '
jobs:
  release:
    steps:
      - run: git clone --branch v0.4.1 https://github.com/x/am-sibling.git ../am-sibling'
sed -i.bak 's/"0\.4\.9"/"0.4.1"/' "$d/Cargo.lock" && rm -f "$d/Cargo.lock.bak"
check "#67 a stale staged Cargo.lock is caught though the working tree is fixed" 1 "$(run_guard "$d")" "$d"

# ── #68: every fetch is compared; --branch=TAG is a pin ──────────────────────
correct_clone='
jobs:
  test:
    steps:
      - run: git clone --branch v0.4.1 https://github.com/x/am-sibling.git ../am-sibling'

d="$root/p68a"; make_case "$d" "0.4.1" "$correct_clone"
add_workflow "$d" release.yml '
jobs:
  release:
    steps:
      - run: git clone --branch=v0.3.7 https://github.com/x/am-sibling.git ../am-sibling'
check "#68 a stale --branch=TAG is caught beside a correct pin" 1 "$(run_guard "$d")" "$d"

d="$root/p68b"; make_case "$d" "0.4.1" "$correct_clone"
add_workflow "$d" release.yml '
jobs:
  release:
    steps:
      - run: curl -fsSL https://github.com/x/am-sibling/archive/refs/tags/v0.3.7.tar.gz | tar -xz -C .. && mv ../am-sibling-0.3.7 ../am-sibling'
check "#68 a stale release tarball is caught beside a correct pin" 1 "$(run_guard "$d")" "$d"

d="$root/p68c"; make_case "$d" "0.4.1" "$correct_clone"
add_workflow "$d" release.yml '
jobs:
  release:
    steps:
      - run: curl -fsSL "https://github.com/x/am-sibling/archive/refs/tags/v0.4.1.tar.gz" | tar -xz -C ..'
check "#68 a matching release tarball is allowed" 0 "$(run_guard "$d")" "$d"

d="$root/p68d"; make_case "$d" "0.4.1" '
env:
  OTHER_REF: v0.4.1
jobs:
  release:
    steps:
      - run: git clone --branch "$SIBLING_REF" https://github.com/x/am-sibling.git ../am-sibling'
check "#68 an unrelated *_REF at the lock version does not excuse an unresolvable pin" 1 "$(run_guard "$d")" "$d"

d="$root/p68e"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - run: git clone https://github.com/x/am-sibling.git ../am-sibling'
check "#68 a clone into the slot with no pin at all is reported, not passed" 1 "$(run_guard "$d")" "$d"

# ── #34 defect 2: quoted scalars and trailing comments ───────────────────────
d="$root/q1"; make_case "$d" "0.4.1" '
env:
  SIBLING_REF: "v0.3.7"
jobs:
  release:
    steps:
      - run: git clone --branch "$SIBLING_REF" https://github.com/x/am-sibling.git ../am-sibling'
check "#34-2 a stale double-quoted env value is caught" 1 "$(run_guard "$d")" "$d"

d="$root/q2"; make_case "$d" "0.4.1" '
env:
  SIBLING_REF: "v0.4.1"
jobs:
  release:
    steps:
      - run: git clone --branch "$SIBLING_REF" https://github.com/x/am-sibling.git ../am-sibling'
check "#34-2 a correct double-quoted env value is allowed" 0 "$(run_guard "$d")" "$d"

d="$root/q3"; make_case "$d" "0.4.1" "
env:
  SIBLING_REF: 'v0.4.1'   # the sibling
jobs:
  release:
    steps:
      - run: git clone --branch \"\$SIBLING_REF\" https://github.com/x/am-sibling.git ../am-sibling"
check "#34-2 a correct single-quoted, commented env value is allowed" 0 "$(run_guard "$d")" "$d"

d="$root/q4"; make_case "$d" "0.4.1" "$(checkout_wf "ref: 'v0.3.7'" '')"
sed -i.bak "s@repository: x/am-sibling@repository: \"x/am-sibling\"@; s@path: am-sibling@path: 'am-sibling'@" "$d/.github/workflows/ci.yml"
rm -f "$d/.github/workflows/ci.yml.bak"; ( cd "$d" && git add -A >/dev/null 2>&1 )
check "#34-2 a stale checkout with quoted repository/ref/path is caught" 1 "$(run_guard "$d")" "$d"

d="$root/q5"; make_case "$d" "0.4.1" "$(checkout_wf 'ref: "v0.3.7"' '')"
sed -i.bak "s@repository: x/am-sibling@repository: x/am-sibling   # the sibling@" "$d/.github/workflows/ci.yml"
rm -f "$d/.github/workflows/ci.yml.bak"; ( cd "$d" && git add -A >/dev/null 2>&1 )
check "#34-2 a stale checkout with a comment after repository: is caught" 1 "$(run_guard "$d")" "$d"

d="$root/q6"; make_case "$d" "0.4.1" "$(checkout_wf "ref: 'v0.4.1'" '')"
sed -i.bak "s@repository: x/am-sibling@repository: \"x/am-sibling\" # ok@; s@path: am-sibling@path: \"am-sibling\"@" "$d/.github/workflows/ci.yml"
rm -f "$d/.github/workflows/ci.yml.bak"; ( cd "$d" && git add -A >/dev/null 2>&1 )
check "#34-2 a correct fully-quoted checkout is allowed" 0 "$(run_guard "$d")" "$d"

d="$root/q7"; make_case "$d" "0.4.1" "$(checkout_wf 'ref: v0.3.7' '')"
sed -i.bak "s@repository: x/am-sibling@repository: x/am-sibling-extra@" "$d/.github/workflows/ci.yml"
rm -f "$d/.github/workflows/ci.yml.bak"; ( cd "$d" && git add -A >/dev/null 2>&1 )
check "#34-2 a checkout of a different repo sharing a prefix is not this sibling" 0 "$(run_guard "$d")" "$d"

# ── #34 defect 3: the checkout block ends on dedent, not after four lines ─────
four='          fetch-depth: 0
          submodules: true
          persist-credentials: false
          clean: true
'
d="$root/w4"; make_case "$d" "0.4.1" "$(checkout_wf 'ref: v0.3.7' "$four")"
check "#34-3 a stale ref behind four with: keys is caught" 1 "$(run_guard "$d")" "$d"

d="$root/w5"; make_case "$d" "0.4.1" "$(checkout_wf 'ref: v0.3.7' "$four          lfs: false
")"
check "#34-3 a stale ref behind five with: keys is caught" 1 "$(run_guard "$d")" "$d"

d="$root/w6"; make_case "$d" "0.4.1" "$(checkout_wf 'ref: v0.4.1' "$four          lfs: false
")"
check "#34-3 a correct ref behind five with: keys is allowed" 0 "$(run_guard "$d")" "$d"

d="$root/w7"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - uses: actions/checkout@v4
        with:
          repository: x/am-sibling
          ref: v0.3.7
      - uses: actions/checkout@v4
        with:
          path: am-sibling'
check "#34-3 a later step's path: is not attributed to an earlier checkout" 0 "$(run_guard "$d")" "$d"

# #85. A workflow that reads the pin from chores.yml at run time through a
#      `pin NAME` helper -- `--branch "$(pin SIBLING_REF)"` -- names the same
#      value chores.yml declares, so the guard resolves it there. Unresolved,
#      it blocked every commit in such a repository, whatever it changed.
d="$root/p85a"; make_case "$d" "0.4.1" '
jobs:
  release:
    steps:
      - run: |
          pin() { sed -n "s/^  $1: *//p" chores.yml; }
          git clone --depth 1 --branch "$(pin SIBLING_REF)" https://github.com/x/am-sibling.git ../am-sibling'
printf 'version: "3"\nvars:\n  SIBLING_REF: v0.4.1\n' > "$d/chores.yml"
( cd "$d" && git add chores.yml >/dev/null 2>&1 )
check "#85 a pin read through \$(pin NAME) that matches the lock is allowed" 0 "$(run_guard "$d")" "$d"

d="$root/p85b"; make_case "$d" "0.4.9" '
jobs:
  release:
    steps:
      - run: |
          pin() { sed -n "s/^  $1: *//p" chores.yml; }
          git clone --depth 1 --branch "$(pin SIBLING_REF)" https://github.com/x/am-sibling.git ../am-sibling'
printf 'version: "3"\nvars:\n  SIBLING_REF: v0.4.1\n' > "$d/chores.yml"
( cd "$d" && git add chores.yml >/dev/null 2>&1 )
check "#85 a pin read through \$(pin NAME) that disagrees with the lock is still blocked" 1 "$(run_guard "$d")" "$d"

echo
if [ "$fail" = 0 ]; then
  echo "rust-deps-pinned-sibling-lock: all $pass checks passed"
else
  echo "rust-deps-pinned-sibling-lock: $fail of $((pass+fail)) failed" >&2
fi
exit $(( fail > 0 ))
