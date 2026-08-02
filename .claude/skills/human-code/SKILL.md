---
name: human-code
description: Refactor code for human readability — finds magic numbers, god functions, duplication, dense logic, and deep nesting, then fixes each with a test-gated loop so regressions are caught immediately.
---

# Human Code

Make code readable by humans, not just computers. Works on any language.

## File-edit collision guard (mandatory)

Before editing any **existing** file, operate under a hash contract:

1. **On read** — record the file's content hash (`shasum -a 256 <file>`) as your baseline.
2. **Before you write** — recompute the on-disk hash. If it still matches your baseline, proceed.
3. **If the hash differs** — another writer (teammate, hook, user) changed the file since you read it. **Do NOT overwrite it.** Re-read, then make a *smaller, surgical* `Edit` (`old_string`→`new_string`) that touches only your region and preserves their change. Never replace a changed file with your stale in-memory copy.
4. **Prefer `Edit` over `Write`** for existing files. Reserve full-file `Write` for brand-new files.
5. **Never delete a test** (or any file) without explicit user confirmation.

This closes the lost-update race where a parallel writer's save is silently clobbered by your later full-file write. (Same contract as the dev-loop skill, which this composes with.)

## Arguments

- `$ARGUMENTS` — A file, directory, or description of the area to improve. If empty, scan the whole codebase and present a prioritised hit-list before touching anything.

## What to look for

Scan for these smells. Not all will be present — find what's actually there.

**Magic numbers and unnamed constants**
Raw literals (numbers, strings, byte values) with no name or explanation. `0xff`, `16`, `128`, `"SW009"` scattered through logic without context.

When naming a magic number, also check whether the same value (or related values of the same domain) appears elsewhere in the codebase. If it does, don't just name it in place — centralise the whole family into one location appropriate for the language:

| Language | Preferred home |
|---|---|
| Go | `const` block or `const` group in a dedicated `constants.go` or alongside the type that owns them |
| TypeScript/JS | `const` object or `enum` in a shared `constants.ts` |
| Python | Module-level constants in a `constants.py` or alongside the class that owns them |
| Rust | `const`/`static` items in a dedicated `constants.rs` or the module that owns them |
| C/C++ | `#define` group or `enum` in a shared header |

A named constant defined in isolation is better than a raw literal, but a named constant that lives next to its siblings — with a shared prefix or namespace — is better still. `maxIDDigits = 6` and `maxLenDigits = 8` belong together; `frameHeaderSize = 16` belongs with the other framing constants. Group by domain, not by file of first use.

**God functions**
Functions/methods that do more than one or two things. Signs: long scroll, multiple blank-line sections, comments like `// step 3: ...`, local variables only used in one block, mixed abstraction levels (high-level logic next to byte twiddling).

**Duplicated code**
The same logic appearing in two or more places with minor variation. Should be a shared function or parameterised helper.

**Dense, impenetrable expressions**
Chained array accesses, multi-level bit operations, long boolean expressions, deeply nested ternaries — anything that takes 30 seconds to parse mentally. Each should become a named variable or named function.

**Deep nesting / arrow code**
Three or more levels of `if`/`for`/`switch` nesting. Flatten with early returns, helper functions, or inversion.

**Comments that lie or explain WHAT**
Comments that restate the code (`i++ // increment i`) or that describe removed/changed logic. Comments should explain WHY — the non-obvious constraint, the workaround, the invariant.

**Misleading or opaque names**
Single-letter variables outside tiny loops, abbreviations that save three characters at the cost of comprehension, names that don't match what the thing actually does.

**Functions with too many parameters**
More than ~4 parameters usually means the function is doing too much or the parameters belong in a struct/type.

**Speculative or defensive code for scenarios that can't happen**
Null checks on values that are never null, error handling for errors the API guarantees won't occur, backwards-compatibility shims for callers that don't exist.

## Phase 0: Understand

1. Detect project type — `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml`, `Makefile`, etc.
2. If `$ARGUMENTS` names a file or directory, read it. If no argument, do a broad survey: file sizes, function lengths, obvious patterns.
3. Note the testing framework — you'll need this when you hand off to dev-loop.

## Phase 1: Scan and Triage

Walk the target code. For each smell found, record:
- **File and line range**
- **Category** (from the list above)
- **Severity**: High (causes confusion that could hide bugs), Medium (slows comprehension), Low (cosmetic)
- **Test coverage**: is this code covered? What tests exercise it?

Sort the list: High before Medium before Low. Within a tier, prefer changes where coverage already exists.

Present the full list to the user. Get explicit confirmation on which items to fix and in what order. **Do not proceed until confirmed.**

## Phase 2: Implement via dev-loop

Once the user confirms the items, hand the work to the **dev-loop** skill. Pass the confirmed item list as the task description. The items are already analyzed and confirmed — tell dev-loop to **skip Phase 3 and start from Phase 4**. dev-loop owns everything from there:

- Baseline test capture and contract
- Coverage snapshot
- Implementation — one item at a time, in confirmed priority order
- Regression check after every change
- New tests for any uncovered code touched
- Final verify and static analysis (clippy / vet / eslint)

The rename/extract rules below apply inside that implementation loop:

### Rename / extract rules

- New names must be more descriptive than what they replace, not just longer.
- Extracted functions must do one thing. If naming it is hard, it's doing too much.
- Constants should be named for their meaning, not their value (`maxIDDigits`, not `six`).
- Don't change external API signatures (exported names, function signatures used elsewhere) unless explicitly agreed.
- Don't rewrite working logic while renaming — one concern per change.
- Don't introduce abstractions that aren't justified by actual duplication (three instances minimum before extracting a helper).
- Don't touch code outside the agreed scope.

## Phase 3: Report Document

Write a report file at `docs/human-code-report-YYYY-MM-DD.md` (use the actual current date). This document is for the user to read at leisure and to reference when asking follow-up questions or requesting changes.

Structure the report as follows:

### Header
- Date, scope (files or "full codebase"), counts: N items found, M fixed, K skipped.

### Changes Made
One section per item fixed. For each:

**Title — short description of the smell**

- **Files:** link(s) to the changed file(s)
- **What changed:** a before/after code snippet showing the actual diff at the relevant lines. Keep snippets short — just enough to show the smell and its fix.
- **Why it's better:** one short paragraph explaining the readability gain. Focus on what a reader gains: what they no longer need to look up, what intent is now explicit, what confusion is eliminated.

### Items Skipped
A table: item ID | reason. Reasons fall into four categories:
- *Already done* — the smell was fixed before this session
- *False positive* — the triage was wrong about the code actually being problematic
- *Below threshold* — e.g. only 2 instances of a pattern, below the 3-instance extraction rule
- *Acceptable pattern* — the code is idiomatic or the "fix" would add indirection without adding clarity

### Test Results
A small table: tests passing before/after, tests failing before/after, coverage before/after, static analysis findings.

---

**Linking to the report:** After writing the file, tell the user where it is and invite them to read it and ask questions or request changes.

## Phase 4: Summary

Report concisely in the conversation:
- Items found vs items fixed (with rationale for anything skipped)
- Tests added to establish coverage before refactoring
- Before/after: baseline test count, any coverage change
- Any items deferred and why
- Path to the report document written in Phase 3
