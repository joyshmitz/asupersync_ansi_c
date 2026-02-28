# API Ergonomics Validation Gate

Bead linkage: `bd-56t.5` (executed under `bd-66l` quality-gate lane)

## Scope

This gate validates realistic public-header usage before API/ABI freeze by
compiling and running five vignette programs:

- `tests/vignettes/vignette_lifecycle.c`
- `tests/vignettes/vignette_obligations.c`
- `tests/vignettes/vignette_budgets.c`
- `tests/vignettes/vignette_replay.c`
- `tests/vignettes/vignette_hooks.c`

Execution path:

- Local: `make test-vignettes`
- CI: `.github/workflows/ci.yml` unit+invariant lane step `test-vignettes`

## Acceptance Criteria Mapping

1. Vignettes compile and run in CI against public headers.
- Implemented via `test-vignettes` in `Makefile` and CI wiring.
- Vignettes compile with public include path (`-I include`) and do not rely on
  internal test headers.

2. Ergonomics findings are documented with actionable outcomes.
- Findings and actions are recorded in this document.

3. Header freeze requires explicit ergonomics sign-off.
- This document serves as the sign-off record and must be referenced during
  API/ABI freeze review.

## Findings

### Good Ergonomics

- Budget constructors (`asx_budget_from_polls`, `asx_budget_infinite`) are
  concise and easy to adopt.
- Lifecycle happy-path (`asx_region_open` + `asx_task_spawn` +
  `asx_region_drain`) is straightforward.
- Hook initialization (`asx_runtime_hooks_init`) provides a safe baseline.
- Replay/snapshot digest APIs have clean value-return style for infallible
  operations.

### Friction Points

- `asx_task_spawn_captured(...)` has a long parameter list and requires manual
  post-spawn state initialization.
- Hook wiring requires repetitive nested field assignment for common cases.
- Budget exhaustion symbol naming in docs/vignettes must match canonical status
  constants to avoid user confusion.

## Actionable Outcomes

1. Keep current APIs for this phase; no blocking ergonomic defects found.
2. Track potential convenience additions for a later compatibility window:
- captured-task helper for state initialization,
- optional hook context convenience setter.
3. Ensure examples and docs always use canonical status symbols from
   `include/asx/asx_status.h`.

## Sign-off Decision

Status: **PASS**

Rationale: The current public API is usable for realistic lifecycle,
obligation, budget, replay, and freestanding-hook workflows without requiring
internal headers or unsafe patterns. Remaining friction is optimization-level,
not release-blocking.

Date: 2026-02-28
