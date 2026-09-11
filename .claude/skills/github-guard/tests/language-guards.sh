#!/usr/bin/env bash
# Tests for the per-language guards — the format-then-restage family, the two
# blocking checks, and the two that act only on paths a repo declared.
#
#   tests/language-guards.sh [githooks-dir]   (default: the sibling githooks/)
#
# The load-bearing property is the same in every formatting guard and it is not
# "the file got formatted": formatting rewrites a file's FULL on-disk content,
# so re-staging it afterwards also stages whatever unstaged edits were sitting
# in it. A guard that gets that wrong silently commits work-in-progress nobody
# offered. Every fmt case here therefore checks the STAGED blob, not the
# working tree.
#
# The tools are stubs. What is under test is the guards' logic — which files
# they touch, what they stage, when they block — not gofmt's or ruff's
# behaviour, and a suite that needed six toolchains installed would not run.
set -uo pipefail

G=${1:-$(cd "$(dirname "$0")/../githooks" && pwd)}
[ -d "$G/pre-commit.d" ] || { echo "no githooks tree at $G" >&2; exit 2; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
bin="$root/bin"
mkdir -p "$bin"
pass=0; fail=0; n=0

ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
says()     { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 (output: ${2//$'\n'/ | })" ;; esac; }
says_not() { case "$2" in *"$1"*) bad "$4 (output: ${2//$'\n'/ | })" ;; *) ok "$4" ;; esac; }
staged_is() {
  got=$(git -C "$repo" show ":$1" 2>&1)
  [ "$got" = "$2" ] && ok "$3" || bad "$3 (staged: ${got//$'\n'/ | })"
}
worktree_is() {
  got=$(cat "$repo/$1")
  [ "$got" = "$2" ] && ok "$3" || bad "$3 (worktree: ${got//$'\n'/ | })"
}

# A formatter stub: `-l` names the file when it holds the marker line, `-w`
# removes it. Enough to be told apart from "did nothing".
make_formatter() {
  cat > "$bin/$1" <<'STUB'
#!/usr/bin/env bash
mode=$1; shift
# The guards end their options with `--` before the path, as they must for a
# file named like a flag. A stub that took $1 literally read "--" as the file,
# found nothing to format, and the suite then asserted on a no-op.
[ "${1:-}" = "--" ] && shift
case "$mode" in
  -l) grep -ql UNFORMATTED "$1" && printf '%s\n' "$1" ;;
  -w) tr -d '\r' < "$1" | grep -v '^UNFORMATTED$' > "$1.f" && mv "$1.f" "$1"
      printf 'FORMATTED-BY-%s\n' "$(basename "$0")" >> "$1" ;;
esac
exit 0
STUB
  chmod +x "$bin/$1"
}

repo=
setup() {
  n=$((n + 1)); repo="$root/repo$n"
  git init -q "$repo"
  git -C "$repo" config user.email github-guard-tests@example.invalid
  git -C "$repo" config user.name 'github-guard tests'
  git -C "$repo" config commit.gpgsign false
}
run() { ( cd "$repo" && PATH="$bin:$PATH" "$G/$1" 2>&1 ); }

printf 'language guards (%s)\n' "$G"

# --- go-fmt ----------------------------------------------------------------
make_formatter gofmt

setup
printf 'package main\nUNFORMATTED\n' > "$repo/a.go"
git -C "$repo" add a.go
out=$(run pre-commit.d/go-fmt.sh); rc=$?
staged_is a.go "package main
FORMATTED-BY-gofmt" "a fully staged file is formatted AND re-staged"
[ "$rc" = 0 ] && ok "go-fmt never blocks" || bad "go-fmt exited $rc"

