#!/usr/bin/env bash
# guard: git-block-large-files
# Refuse to commit a staged file larger than the limit (default 10 MiB) unless
# it's tracked by Git LFS. Big blobs bloat history forever — deleting one later
# needs a full history rewrite. This is a BACKSTOP for accidents; the right home
# for genuinely large assets is .gitignore (e.g. *.img, *.qcow2) or Git LFS.
# Override the limit with GITHUB_GUARD_MAX_FILE_MB. Bypass once: git commit --no-verify.
set -u
max_mb=${GITHUB_GUARD_MAX_FILE_MB:-10}
max_bytes=$(( max_mb * 1024 * 1024 ))

staged=$(git diff --cached --name-only --diff-filter=ACM)
[ -n "$staged" ] || exit 0

fail=0
while IFS= read -r path; do
  [ -n "$path" ] && [ -f "$path" ] || continue
  # Tracked by Git LFS? Then only a small pointer is committed — allow it.
  if git check-attr filter -- "$path" 2>/dev/null | grep -q ': filter: lfs$'; then
    continue
  fi
  # `wc -c`, not stat. BSD reads `stat -f '%z'` as the size, but GNU reads
  # `stat -f` as FILESYSTEM status and succeeds, so the old BSD-first chain got
  # a multi-line filesystem report on Linux, `[ -gt ]` errored, and no file was
  # ever blocked there. wc takes the size from fstat for a regular file on both.
  sz=$(wc -c < "$path" 2>/dev/null | tr -d ' ') || sz=0
  case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
  if [ "$sz" -gt "$max_bytes" ]; then
    mb=$(( sz / 1024 / 1024 ))
    echo "git-block-large-files: '$path' is ${mb} MiB (limit ${max_mb} MiB)." >&2
    echo "             .gitignore it, track it with Git LFS, or store it outside the repo." >&2
    echo "             intentional? bypass once: git commit --no-verify" >&2
    fail=1
  fi
done <<EOF
$staged
EOF
exit "$fail"
