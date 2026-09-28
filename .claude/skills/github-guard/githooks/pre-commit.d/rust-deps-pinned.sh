#!/usr/bin/env bash
# guard: rust-deps-pinned
# Reproducible-release gate for Cargo projects: refuse a commit that would make
# a versioned tag non-reproducible. Only runs when Cargo.toml is present (skips
# silently otherwise), so non-Rust repos are unaffected. BLOCKS on a real
# problem; fail-OPEN whenever the environment can't give a reliable answer (no
# cargo, empty offline cache, a path-dep sibling not checked out) — CI's
# `cargo … --locked` is the authoritative backstop.
#
# It catches the ways a "pinned" release silently isn't:
#   1. A workflow that FLOATING-clones a sibling repo (same GitHub owner) with
#      no `--branch`/`-b` — the published build then resolves against whatever
#      that repo's HEAD happens to be, not a fixed tag.
#   2. A workflow `actions/checkout` of a sibling repo with no `ref:` — same
#      floating hazard, via the action instead of raw git.
#   3. A committed Cargo.lock whose own package version drifted from Cargo.toml
#      (bumped the manifest, forgot to re-lock — only blows up at `cargo publish`).
#   4. A Cargo.lock that `cargo metadata --locked` reports as stale.
#   5. A Cargo.lock recording a path-dep sibling at a version some workflow
#      fetch of that sibling does not pin.
#
# Parts 1-3 and 5 read the STAGED files (the index), which is what the commit
# records; part 4 needs cargo and a real tree, so it reads the working tree.
#
# Bypass once (NOT recommended): git commit --no-verify
set -u
dir=$(cd "$(dirname "$0")/.." && pwd)   # the hooks dir
# shellcheck source=../lib/common.sh
. "$dir/lib/common.sh"

gg_is_rust || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0
# The pinning rules read the ROOT Cargo.toml and Cargo.lock -- the crate this
# repo releases. A repo whose only Cargo project is in a subdirectory (a tool
# under runner/) has no root manifest, and nothing here to check.
[ -f Cargo.toml ] || exit 0
fail=0