# The case that matters: half the file is staged, the other half is not.
setup
printf 'package main\nUNFORMATTED\n' > "$repo/a.go"
git -C "$repo" add a.go
printf 'package main\nUNFORMATTED\nWORK IN PROGRESS\n' > "$repo/a.go"
out=$(run pre-commit.d/go-fmt.sh)
staged_is a.go "package main
UNFORMATTED" "a partially staged file is NOT re-staged"
worktree_is a.go "package main
UNFORMATTED
WORK IN PROGRESS" "and the unstaged work is left in the working tree"
says "has unstaged" "$out" "the notice explains why it was skipped"

# A partially staged file that is ALREADY formatted is nobody's problem, and a
# warning printed for it is a warning that gets tuned out.
setup
printf 'package main\n' > "$repo/a.go"
git -C "$repo" add a.go
printf 'package main\nWORK IN PROGRESS\n' > "$repo/a.go"
out=$(run pre-commit.d/go-fmt.sh)
says_not "has unstaged" "$out" x "no notice when formatting would change nothing"

# gofumpt is the stricter superset a project's linter may demand, so it wins.
make_formatter gofumpt
setup
printf 'package main\nUNFORMATTED\n' > "$repo/a.go"
git -C "$repo" add a.go
run pre-commit.d/go-fmt.sh >/dev/null
staged_is a.go "package main
FORMATTED-BY-gofumpt" "gofumpt is preferred over gofmt when installed"
rm -f "$bin/gofumpt"

setup
printf 'package main\nUNFORMATTED\n' > "$repo/a.go"
git -C "$repo" add a.go
mv "$bin/gofmt" "$root/gofmt.hidden"
out=$(run pre-commit.d/go-fmt.sh); rc=$?
staged_is a.go "package main
UNFORMATTED" "with no formatter installed nothing is rewritten"
[ "$rc" = 0 ] && ok "a missing formatter does not block" || bad "missing formatter exited $rc"
mv "$root/gofmt.hidden" "$bin/gofmt"

# --- python-lint -----------------------------------------------------------
# The stub records its argv, so the assertions can be about what the guard
# asked for as well as what it did with the answer.
cat > "$bin/ruff" <<'STUB'
#!/usr/bin/env bash
: > "$RUFF_ARGV"
for a in "$@"; do printf '%s\n' "$a" >> "$RUFF_ARGV"; done
exit "${RUFF_EXIT:-0}"
STUB
chmod +x "$bin/ruff"
export RUFF_ARGV="$root/ruff.argv"

setup
printf 'x = 1\n' > "$repo/a.py"
git -C "$repo" add a.py
export RUFF_EXIT=1
out=$(run pre-commit.d/python-lint.sh); rc=$?
[ "$rc" = 1 ] && ok "python-lint blocks when ruff reports a finding" || bad "python-lint exited $rc, want 1"
says BLOCKED "$out" "and says the commit was blocked"

export RUFF_EXIT=0
out=$(run pre-commit.d/python-lint.sh); rc=$?
[ "$rc" = 0 ] && ok "python-lint passes a clean tree" || bad "clean tree exited $rc"

# A path with a space is ONE argument. Through xargs it was two, and the guard
# then linted a file nobody staged (or nothing at all).
setup
mkdir -p "$repo/a dir"
printf 'x = 1\n' > "$repo/a dir/b c.py"
git -C "$repo" add "a dir/b c.py"
run pre-commit.d/python-lint.sh >/dev/null
got=$(grep -c . "$RUFF_ARGV"); want_path=$(grep -c '^a dir/b c\.py$' "$RUFF_ARGV")
[ "$want_path" = 1 ] && ok "a path with a space is passed as one argument" \
                     || bad "the spaced path was split (argv had $got entries)"

setup
printf 'x = 1\n' > "$repo/a.py"
git -C "$repo" add a.py
mv "$bin/ruff" "$root/ruff.hidden"
out=$(run pre-commit.d/python-lint.sh); rc=$?
[ "$rc" = 0 ] && ok "no ruff installed does not block" || bad "missing ruff exited $rc"
says "not found" "$out" "and says why it skipped"
mv "$root/ruff.hidden" "$bin/ruff"

