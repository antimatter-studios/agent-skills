---
name: dev-loop
description: Iterative development cycle with baseline test contract. Use when making non-trivial changes — refactoring, features, bug fixes, or code quality improvements.
---

# Development Loop

Iterative development cycle: test → analyze → implement → test → enhance tests → test → repeat.

## Arguments

- `$ARGUMENTS` — Description of what to work on (e.g. "add integer/number distinction in schema generation", "refactor the auth middleware"). If empty, analyze the codebase and propose improvements.

## Phase 0: Understand

Before changing anything:

1. **Detect the project type** — look for `go.mod` (Go), `package.json` (Node/TS), `Cargo.toml` (Rust), `pyproject.toml`/`setup.py` (Python), `Makefile`, etc. This determines which test/coverage/lint commands to use throughout. If a `Makefile` or `Taskfile.yml` exists, prefer its `test`/`lint` targets over raw commands.
2. **Read** all files relevant to the task. Never modify code you haven't read.
3. **Understand** existing patterns, conventions, and architecture.
4. **Identify** what tests exist and what they cover.

## File-edit collision guard (mandatory)

You may run alongside other writers — a teammate Claude, a hook, or the user's
own edits. To avoid silently clobbering their changes, every edit to an
**existing** file operates under a hash contract:

1. **On read** — when you Read a file you intend to modify, record its content
   hash: `shasum -a 256 <file>`. That hash is your baseline for this file.
2. **Before you write** — recompute the on-disk hash. If it still equals your
   baseline, the file is unchanged since you read it; proceed with your edit.
3. **If the hash differs** — someone else modified the file after you read it.
   **Do NOT overwrite it.** Re-read the file, then make a *smaller, surgical*
   `Edit` (a targeted `old_string`→`new_string`) that changes only your intended
   region and leaves the concurrent change intact. Never replace a changed file
   with your stale in-memory copy.
4. **Prefer `Edit` over `Write`** for existing files, always. Reserve full-file
   `Write` for brand-new files you are creating from scratch.
5. **Never delete a test** (or any file) without explicit user confirmation.

This closes the lost-update race: you read a file, a parallel writer edits and
saves it, and your later full-file write wipes out their change. The harness
already rejects a stale `Edit`; this guard adds the required recovery
(re-read → minimal in-place edit) and forbids full-overwrite of a file whose
hash moved.

## Phase 1: Baseline Test

Run the full test suite and capture which specific tests pass by name.
Use the exact pipeline for your project type — the grep must match **only passing tests**, not failures or summaries, or `comm -23` will produce false output later.

| Project type | Full extraction pipeline |
|---|---|
| Go | `go test -v -count=1 ./... 2>&1 \| grep -E "^--- PASS:" \| sort > /tmp/tests_baseline.txt` |
| Node/TS (jest) | `npx jest --verbose 2>&1 \| grep -E "^\s+✓" \| sort > /tmp/tests_baseline.txt` |
| Node/TS (vitest) | `npx vitest run --reporter=verbose 2>&1 \| grep -E "^\s+✓" \| sort > /tmp/tests_baseline.txt` |
| Rust | `cargo test -- --nocapture 2>&1 \| grep -E "^test .+ \.\.\. ok$" \| sort > /tmp/tests_baseline.txt` |
| Python (pytest) | `pytest -v 2>&1 \| grep " PASSED" \| sort > /tmp/tests_baseline.txt` |

The Rust pattern `^test .+ \.\.\. ok$` is deliberately strict — it matches only individual test lines (`test foo::bar ... ok`), not summary lines (`test result: ok.`) and not failures. A broader pattern will pollute `comm -23` with noise.

Every test MUST pass before any changes are made. If tests fail, stop and fix them first — that's the task now.

The file `/tmp/tests_baseline.txt` is the contract. Every named test in that file must still pass after every subsequent phase.

## Phase 2: Coverage Snapshot

Record baseline coverage. This is the floor — coverage must not drop below this after any iteration.

| Project type | Coverage command |
|---|---|
| Go | `go test -coverprofile=/tmp/cover_baseline.out ./... && go tool cover -func=/tmp/cover_baseline.out` |
| Node/TS (jest) | `npx jest --coverage` |
| Node/TS (vitest) | `npx vitest run --coverage` |
| Rust | `cargo llvm-cov --summary-only` (requires `llvm-tools-preview`: `rustup component add llvm-tools-preview`) |
| Python | `pytest --cov` (requires `pytest-cov`: `pip install pytest-cov`) |