# ── the snapshot being committed, not the working tree ──────────────────────
# A pre-commit hook judges what the commit will record. Reading the working
# tree instead meant a fixed-but-unstaged pin let a stale one through, and an
# unstaged edit (or a Cargo.lock that clippy rewrote) blocked a correct commit.
# So every file parsed below is read from the index (`git show :path`), falling
# back to the working tree only for a path with no staged version. Part 4 is
# the exception: cargo needs a real tree, so it runs in the repository.
owner=$(gg_repo_slug); owner=${owner%%/*}
tomls=$(git ls-files '*Cargo.toml' 'Cargo.toml')
snap=$(mktemp -d "${TMPDIR:-/tmp}/rust-deps-pinned.XXXXXX") || exit 0
trap 'rm -rf "$snap"' EXIT
while IFS= read -r f; do
  [ -n "$f" ] || continue
  mkdir -p "$snap/$(dirname "$f")"
  if git cat-file -e ":$f" 2>/dev/null; then
    git show ":$f" > "$snap/$f"
  elif [ -f "$f" ]; then
    cp "$f" "$snap/$f"
  fi
done < <({ printf '%s\n' Cargo.toml Cargo.lock chores.yml "$tomls"
           git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml'
           for f in .github/workflows/*.yml .github/workflows/*.yaml; do
             [ -f "$f" ] && printf '%s\n' "$f"; done; } | sort -u)
cd "$snap" || exit 0

# ── 1 & 2. no FLOATING fetch of a sibling repo (same owner) in any workflow ──
# A "sibling" is another repo under the same GitHub owner as origin — those are
# the path/git dependency crates a release must pin. If the owner can't be
# determined (no github origin) we skip these two checks; the lock checks below
# still run.
if [ -n "$owner" ] && [ -d .github/workflows ]; then
  shopt -s nullglob 2>/dev/null || true
  for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    # Join shell line-continuations (a trailing '\') into one logical line before
    # scanning: in a `run: |` block a `git clone …\` and its `--branch vX` land on
    # two physical lines, and a per-physical-line check would flag the first as
    # unpinned even though the clone is pinned.
    logical=""
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      logical="${logical:+$logical }$line"
      case "$logical" in *\\) logical=${logical%\\}; continue ;; esac   # keep joining
      case "$logical" in
        *"git clone"*github.com[:/]"$owner"/*)
          # A real pin is an IMMUTABLE ref. Pull out the --branch/-b value: empty
          # means no pin at all, and a well-known MUTABLE branch name (main/master/
          # …) is just as floating as none — block both; anything else (a tag) ok.
          brval=$(printf '%s' "$logical" | sed -nE 's/.*(^|[[:space:]])(--branch[ =]|-b[[:space:]]*)([^[:space:]]+).*/\3/p')
          brval=${brval//\"/}; brval=${brval//\'/}     # strip surrounding quotes
          # Heuristic blocklist of well-known mutable branch names (not exhaustive
          # by design — the authoritative reproducibility gate is the Cargo.lock
          # checks below + CI's --locked; this just catches the common offenders).
          # Matched case-insensitively so Main/MAIN/Develop are caught too.
          case "$(printf '%s' "$brval" | tr '[:upper:]' '[:lower:]')" in
            main | master | develop | dev | trunk | head | next | staging | release | canary)
              echo "[deps] FLOATING git clone — --branch '$brval' is a MUTABLE branch (pin a tag) in $wf:" >&2
              echo "       ${logical#"${logical%%[![:space:]]*}"}" >&2
              fail=1 ;;
            '')
              echo "[deps] FLOATING git clone of a sibling repo (add --branch v<X>) in $wf:" >&2
              echo "       ${logical#"${logical%%[![:space:]]*}"}" >&2
              fail=1 ;;
            *) : ;;                                        # pinned to a tag → ok
          esac ;;
      esac
      logical=""
    done < "$wf"
  done

  # actions/checkout of an explicit sibling repository: with no ref:. Parsed
  # with ruby's stdlib YAML when available; skipped (never failed) if ruby isn't.
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e '
      # aliases: is a ruby >= 2.7 kwarg; on older rubies (e.g. macOS system ruby)
      # passing it raises ArgumentError, which — if rescued straight to nil — would
      # silently skip EVERY workflow and disable this check. Fall back to a plain
      # safe_load there so the ref-pinning check still runs.
      def load_wf(f)
        YAML.safe_load(File.read(f), aliases: true)
      rescue ArgumentError
        (YAML.safe_load(File.read(f)) rescue nil)
      rescue
        nil
      end
      owner = ARGV[0]
      bad = []
      Dir.glob(".github/workflows/*.{yml,yaml}").each do |wf|
        doc = load_wf(wf)
        next unless doc.is_a?(Hash)
        (doc["jobs"] || {}).each_value do |job|
          next unless job.is_a?(Hash)
          (job["steps"] || []).each do |st|
            next unless st.is_a?(Hash)
            next unless st["uses"].to_s.start_with?("actions/checkout")
            w = st["with"] || {}
            repo = w["repository"].to_s
            next if repo.empty?
            next unless repo.split("/").first == owner        # sibling only
            bad << "#{wf}: actions/checkout #{repo} has no ref: (pin to a tag)" if w["ref"].to_s.empty?
          end
        end
      end
      unless bad.empty?
        STDERR.puts "[deps] FLOATING actions/checkout of a sibling repo (add ref: v<X>):"
        bad.each { |b| STDERR.puts "       #{b}" }
        exit 1
      end
    ' "$owner" || fail=1
  fi
fi