# --- git-block-private-paths ------------------------------------------------
setup
mkdir -p "$repo/tmp" "$repo/tmpl"
printf 'x\n' > "$repo/tmp/secret.bin"; printf 'x\n' > "$repo/tmpl/page.html"
git -C "$repo" config --add github-guard.private-path tmp
git -C "$repo" add -f tmp/secret.bin
out=$(run pre-commit.d/git-block-private-paths.sh); rc=$?
[ "$rc" = 1 ] && ok "a declared private path is blocked" || bad "private path exited $rc, want 1"
says "tmp/secret.bin" "$out" "the offending path is named"

git -C "$repo" rm -q --cached tmp/secret.bin
git -C "$repo" add tmpl/page.html
out=$(run pre-commit.d/git-block-private-paths.sh); rc=$?
[ "$rc" = 0 ] && ok "a path that merely starts with the same letters is allowed" \
              || bad "tmpl/ was blocked by a declaration of tmp (exit $rc)"

# The in-tree declaration, which is the one that travels to a fresh clone.
setup
mkdir -p "$repo/.githooks" "$repo/corpus"
printf '# not ours to publish\ncorpus\n' > "$repo/.githooks/private-paths"
printf 'x\n' > "$repo/corpus/sample.bin"
git -C "$repo" add -f corpus/sample.bin
out=$(run pre-commit.d/git-block-private-paths.sh); rc=$?
[ "$rc" = 1 ] && ok "an in-tree declaration is honoured too" || bad "in-tree declaration exited $rc"

# The declaration belongs in .github-guard/, since .githooks/ holds no hooks
# any more. The old location still works, and says so, so no repo has to move
# its file in the same commit as anything else.
setup
mkdir -p "$repo/.github-guard" "$repo/corpus"
printf 'corpus\n' > "$repo/.github-guard/private-paths"
printf 'x\n' > "$repo/corpus/sample.bin"
git -C "$repo" add -f corpus/sample.bin
out=$(run pre-commit.d/git-block-private-paths.sh); rc=$?
[ "$rc" = 1 ] && ok ".github-guard/ is where a declaration is read from" || bad ".github-guard declaration ignored (exit $rc)"
says_not "move it" "$out" x "and the new location draws no migration notice"

setup
mkdir -p "$repo/.githooks" "$repo/corpus"
printf 'corpus\n' > "$repo/.githooks/private-paths"
printf 'x\n' > "$repo/corpus/sample.bin"
git -C "$repo" add -f corpus/sample.bin
out=$(run pre-commit.d/git-block-private-paths.sh); rc=$?
[ "$rc" = 1 ] && ok "the superseded location still works" || bad "a .githooks declaration was dropped (exit $rc)"
says "move it to .github-guard/private-paths" "$out" "and the move is spelled out"

# Nothing declared: the guard has no business guessing.
setup
mkdir -p "$repo/tmp"; printf 'x\n' > "$repo/tmp/thing.bin"
git -C "$repo" add -f tmp/thing.bin
out=$(run pre-commit.d/git-block-private-paths.sh); rc=$?
[ "$rc" = 0 ] && ok "with nothing declared the guard no-ops" || bad "undeclared tmp/ was blocked (exit $rc)"
says_not refusing "$out" x "and says nothing at all"

# --- generated-normalise ----------------------------------------------------
setup
mkdir -p "$repo/.github-guard" "$repo/gen"
printf 'gen\n' > "$repo/.github-guard/generated-paths"
printf 'line   \n' > "$repo/gen/out.ts"
git -C "$repo" add gen/out.ts
out=$(run pre-commit.d/generated-normalise.sh)
staged_is gen/out.ts "line" "generated-normalise reads .github-guard/generated-paths too"

setup
mkdir -p "$repo/gen" "$repo/src"
printf 'line   \n' > "$repo/gen/out.ts"
printf 'line   \n' > "$repo/src/hand.ts"
git -C "$repo" config --add github-guard.generated-path gen
git -C "$repo" add gen/out.ts src/hand.ts
out=$(run pre-commit.d/generated-normalise.sh); rc=$?
staged_is gen/out.ts "line" "trailing whitespace in generated output is stripped and re-staged"
staged_is src/hand.ts "line   " "hand-written code is left for the blocking guard"
[ "$rc" = 0 ] && ok "generated-normalise never blocks" || bad "generated-normalise exited $rc"

