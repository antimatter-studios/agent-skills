#!/usr/bin/env bash
# guard: go-test  (SHIPS DISARMED — chmod +x to enable it in a repo)
# `go test ./...` and block the push on a failure. Go modules only.
#
# On push rather than on commit: a suite that touches the filesystem or the
# network costs seconds, and seconds on every commit is what trains people into
# --no-verify — which disables every other guard too. Paid once per push it is
# invisible.
#
# Not executable in the payload because "run the whole suite" is a per-project
# decision: a repo with a fast suite wants this, one with a ten-minute suite
# wants it in CI only. `chmod +x .git/hooks/pre-push.d/go-test.sh` arms it, and
# re-running the installer does not disarm it (a merging copy leaves the mode of
# a file that already exists alone).
#
# Fails OPEN when the module cannot be built for an environmental reason — see
# go-vet for the case that forced it.
set -u
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/go.mod" ] || exit 0
command -v go >/dev/null 2>&1 || exit 0

out=$(cd "$root" && go test ./... 2>&1)
status=$?
out=$(printf '%s\n' "$out" | grep -vE '^ld: warning|was built for newer')
[ "$status" -eq 0 ] && exit 0

if printf '%s\n' "$out" | grep -qE 'pattern [^:]*: no matching files found'; then
  echo "github-guard: go-test skipped — an embed directive has nothing to embed yet," >&2
  echo "             so the module cannot build for a reason that is not the code." >&2
  exit 0
fi

echo "github-guard: go test failed — push blocked." >&2
printf '%s\n' "$out" >&2
exit 1