Note the total coverage percentage.

**If the coverage tool is not installed: stop and tell the user what to install.** Do not skip this phase or proceed without a baseline — the coverage floor check in Phase 7 depends on this number. Once the user installs the tool, re-run this phase and continue.

## Phase 3: Analyze

Based on the task ($ARGUMENTS):

- If a specific task was given: analyze the relevant code, identify what needs to change, and plan the implementation.
- If no task was given: analyze the full codebase for issues — bugs, missing features, code quality problems, testability concerns, correctness gaps. Propose improvements ranked by impact.

Present findings to the user before proceeding. Get confirmation on what to implement.

## Phase 4: Implement

Make the changes. Follow these rules:

- **Small, focused changes** — one concern per iteration. Don't bundle unrelated changes.
- **Preserve existing behavior** unless explicitly changing it.
- **Don't add speculative features** — only what was agreed in Phase 3.
- **Don't "improve" code you're not changing** — no drive-by refactors.

## Phase 5: Post-Change Test

Run the full test suite and verify every baseline test still passes by name.

```
<test command> 2>&1 | tee /tmp/test_output_current.txt
```

Extract passing test names into `/tmp/tests_current.txt` using the same pattern as Phase 1.

Now check that every test from the baseline is still present and passing:

```
comm -23 /tmp/tests_baseline.txt /tmp/tests_current.txt
```

If this produces any output, those are tests that passed before but no longer pass. This is a **hard stop**.

**Rules:**

1. **Default assumption: your change broke something.** Fix your code, not the test.
2. **Exception: the test was asserting buggy behavior that you intentionally fixed.** In this case you may update the test — but you MUST explicitly call out to the user what changed, what the old assertion was, what the new one is, and why. Never silently update a test to make it pass.
3. **Never delete or rename a previously-passing test** to make the suite green. That hides regressions behind bookkeeping.

New tests appearing in `tests_current.txt` that weren't in `tests_baseline.txt` are fine — that's additive. The contract is one-directional: nothing from the baseline may disappear or fail.

## Phase 6: Enhance Tests

Now improve test coverage for the changes you made:

1. Run coverage analysis using the project-appropriate command from Phase 2.

2. Identify uncovered paths in the code you changed or added.

3. Add tests for:
   - Happy paths for new functionality
   - Edge cases and boundary conditions
   - Error paths and invalid inputs
   - Integration between new and existing code
   - **Pure functions** — any function with no I/O or side effects should have a unit test. No exceptions. If a pure function exists without a test, write one now even if you didn't change it.

4. Do NOT add tests for:
   - Stubs, dead code, or unreachable paths
   - Filesystem-dependent code that would create fragile tests
   - Functions you didn't change that already have coverage

5. **Every new test you write must pass immediately.** If a new test fails on arrival, that is a bug — either in your implementation (go back to Phase 4) or in your test. You just wrote the code; you should know what it does. A new test that fails is not "to be fixed later" — it means something is wrong right now.

6. After all new tests pass, **update the baseline** — the new tests are now part of the contract too. Re-extract passing test names into `/tmp/tests_baseline.txt`. The baseline only ever grows. It never shrinks.

## Phase 7: Final Test

Run the full suite one last time and verify the baseline contract:

```
<test command> 2>&1 | grep <pass pattern> | sort > /tmp/tests_final.txt
comm -23 /tmp/tests_baseline.txt /tmp/tests_final.txt
```

If `comm` produces any output — baseline tests are missing or failing. This includes both the original tests AND any tests added in Phase 6. Hard stop, fix before proceeding.

Then check that coverage did not drop below the Phase 2 baseline.

## Phase 8: Vet

Run static analysis to catch issues the tests won't:

| Project type | Lint/vet command |
|---|---|
| Go | `go vet ./...` |
| Node/TS | `npx eslint .` or `npx tsc --noEmit` |
| Rust | `cargo clippy` |
| Python | `ruff check .` or `flake8` |

Fix any findings.

## Phase 9: Iterate or Stop

Ask: is there more to do for this task?

- If the task from $ARGUMENTS is complete → stop and summarize what was done.
- If there are more improvements to make within the scope → go back to Phase 3.
- If you've run out of meaningful changes → stop. Don't invent work.

## Summary

When done, report:
- What changed (briefly)
- Baseline tests: all still passing (confirm)
- Test count: before → after (new tests added)
- Coverage: before → after
- Any issues discovered but not addressed (with rationale)
