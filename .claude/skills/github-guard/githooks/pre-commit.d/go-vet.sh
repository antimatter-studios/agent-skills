#!/usr/bin/env bash
# guard: go-vet
# `go vet ./...` and block the commit on a finding. Go modules only, and only
# when the commit touches Go — a vet finding is a statement that the code is
# wrong (a printf verb that cannot match, a lost cancel, a mutex copied), not
# an opinion about layout.
#
# Fails OPEN when the module cannot be built for a reason that is not the code.
# The case that forced this: a repo whose embed directive points at a build
# output directory (a frontend bundle, a generated asset tree) cannot vet at all
# in a fresh clone until that output exists — and a checkout where nothing can
# be committed is a worse failure than a missed vet, which CI catches anyway.
# The escape is keyed on the error go itself prints for an unresolvable embed,
# so it cannot be mistaken for a real finding.
set -u
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/go.mod" ] || exit 0
command -v go >/dev/null 2>&1 || exit 0

git diff --cached --name-only --diff-filter=ACM -- '*.go' 'go.mod' 'go.sum' | grep -q . || exit 0

out=$(cd "$root" && go vet ./... 2>&1)
status=$?

# Linker warnings from building on a machine newer than the module's target say
# nothing about the code, so they are not part of the report.
out=$(printf '%s\n' "$out" | grep -vE '^ld: warning|was built for newer')
[ "$status" -eq 0 ] && exit 0

if printf '%s\n' "$out" | grep -qE 'pattern [^:]*: no matching files found'; then
  echo "github-guard: go-vet skipped — an embed directive has nothing to embed yet," >&2
  echo "             so the module cannot build for a reason that is not the code." >&2
  echo "             Build the embedded output once, then vet runs normally." >&2
  exit 0
fi

echo "github-guard: go vet failed — commit blocked." >&2
printf '%s\n' "$out" >&2
exit 1