setup
mkdir -p "$repo/gen"
printf 'line   \n' > "$repo/gen/out.ts"
git -C "$repo" config --add github-guard.generated-path gen
git -C "$repo" add gen/out.ts
printf 'line   \nlocal edit\n' > "$repo/gen/out.ts"
out=$(run pre-commit.d/generated-normalise.sh)
staged_is gen/out.ts "line   " "a generated file with unstaged edits is not re-staged"
says "unstaged changes" "$out" "and the skip is reported"

# --- go-vet -----------------------------------------------------------------
cat > "$bin/go" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${GO_OUT:-}"
exit "${GO_EXIT:-0}"
STUB
chmod +x "$bin/go"

setup
printf 'module x\n' > "$repo/go.mod"
printf 'package main\n' > "$repo/a.go"
git -C "$repo" add go.mod a.go
export GO_EXIT=1 GO_OUT='a.go:3:2: printf: non-constant format string'
out=$(run pre-commit.d/go-vet.sh); rc=$?
[ "$rc" = 1 ] && ok "go-vet blocks on a finding" || bad "go-vet exited $rc, want 1"
says 'non-constant format string' "$out" "and shows what vet said"

# An unresolvable embed is the module failing to build for a reason that is not
# the code; blocking there makes a fresh clone unable to commit at all.
export GO_EXIT=1 GO_OUT='a.go:5:12: pattern dist/*: no matching files found'
out=$(run pre-commit.d/go-vet.sh); rc=$?
[ "$rc" = 0 ] && ok "go-vet fails open when an embed has nothing to embed" || bad "embed failure blocked the commit (exit $rc)"

# Not a Go module: no opinion.
setup
printf 'x\n' > "$repo/a.txt"
git -C "$repo" add a.txt
export GO_EXIT=1
out=$(run pre-commit.d/go-vet.sh); rc=$?
[ "$rc" = 0 ] && ok "go-vet has no opinion outside a Go module" || bad "non-Go repo exited $rc"

# --- js-fmt -----------------------------------------------------------------
# prettier comes from the NEAREST package's node_modules, because a global one
# formats to a different major's defaults than the project's CI checks.
setup
mkdir -p "$repo/web/node_modules/.bin" "$repo/other"
cat > "$repo/web/node_modules/.bin/prettier" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -*) ;; *) printf 'FORMATTED %s\n' "$(pwd | sed 's#.*/##')" > "$a" ;; esac; done
STUB
chmod +x "$repo/web/node_modules/.bin/prettier"
printf 'const a=1\n' > "$repo/web/app.ts"
printf 'const b=2\n' > "$repo/other/lib.ts"
git -C "$repo" add web/app.ts other/lib.ts
out=$(run pre-commit.d/js-fmt.sh); rc=$?
staged_is web/app.ts "FORMATTED web" "the package's own prettier formats its files, run from its directory"
staged_is other/lib.ts "const b=2" "a file with no prettier above it is left alone"
[ "$rc" = 0 ] && ok "js-fmt never blocks" || bad "js-fmt exited $rc"

# --- the payload's own modes ------------------------------------------------
# go-test runs the whole suite, which is a per-project decision, so it ships
# disarmed. A dispatcher only runs executable guards.
[ ! -x "$G/pre-push.d/go-test.sh" ] && ok "go-test ships disarmed (not executable)" \
                                    || bad "go-test ships executable — it would run in every Go repo on upgrade"
for g in go-fmt go-vet python-fmt python-lint js-fmt git-block-private-paths generated-normalise; do
  [ -x "$G/pre-commit.d/$g.sh" ] && ok "$g ships armed" || bad "$g is not executable"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