# ── 3. Cargo.lock consistency — only when the repo actually commits a lock ───
# Respect the repo's own convention: enforce the lock if it's tracked; never
# invent one for a library that deliberately gitignores it.
lock_tracked=0; git -C "$root" ls-files --error-unmatch Cargo.lock >/dev/null 2>&1 && lock_tracked=1
if [ "$lock_tracked" = 1 ] && [ ! -f "$root/Cargo.lock" ]; then
  echo "[deps] Cargo.lock is tracked but missing from the working tree." >&2
  echo "       Restore it: git checkout -- Cargo.lock   (or: cargo generate-lockfile)" >&2
  fail=1
elif [ -f Cargo.lock ]; then
  # Read name/version ONLY from the [package] section. A workspace root, or a
  # manifest carrying [[bin]]/[lib]/[workspace.dependencies] sections, has other
  # `name =`/`version =` keys; a first-match scan would grab the wrong one (or, in
  # a virtual workspace root with no [package], nothing meaningful) and either
  # mis-compare or silently no-op. Section-scoping keeps the drift check honest;
  # a manifest with no [package] (virtual workspace root) correctly yields empty
  # and the guarded block below skips.
  pkg=$(awk -F'"' '
    /^[[:space:]]*\[/ { inpkg = ($0 ~ /^[[:space:]]*\[package\]/) }
    inpkg && /^[[:space:]]*name[[:space:]]*=/ { print $2; exit }
  ' Cargo.toml)
  ver=$(awk -F'"' '
    /^[[:space:]]*\[/ { inpkg = ($0 ~ /^[[:space:]]*\[package\]/) }
    inpkg && /^[[:space:]]*version[[:space:]]*=/ { print $2; exit }
  ' Cargo.toml)
  if [ -n "$pkg" ] && [ -n "$ver" ]; then
    lockver=$(awk -v p="$pkg" '
      $0 == "name = \"" p "\"" { hit=1; next }
      hit && /^version = / { gsub(/^version = "|"$/, "", $0); print; exit }
    ' Cargo.lock)
    if [ -n "$lockver" ] && [ "$lockver" != "$ver" ]; then
      echo "[deps] Cargo.lock records $pkg = $lockver but Cargo.toml is $ver — the lock" >&2
      echo "       drifted from the manifest. Run: cargo generate-lockfile && git add Cargo.lock" >&2
      fail=1
    fi
  fi

  # ── 4. authoritative stale-lock check (cargo is the oracle), best-effort ──
  # `cargo metadata --locked` refuses to rewrite the lock and errors if it's out
  # of date. Run --offline so the hook stays fast and never touches the network.
  #
  # BUT only when the graph resolves the same as CI's. A crate with an EXTERNAL
  # `path = "../sibling"` dependency can't guarantee that locally: a sibling
  # checked out at a version that differs from what the lock records (routine in
  # multi-repo dev) makes cargo want to re-lock, which surfaces as the exact same
  # "cannot update the lock file" error as true staleness — a false block we must
  # not raise. So skip part 4 whenever an external path dep is present; CI (with
  # siblings pinned to their tagged versions) is the authoritative --locked
  # backstop, and parts 1–3 above still apply. Registry-only / in-repo-workspace
  # crates keep the full check.
  ext_path_dep=0
  while IFS= read -r toml; do
    # Anchor `path` to a key boundary (start / space / , / {) so it matches the
    # dependency `path =` key, not a suffix like `manifest-path =`; drop full-line
    # comments so a commented example doesn't count.
    if grep -vE '^[[:space:]]*#' "$toml" 2>/dev/null \
         | grep -qE '(^|[[:space:],{])path[[:space:]]*=[[:space:]]*"\.\.?/'; then ext_path_dep=1; break; fi
  done <<< "$tomls"
  if [ "$ext_path_dep" = 0 ]; then
    # BLOCK only on the staleness signal; any other failure (empty offline cache,
    # etc.) is an environment limitation → skip. gg_cargo returns 127 with no cargo.
    if err=$(cd "$root" && gg_cargo metadata --locked --offline --format-version 1 2>&1 >/dev/null); then
      : # lock is fresh
    else
      rc=$?
      if [ "$rc" != 127 ] && printf '%s\n' "$err" | grep -qiE 'cannot update the lock file|needs to be updated|out.?of.?date'; then
        echo "[deps] Cargo.lock is STALE — it no longer matches Cargo.toml:" >&2
        printf '%s\n' "$err" | grep -iE 'cannot update the lock file|needs to be updated|out.?of.?date' | head -1 | sed 's/^/       /' >&2
        echo "       Fix: cargo generate-lockfile && git add Cargo.lock" >&2
        fail=1
      fi
    fi
  fi
fi

# ── 5. the lock must record the sibling version the workflows PIN ───────────
# The gap part 4 leaves. It skips whenever an external path dep is present,
# deferring to CI's --locked — and that is the one case where the lock and the
# workflow can disagree without anything local noticing.
#
# HOW IT HAPPENS, and it happens constantly in multi-repo work: bump a sibling
# in its own checkout, then run ANY cargo command in a consumer — a build, a
# test, this hook's own clippy — and cargo re-resolves the path dependency and
# rewrites the consumer's lock to the sibling's new version. Commit that, and
# CI clones the sibling at the tag written in the workflow, finds a lock naming
# a version that tag does not have, and stops at:
#
#   error: cannot update the lock file … because --locked was passed
#
# Which is the pin doing its job, several minutes into a run, after a push.
# This says the same thing before the commit exists.
#
# EVERY FETCH OF THE SIBLING IS COMPARED, AND NOTHING ELSE COUNTS AS EVIDENCE.
# Earlier versions decided from "does the right version appear somewhere": a
# line pre-filter skipped any sibling whose name and version were not on one
# physical line (so a checkout block or a continued clone was never read), and
# an existential fallback passed a sibling as soon as ANY token in ANY workflow
# or chores.yml equalled the lock (so a stale --branch=TAG or tarball beside a
# correct ci.yml passed). Both are gone. The parser below finds each fetch —
# `git clone` into ../<sib>, `actions/checkout` with path <sib> or ../<sib>, a
# GitHub archive/release tarball of <sib>, `gh release download -R …/<sib>` —
# resolves its tag, and reports every one that differs from the lock. A fetch
# whose tag cannot be determined is REPORTED ("not checked"), never passed: a
# silent skip reads exactly like a pass. A sibling no workflow fetches is not
# this check's business and passes.
#
# `../<sibling>` (or checkout `path:`) IS THE DISCRIMINATOR for clones and
# checkouts: a workflow may legitimately clone the same sibling into
# RUNNER_TEMP at the version a DIFFERENT crate wants. A tarball's destination
# cannot be read reliably, so every tarball of the sibling is compared.
#
# THE WORKFLOW IS READ AS YAML STRUCTURE, by indentation, not line by line:
#   - an `env:` value resolves with Actions' own scoping — step over job over
#     workflow, then chores.yml — whatever order the keys are written in. A
#     step's `env:` below its `run:` is valid YAML and applies to that run; a
#     later job's `env:` does not.
#   - a checkout's `with:` block ends where the YAML says it does (dedent), not
#     after a fixed number of lines, so four ordinary options no longer hide it.
#   - scalars are unquoted and trailing comments dropped, so `"v0.2.7"`,
#     `'v0.2.7'` and `v0.2.7 # core` all mean v0.2.7.
if [ -f Cargo.lock ] && [ -d .github/workflows ]; then
  # shellcheck disable=SC2016  # $ and ${{ }} are awk/YAML text, not shell.
  pin_awk='
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    # A YAML scalar as its value: quotes removed, a trailing comment dropped.
    function scalar(v,   q, i) {
      v = trim(v); q = substr(v, 1, 1)
      if (q == "\"" || q == "\047") {
        i = index(substr(v, 2), q)
        return (i > 0) ? substr(v, 2, i - 1) : substr(v, 2)
      }
      sub(/[[:space:]]+#.*$/, "", v)
      return trim(v)
    }
    function unquote(t) { gsub(/["\047]/, "", t); return t }
    function endswith(s, x) { return length(s) >= length(x) && substr(s, length(s) - length(x) + 1) == x }
    function lastseg(r) { r = unquote(r); sub(/\/+$/, "", r); sub(/\.git$/, "", r); sub(/^.*\//, "", r); return r }
    function isver(v) { return v ~ /^(refs\/tags\/)?v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]*)?$/ }
    function norm(v) { sub(/^refs\/tags\//, "", v); sub(/^v/, "", v); return v }
    # `${{ env.NAME }}` becomes `$NAME`, so one resolver serves both spellings.
    function envexpr(s,   out, m) {
      out = ""
      while (match(s, /\$\{\{[[:space:]]*env\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\}\}/)) {
        m = substr(s, RSTART, RLENGTH)
        sub(/^\$\{\{[[:space:]]*env\./, "", m); sub(/[[:space:]]*\}\}$/, "", m)
        out = out substr(s, 1, RSTART - 1) "$" m
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    # A name as the step that uses it sees it: a shell alias set in that
    # step, then step env, job env, workflow env, chores.yml.
    function lookup(name, st, jb) {
      if ((st, name) in alias) name = alias[st, name]
      if ((st, name) in envS) return envS[st, name]
      if ((jb, name) in envJ) return envJ[jb, name]
      if (name in envW) return envW[name]
      if (name in chores) return chores[name]
      return ""
    }
    function fetch(what, ref, ln, st, jb) {
      nf++; Fw[nf] = what; Fr[nf] = ref; Fl[nf] = ln; Fs[nf] = st; Fj[nf] = jb
    }
    # One shell command (a logical line split at && || ;).
    function command(s, ln,   n, tok, i, t, ref, slot, rest, k) {
      n = split(trim(s), tok, /[[:space:]]+/)
      if (s ~ /(^|[[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*clone([[:space:]]|$)/) {
        slot = 0; ref = ""
        for (i = 1; i <= n; i++) {
          t = unquote(tok[i]); sub(/\/+$/, "", t)
          if (t == "../" sib || endswith(t, "/../" sib)) slot = 1
          if (ref != "") continue
          if (tok[i] == "--branch" || tok[i] == "-b") ref = unquote(tok[i + 1])
          else if (tok[i] ~ /^--branch=/) ref = unquote(substr(tok[i], 10))
          else if (tok[i] ~ /^-b[^-]/) ref = unquote(substr(tok[i], 3))
        }
        if (slot) fetch("--branch", ref, ln, curstep, curjob)
        return
      }
      for (i = 1; i + 2 <= n; i++) {
        if (tok[i] != "gh" || tok[i + 1] != "release" || tok[i + 2] != "download") continue
        ref = (i + 3 <= n && tok[i + 3] !~ /^-/) ? unquote(tok[i + 3]) : ""
        for (k = i + 3; k <= n; k++) {
          t = ""
          if (tok[k] == "-R" || tok[k] == "--repo") t = tok[k + 1]
          else if (tok[k] ~ /^--repo=/) t = substr(tok[k], 8)
          if (t != "" && lastseg(t) == sib) { fetch("gh release download", ref, ln, curstep, curjob); break }
        }
        return
      }
      # A GitHub archive / release-asset / codeload URL of the sibling.
      for (i = 1; i <= n; i++) {
        t = unquote(tok[i])
        k = index(t, "/" sib "/"); rest = substr(t, k + length(sib) + 2)
        if (k == 0) { k = index(t, "/" sib ".git/"); rest = substr(t, k + length(sib) + 6) }
        if (k == 0) continue
        if (!match(rest, /^(archive\/(refs\/tags\/)?|releases\/download\/|(tarball|zipball)\/(refs\/tags\/)?|(legacy\.)?(tar\.gz|zip)\/(refs\/tags\/)?)/)) continue
        ref = substr(rest, RLENGTH + 1); sub(/\/.*$/, "", ref); sub(/\.(tar\.gz|tgz|zip)$/, "", ref)
        fetch("tarball", ref, ln, curstep, curjob)
      }
    }
    function logical(l, ln,   lhs, rhs, n, c, cmd) {
      l = envexpr(l)
      # ONE HOP THROUGH A SHELL ASSIGNMENT: `core_ref="$(pin FS_CORE_REF)"`,
      # the value living in chores.yml; the clone then reads `$core_ref`.
      if (l ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*\$\(pin[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\)/) {
        lhs = l; sub(/^[[:space:]]*/, "", lhs); sub(/=.*$/, "", lhs)
        rhs = l; sub(/^.*\$\(pin[[:space:]]+/, "", rhs); sub(/[[:space:]]*\).*$/, "", rhs)
        alias[curstep, lhs] = rhs
      }
      n = split(l, cmd, /&&|\|\||;/)
      for (c = 1; c <= n; c++) command(cmd[c], ln)
    }
    # Script lines of a run:, with backslash continuations joined — a clone
    # routinely puts --branch and ../<sib> on different physical lines.
    function script(s) {
      if (buf == "") bufline = FNR
      if (s ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", s); buf = buf s " "; return }
      buf = buf s; logical(buf, bufline); buf = ""
    }
    function flush() { if (buf != "") { logical(buf, bufline); buf = "" } }

    { sub(/\r$/, "") }
    # chores.yml: flat NAME: value pairs, the lowest-precedence scope.
    FILENAME == cf {
      if (match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/)) {
        k = trim(substr($0, 1, RLENGTH - 1)); v = scalar(substr($0, RLENGTH + 1))
        if (v != "") chores[k] = v
      }
      next
    }
    # Inside a `run: |` block: every line indented deeper than the key is script.
    inblock {
      if ($0 ~ /^[[:space:]]*$/) { script(""); next }
      match($0, /^ */)
      if (RLENGTH > blockind) { script($0); next }
      flush(); inblock = 0
    }
    /^[[:space:]]*(#.*)?$/ { next }
    /^(---|\.\.\.)/ { next }
    # The structure: a stack of (indent, key); a sequence item is "[n]".
    {
      match($0, /^ */); ind = RLENGTH; rest = substr($0, ind + 1)
      if (rest ~ /^-([[:space:]]|$)/) {
        while (sp > 0 && (sind[sp] > ind || (sind[sp] == ind && skey[sp] ~ /^\[/))) sp--
        items++; sp++; sind[sp] = ind; skey[sp] = "[" items "]"
        sub(/^-[[:space:]]*/, "", rest)
        if (rest == "" || rest ~ /^#/) next
        ind = length($0) - length(rest)
      } else {
        while (sp > 0 && sind[sp] >= ind) sp--
      }
      if (!match(rest, /^[^[:space:]#][^:]*:([[:space:]]|$)/)) next
      key = substr(rest, 1, RLENGTH); sub(/:[[:space:]]*$/, "", key); key = unquote(trim(key))
      val = substr(rest, RLENGTH + 1)
      sp++; sind[sp] = ind; skey[sp] = key
      jb = (sp >= 2 && skey[1] == "jobs") ? skey[2] : ""
      st = (sp >= 4 && jb != "" && skey[3] == "steps" && skey[4] ~ /^\[/) ? skey[4] : ""
      v = scalar(val)
      if (sp == 2 && skey[1] == "env") envW[key] = v
      else if (sp == 4 && jb != "" && skey[3] == "env") envJ[jb, key] = v
      else if (sp == 6 && st != "" && skey[5] == "env") envS[st, key] = v
      else if (sp == 6 && st != "" && skey[5] == "with") {
        if (key == "repository") { if (!(st in Wrepo)) Wlist[++wn] = st; Wrepo[st] = v; Wline[st] = FNR; Wjob[st] = jb }
        else if (key == "ref") Wref[st] = v
        else if (key == "path") Wpath[st] = v
      }
      else if (sp == 5 && st != "" && key == "run") {
        curstep = st; curjob = jb
        if (trim(val) ~ /^[|>]/) { inblock = 1; blockind = ind }
        else { script(v); flush() }
      }
    }
    END {
      flush()
      for (w = 1; w <= wn; w++) {
        st = Wlist[w]
        if (lastseg(Wrepo[st]) != sib) continue
        p = Wpath[st]; sub(/^\.\//, "", p); sub(/\/+$/, "", p)
        if (p != sib && p != "../" sib) continue
        fetch("ref:", envexpr(Wref[st]), Wline[st], st, Wjob[st])
      }
      for (i = 1; i <= nf; i++) {
        ref = Fr[i]; shown = Fw[i] " " ref
        if (ref == "") { printf "%s:%d: %s (no pin; not checked)\n", file, Fl[i], Fw[i]; continue }
        val = ref
        if (ref ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) {
          name = ref; gsub(/[$\{\}]/, "", name)
          val = lookup(name, Fs[i], Fj[i])
          if (val == "") { printf "%s:%d: %s (cannot resolve; not checked)\n", file, Fl[i], shown; continue }
          shown = shown " = " val
        }
        if (val ~ /\$/) { printf "%s:%d: %s (cannot resolve; not checked)\n", file, Fl[i], shown; continue }
        if (!isver(val)) { printf "%s:%d: %s (not a version tag; not checked)\n", file, Fl[i], shown; continue }
        if (norm(val) != want) printf "%s:%d: %s\n", file, Fl[i], shown
      }
    }
  '
  chores_file=""
  [ -f chores.yml ] && chores_file=chores.yml
  while IFS= read -r toml; do
    [ -f "$toml" ] || continue
    # `name = { path = "../sibling", … }` — the crate key and the directory it
    # points at, which is the sibling repository's name.
    while IFS='|' read -r crate sib; do
      [ -n "$crate" ] && [ -n "$sib" ] || continue
      lockver=$(awk -v p="$crate" '
        $0 == "name = \"" p "\"" { getline; if ($1 == "version") { gsub(/[":]/, "", $3); print $3; exit } }
      ' Cargo.lock)
      [ -n "$lockver" ] || continue
      bad=""
      for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
        [ -f "$wf" ] || continue
        # FILENAME, NOT `FNR == NR`, picks out chores.yml: with no chores.yml
        # the first argument is /dev/null, which contributes zero records, so
        # `FNR == NR` would hold for the whole workflow and nothing was checked.
        wf_bad=$(awk -v sib="$sib" -v want="$lockver" -v file="$wf" -v cf="${chores_file:-/dev/null}" \
                   "$pin_awk" "${chores_file:-/dev/null}" "$wf")
        [ -n "$wf_bad" ] && bad="${bad:+$bad
}$wf_bad"
      done
      [ -n "$bad" ] || continue
      echo "[deps] Cargo.lock records $crate = $lockver, and a workflow fetches $sib at something else." >&2
      echo "       These fetches of $sib do not match the lock (or could not be read):" >&2
      printf '         %s\n' "$bad" >&2
      echo "       CI clones the sibling at its pinned tag and then refuses the lock:" >&2
      echo "         error: cannot update the lock file … because --locked was passed" >&2
      echo "       Fix EITHER side: move the pin to v$lockver, or restore the lock" >&2
      echo "       (git checkout HEAD -- Cargo.lock) if the bump was accidental." >&2
      fail=1
    done < <(grep -vE '^[[:space:]]*#' "$toml" 2>/dev/null \
              | sed -nE 's@^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*\{[^}]*path[[:space:]]*=[[:space:]]*"\.\.?/([A-Za-z0-9._-]+)".*@\1|\2@p')
  done <<< "$tomls"
fi

if [ "$fail" != 0 ]; then
  echo "github-guard: rust-deps-pinned blocked the commit — pin your dependencies (above)." >&2
  echo "             Bypass once (NOT recommended): git commit --no-verify" >&2
  exit 1
fi
exit 0
