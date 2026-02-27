# Lifecycle Transition Tables — Canonical Reference

> **Bead:** bd-296.15
> **Status:** Canonical spec artifact for implementation
> **Provenance:** Extracted from Rust source at `/dp/asupersync/src/record/{region,task,obligation}.rs` and `/dp/asupersync/src/types/cancel.rs`, cross-referenced with `PLAN_TO_PORT_ASUPERSYNC_TO_ANSI_C.md` sections 6.1–6.7
> **Rust baseline:** `RUST_BASELINE_COMMIT` (to be pinned per Section 1.1)
> **Last verified:** 2026-02-27 by MossySeal (Claude Opus 4.6)
> **Purpose:** Implementation-ready transition tables for region, task, obligation, and cancellation state machines — the foundation for all downstream semantics

---

## Table of Contents

1. [Region Lifecycle](#1-region-lifecycle)
2. [Task Lifecycle](#2-task-lifecycle)
3. [Obligation Lifecycle](#3-obligation-lifecycle)
4. [Cancellation Protocol](#4-cancellation-protocol)
5. [Outcome Severity Lattice](#5-outcome-severity-lattice)
6. [Cross-Domain Ordering Constraints](#6-cross-domain-ordering-constraints)
7. [Quiescence Invariant](#7-quiescence-invariant)
8. [Forbidden Behavior Catalog](#8-forbidden-behavior-catalog)
9. [Fixture ID Mapping](#9-fixture-id-mapping)
10. [Invariant Schema Cross-Reference](#10-invariant-schema-cross-reference)

---

## 1. Region Lifecycle

### 1.1 States

| State | Enum Value | Description |
|-------|-----------|-------------|
| `Open` | `ASX_REGION_OPEN` | Region is active; children (tasks, sub-regions, obligations) may be created |
| `Closing` | `ASX_REGION_CLOSING` | Close requested; no new children accepted; existing work continues |
| `Draining` | `ASX_REGION_DRAINING` | Actively waiting for child tasks and sub-regions to complete |
| `Finalizing` | `ASX_REGION_FINALIZING` | All children complete; resolving remaining obligations and cleanup |
| `Closed` | `ASX_REGION_CLOSED` | Terminal state; all resources released, arena eligible for reclamation |

### 1.2 Legal Transitions

| # | From | To | Trigger | Preconditions | Postconditions |
|---|------|----|---------|---------------|----------------|
| R1 | `Open` | `Closing` | `begin_close(reason)` | state==Open | No new spawns; cancel reason set if provided |
| R1a | `Open` | `Closing` | Parent region begins closing | Parent transitions to Closing/Draining | Cascading close propagated to child regions |
| R1b | `Open` | `Closing` | Cancellation propagated from parent | Parent cancel reaches this region | Cancel signal forwarded to child tasks |
| R2 | `Closing` | `Draining` | `begin_drain()` | state==Closing | Child cancellation requests issued; scheduler drives completion |
| `Closing` | `Finalizing` | `begin_finalize()` when no children | Region has no child tasks or sub-regions | Skip drain phase; begin finalizer execution (LIFO order) |
| `Draining` | `Finalizing` | All child tasks and sub-regions completed | Child task count == 0; child region count in `Closed` state; no pending work | Finalizer execution begins (LIFO order) |
| `Finalizing` | `Closed` | Finalization complete; quiescence verified | All obligations resolved; all tasks completed; all children closed; finalizers drained | Region arena reclaimed; close waiters notified; parent notified |

### 1.3 Forbidden Transitions (Must-Fail)

| From | To | Expected Error | Rationale |
|------|----|----------------|-----------|
| `Closing` | `Open` | `ASX_E_INVALID_TRANSITION` | Regions cannot reopen once close is initiated |
| `Draining` | `Open` | `ASX_E_INVALID_TRANSITION` | Regions cannot reopen |
| `Draining` | `Closing` | `ASX_E_INVALID_TRANSITION` | Cannot regress to prior phase |
| `Finalizing` | `Open` | `ASX_E_INVALID_TRANSITION` | Regions cannot reopen |
| `Finalizing` | `Closing` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Finalizing` | `Draining` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Closed` | (any) | `ASX_E_INVALID_TRANSITION` | Terminal state; no transitions allowed |
| `Open` | `Draining` | `ASX_E_INVALID_TRANSITION` | Must pass through `Closing` first |
| `Open` | `Finalizing` | `ASX_E_INVALID_TRANSITION` | Must pass through `Closing` first |
| `Open` | `Closed` | `ASX_E_INVALID_TRANSITION` | Must pass through full close sequence |
| `Closing` | `Closed` | `ASX_E_INVALID_TRANSITION` | Must pass through `Finalizing` first |
| `Draining` | `Closed` | `ASX_E_INVALID_TRANSITION` | Must pass through `Finalizing` |

**Note:** `Closing` → `Finalizing` is **LEGAL** when the region has no children (skips `Draining`). See transition in section 1.2.

### 1.4 Operations Gated by Region State

| Operation | Allowed States | Error if Wrong State |
|-----------|---------------|---------------------|
| Create child task | `Open`, `Finalizing` (tasks from finalizers) | `ASX_E_REGION_NOT_OPEN` / `ASX_E_ADMISSION_CLOSED` |
| Create child region | `Open` | `ASX_E_REGION_NOT_OPEN` / `ASX_E_ADMISSION_CLOSED` |
| Create obligation | `Open` | `ASX_E_REGION_NOT_OPEN` |
| Close region | `Open` | `ASX_E_INVALID_TRANSITION` (if not `Open`) |
| Query region status | (any) | Never fails |
| Access region arena (internal) | `Open`, `Closing`, `Draining`, `Finalizing` | `ASX_E_REGION_CLOSED` if `Closed` |

**Note:** `Finalizing` allows task creation because finalizers may need to spawn work that must complete before region closure. This is verified in Rust source (`admission_allowed_when_finalizing` test). However, child region creation is NOT allowed during `Finalizing`.

### 1.5 Region Close Precondition Checklist

Before a region transitions from `Finalizing` to `Closed`:

1. All child tasks in terminal state (`Completed`)
2. All child sub-regions in `Closed` state
3. All obligations resolved: `committed` or `aborted` (no `reserved` or `leaked`)
4. Cleanup stack fully drained (all registered cleanup actions executed)
5. Ghost linearity monitor confirms zero outstanding obligation count (debug mode)

If any precondition is violated, the region remains in `Finalizing` and reports `ASX_E_UNRESOLVED_OBLIGATIONS` or `ASX_E_INCOMPLETE_CHILDREN`.

---

## 2. Task Lifecycle

### 2.1 States

| State | Enum Value | Description |
|-------|-----------|-------------|
| `Created` | `ASX_TASK_CREATED` | Task allocated but not yet scheduled |
| `Running` | `ASX_TASK_RUNNING` | Task is actively being polled by the scheduler |
| `CancelRequested` | `ASX_TASK_CANCEL_REQUESTED` | Cancel signal received but task has not yet observed it |
| `Cancelling` | `ASX_TASK_CANCELLING` | Task has observed cancel and is performing cleanup |
| `Finalizing` | `ASX_TASK_FINALIZING` | Task cleanup complete; final outcome being determined |
| `Completed` | `ASX_TASK_COMPLETED` | Terminal state; outcome determined, resources released |

### 2.2 Legal Transitions (13 total of 36 state pairs)

| # | From | To | Trigger | Preconditions | Postconditions |
|---|------|----|---------|---------------|----------------|
| T1 | `Created` | `Running` | `start_running()` | state==Created | Task poll function invoked |
| T2 | `Created` | `CancelRequested` | `request_cancel()` | state==Created | Cancel before first poll; `cancel_epoch` incremented |
| T3 | `Created` | `Completed` | `complete(outcome)` | state==Created | Error/panic at spawn time |
| T4 | `Running` | `CancelRequested` | `request_cancel()` | state==Running | Cancel signal delivered; `cancel_epoch` incremented |
| T5 | `Running` | `Completed` | `complete(outcome)` | state==Running | Normal completion, error, or panic |
| T6 | `CancelRequested` | `CancelRequested` | `request_cancel()` | state==CancelRequested | **Strengthening:** reason severity raised; budget combined (min-plus); returns false |
| T7 | `CancelRequested` | `Cancelling` | `acknowledge_cancel()` | state==CancelRequested | Cleanup budget applied; `polls_remaining` set; returns CancelReason |
| T8 | `CancelRequested` | `Completed` | `complete(outcome)` | state==CancelRequested | Error/panic before cancel acknowledgement |
| T9 | `Cancelling` | `Cancelling` | `request_cancel()` | state==Cancelling | **Strengthening:** reason/budget updated; returns false |
| T10 | `Cancelling` | `Finalizing` | `cleanup_done()` | state==Cancelling | User cleanup code finished |
| T11 | `Cancelling` | `Completed` | `complete(outcome)` | state==Cancelling | Error/panic during cleanup |
| T12 | `Finalizing` | `Finalizing` | `request_cancel()` | state==Finalizing | **Strengthening:** reason/budget updated; returns false |
| T13 | `Finalizing` | `Completed` | `finalize_done()` | state==Finalizing | Produces `CancelWitness`; outcome is `Cancelled(reason)` |

**Strengthening semantics (T6, T9, T12):** These are not state changes. The cancel reason is strengthened via `reason.strengthen()` (higher severity wins, deterministic tie-break) and the cleanup budget is combined via `budget.combine()` (min on quota, max on priority). Return value is `false` indicating no new cancellation, just strengthening.

### 2.3 Forbidden Transitions (23 total)

**Backward transitions (10):**

| From | To | Expected Error | Rationale |
|------|----|----------------|-----------|
| `Running` | `Created` | `ASX_E_INVALID_TRANSITION` | No backward transitions |
| `CancelRequested` | `Running` | `ASX_E_INVALID_TRANSITION` | Cannot un-cancel |
| `CancelRequested` | `Created` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Cancelling` | `CancelRequested` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Cancelling` | `Running` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Cancelling` | `Created` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Finalizing` | `Cancelling` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Finalizing` | `CancelRequested` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Finalizing` | `Running` | `ASX_E_INVALID_TRANSITION` | Cannot regress |
| `Finalizing` | `Created` | `ASX_E_INVALID_TRANSITION` | Cannot regress |

**Skipped states (6):**

| From | To | Expected Error | Rationale |
|------|----|----------------|-----------|
| `Created` | `Cancelling` | `ASX_E_INVALID_TRANSITION` | Must pass through `CancelRequested` |
| `Created` | `Finalizing` | `ASX_E_INVALID_TRANSITION` | Must pass through `CancelRequested` then `Cancelling` |
| `Running` | `Cancelling` | `ASX_E_INVALID_TRANSITION` | Must pass through `CancelRequested` |
| `Running` | `Finalizing` | `ASX_E_INVALID_TRANSITION` | Must pass through `CancelRequested` then `Cancelling` |
| `CancelRequested` | `Finalizing` | `ASX_E_INVALID_TRANSITION` | Must pass through `Cancelling` |
| `Created` | `Created` | `ASX_E_INVALID_TRANSITION` | No self-loop (only cancel-related states allow strengthening) |

**From terminal (7):**

| From | To | Expected Error | Rationale |
|------|----|----------------|-----------|
| `Completed` | `Created` | `ASX_E_INVALID_TRANSITION` | Terminal is absorbing |
| `Completed` | `Running` | `ASX_E_INVALID_TRANSITION` | Terminal is absorbing |
| `Completed` | `CancelRequested` | `ASX_E_INVALID_TRANSITION` | Terminal is absorbing |
| `Completed` | `Cancelling` | `ASX_E_INVALID_TRANSITION` | Terminal is absorbing |
| `Completed` | `Finalizing` | `ASX_E_INVALID_TRANSITION` | Terminal is absorbing |
| `Completed` | `Completed` | `ASX_E_INVALID_TRANSITION` | No self-loop from terminal |

**Note:** In debug builds, invalid transitions trigger `debug_assert!` with message `"invalid TaskPhase transition: {current:?} -> {phase:?}"`. In release builds, methods return `false`/`None` without panicking.

### 2.3.1 Transition Matrix (Machine-Readable)

```text
6x6 matrix (36 total pairs: 13 valid, 23 invalid)

From\To        Created  Running  CancelReq  Cancelling  Finalizing  Completed
Created           .       T1       T2           .           .          T3
Running           .        .       T4           .           .          T5
CancelReq         .        .       T6          T7           .          T8
Cancelling        .        .        .          T9          T10         T11
Finalizing        .        .        .           .          T12         T13
Completed         .        .        .           .           .           .
```

### 2.4 Task Poll Contract

| Poll Return | Meaning | State Transition |
|------------|---------|-----------------|
| `ASX_POLL_PENDING` | Task yielded; needs to be rescheduled | Remains in current state (`Running` or `Cancelling`) |
| `ASX_POLL_READY` | Task completed its work | Transitions toward `Completed` (via `Finalizing` if cleanup needed) |
| `ASX_POLL_ERROR` | Task encountered fatal error | Records `Err` outcome; transitions toward `Completed` |

### 2.5 Cancellation Observation Rules

1. Cancel signals are delivered by setting `CancelRequested` on the task
2. Task does **not** see cancel until it calls `asx_checkpoint()` or `asx_is_cancelled()`
3. Between `CancelRequested` and observation, task continues with its normal poll logic
4. Once cancel is observed, task **must** transition to `Cancelling` within bounded cleanup budget
5. If cleanup budget is exceeded, scheduler may force-complete with `Cancelled` outcome
6. A task that completes naturally while in `CancelRequested` produces its **natural outcome**, not `Cancelled`

---

## 3. Obligation Lifecycle

### 3.1 States

| State | Enum Value | Description |
|-------|-----------|-------------|
| `Reserved` | `ASX_OBLIGATION_RESERVED` | Resource/promise reserved but not yet fulfilled |
| `Committed` | `ASX_OBLIGATION_COMMITTED` | Terminal: obligation fulfilled successfully |
| `Aborted` | `ASX_OBLIGATION_ABORTED` | Terminal: obligation explicitly cancelled/rolled back |
| `Leaked` | `ASX_OBLIGATION_LEAKED` | Terminal (error): obligation not resolved before region finalization |

### 3.2 Legal Transitions

| From | To | Trigger | Preconditions | Postconditions |
|------|----|---------|---------------|----------------|
| `Reserved` | `Committed` | `asx_obligation_commit()` | Obligation in `Reserved` state; owning task/region active | Resource guarantee fulfilled; linearity ledger bit cleared |
| `Reserved` | `Aborted` | `asx_obligation_abort()` | Obligation in `Reserved` state | Resource released; linearity ledger bit cleared |
| `Reserved` | `Leaked` | Region finalization detects unresolved obligation | Region enters `Finalizing` with outstanding `Reserved` obligations | Leak reported; error logged; region close may proceed with policy-dependent behavior |

### 3.3 Forbidden Transitions (Must-Fail)

| From | To | Expected Error | Rationale |
|------|----|----------------|-----------|
| `Committed` | (any) | `ASX_E_OBLIGATION_ALREADY_RESOLVED` | Terminal state; exactly-once semantics |
| `Aborted` | (any) | `ASX_E_OBLIGATION_ALREADY_RESOLVED` | Terminal state; exactly-once semantics |
| `Leaked` | (any) | `ASX_E_OBLIGATION_LEAKED` | Terminal error state |
| `Reserved` | `Reserved` | `ASX_E_INVALID_TRANSITION` | Cannot re-reserve |
| `Committed` | `Aborted` | `ASX_E_OBLIGATION_ALREADY_RESOLVED` | Cannot change resolved outcome |
| `Aborted` | `Committed` | `ASX_E_OBLIGATION_ALREADY_RESOLVED` | Cannot change resolved outcome |

### 3.4 Linearity Enforcement

The obligation lifecycle enforces **exactly-once resolution** (linear use):

1. Every `reserve` operation sets a bit in the linearity ledger
2. Every `commit` or `abort` clears the corresponding bit
3. During region `Finalizing`, a `popcnt` of the ledger verifies all bits are cleared
4. Non-zero count at finalization triggers leak detection:
   - Each unresolved obligation transitions to `Leaked`
   - Ghost linearity monitor logs the creation site and owner task
   - Region close proceeds (obligations are marked leaked, not silently dropped)

### 3.5 Obligation-Region Interaction

| Region State | Obligation Creation Allowed | Obligation Resolution Allowed |
|-------------|---------------------------|------------------------------|
| `Open` | Yes | Yes |
| `Closing` | No (`ASX_E_REGION_NOT_OPEN`) | Yes |
| `Draining` | No | Yes |
| `Finalizing` | No | Yes (resolution of remaining obligations); leak detection active |
| `Closed` | No | No (all obligations must be resolved or leaked before `Closed`) |

### 3.6 Double-Resolution Handling

Attempting to resolve an already-resolved obligation is a hard error:

- `commit` on `Committed` -> `ASX_E_OBLIGATION_ALREADY_RESOLVED`
- `abort` on `Committed` -> `ASX_E_OBLIGATION_ALREADY_RESOLVED`
- `commit` on `Aborted` -> `ASX_E_OBLIGATION_ALREADY_RESOLVED`
- `abort` on `Aborted` -> `ASX_E_OBLIGATION_ALREADY_RESOLVED`

This is **not** idempotent by design; double-resolution indicates a logic error.

---

## 4. Cancellation Protocol

### 4.1 Cancellation Phases

| Phase | Rank | Enum Value | Description |
|-------|------|-----------|-------------|
| `Requested` | 0 | `ASX_CANCEL_REQUESTED` | Cancel requested; not yet observed by target |
| `Cancelling` | 1 | `ASX_CANCEL_CANCELLING` | Target has observed cancel; cleanup in progress |
| `Finalizing` | 2 | `ASX_CANCEL_FINALIZING` | Cleanup complete; final outcome determination |
| `Completed` | 3 | `ASX_CANCEL_COMPLETED` | Cancellation protocol complete; outcome is `Cancelled` |

**Note:** There is no `None` phase. The absence of cancellation is represented by no `CancelWitness` existing for the task. The first witness creation is always valid regardless of initial phase.

### 4.2 Legal Phase Transitions

Phase transitions are valid when `next.phase.rank() >= prev.phase.rank()` (monotone non-decreasing):

| From | To | Trigger | Preconditions | Postconditions |
|------|----|---------|---------------|----------------|
| (initial) | `Requested` | `request_cancel()` or parent propagation | Target exists and is not terminal | Cancel witness created; `cancel_epoch` set; target task moves to `CancelRequested` |
| `Requested` | `Requested` | Additional `request_cancel()` | Already in CancelRequested | Strengthening: reason/budget updated (idempotent) |
| `Requested` | `Cancelling` | `acknowledge_cancel()` at checkpoint | Target calls `asx_checkpoint()` | Cleanup budget activated; cleanup begins |
| `Requested` | `Finalizing` | Skip cancelling phase | Short cleanup path | Direct to finalization |
| `Requested` | `Completed` | Target completes before observing | Task reaches Completed naturally | Cancel signal consumed; natural outcome preserved |
| `Cancelling` | `Cancelling` | Additional `request_cancel()` | Already in Cancelling | Strengthening: reason/budget updated (idempotent) |
| `Cancelling` | `Finalizing` | `cleanup_done()` | All registered cleanup actions executed | Final outcome computation |
| `Cancelling` | `Completed` | `complete(outcome)` | Error/panic during cleanup | `Cancelled` or panic outcome recorded |
| `Finalizing` | `Finalizing` | Additional `request_cancel()` | Already in Finalizing | Strengthening: reason/budget updated (idempotent) |
| `Finalizing` | `Completed` | `finalize_done()` | Final outcome determined | `Cancelled` outcome with full witness metadata |
| `Completed` | `Completed` | N/A | N/A | Terminal state; self-loop is no-op |

### 4.3 Forbidden Phase Transitions

Phase transitions where `next.phase.rank() < prev.phase.rank()`:

| From | To | Expected Error | Rationale |
|------|----|----------------|-----------|
| `Cancelling` | `Requested` | `ASX_E_WITNESS_PHASE_REGRESSION` | Cannot regress phase rank (1 -> 0) |
| `Finalizing` | `Requested` | `ASX_E_WITNESS_PHASE_REGRESSION` | Cannot regress phase rank (2 -> 0) |
| `Finalizing` | `Cancelling` | `ASX_E_WITNESS_PHASE_REGRESSION` | Cannot regress phase rank (2 -> 1) |
| `Completed` | `Requested` | `ASX_E_WITNESS_PHASE_REGRESSION` | Cannot regress phase rank (3 -> 0) |
| `Completed` | `Cancelling` | `ASX_E_WITNESS_PHASE_REGRESSION` | Cannot regress phase rank (3 -> 1) |
| `Completed` | `Finalizing` | `ASX_E_WITNESS_PHASE_REGRESSION` | Cannot regress phase rank (3 -> 2) |

**Note:** The cancellation protocol does NOT have a `None` phase state. The absence of cancellation is represented by having no `CancelWitness` at all. The first witness creation (from no prior witness) is always valid. Phase transitions that skip intermediate phases (e.g., `Requested` -> `Completed`) are ALLOWED because the phase rank is non-decreasing.

**Additionally forbidden:** Any witness transition where `next.reason.severity() < prev.reason.severity()` produces `ASX_E_WITNESS_REASON_WEAKENED`.

### 4.4 Cancellation Kinds (11 Variants with Severity Ladder)

| Kind | Enum Value | Severity | Cleanup Quota | Cleanup Priority | Category |
|------|-----------|----------|--------------|-----------------|----------|
| `User` | `ASX_CANCEL_USER` | 0 | 1000 | 200 | Explicit/gentle |
| `Timeout` | `ASX_CANCEL_TIMEOUT` | 1 | 500 | 210 | Time-based |
| `Deadline` | `ASX_CANCEL_DEADLINE` | 1 | 500 | 210 | Time-based |
| `PollQuota` | `ASX_CANCEL_POLL_QUOTA` | 2 | 300 | 215 | Resource budget |
| `CostBudget` | `ASX_CANCEL_COST_BUDGET` | 2 | 300 | 215 | Resource budget |
| `FailFast` | `ASX_CANCEL_FAIL_FAST` | 3 | 200 | 220 | Sibling/peer |
| `RaceLost` | `ASX_CANCEL_RACE_LOST` | 3 | 200 | 220 | Sibling/peer |
| `LinkedExit` | `ASX_CANCEL_LINKED_EXIT` | 3 | 200 | 220 | Sibling/peer |
| `ParentCancelled` | `ASX_CANCEL_PARENT` | 4 | 200 | 220 | Structural |
| `ResourceUnavailable` | `ASX_CANCEL_RESOURCE` | 4 | 200 | 220 | Structural |
| `Shutdown` | `ASX_CANCEL_SHUTDOWN` | 5 | 50 | 255 | System-level |

**Severity rules:**
- Higher severity always wins in `strengthen()` operations
- Equal severity: deterministic tie-break by earlier timestamp, then lexicographically smaller message
- Severity is monotone non-decreasing across witness transitions

**Budget combination (min-plus algebra):**
- `combined_quota = min(quota1, quota2)` -- tighter quota wins
- `combined_priority = max(priority1, priority2)` -- higher urgency wins
- Monotone-narrowing: combining never widens the cleanup allowance

### 4.5 Cancellation Witness Structure

Each cancellation witness carries:

| Field | Type | Description |
|-------|------|-------------|
| `task_id` | `asx_task_id` | The task being cancelled |
| `region_id` | `asx_region_id` | The owning region |
| `epoch` | `uint64_t` | Cancellation epoch (increments on first request; constant thereafter) |
| `phase` | `asx_cancel_phase` | Current phase of the cancellation protocol |
| `reason` | `asx_cancel_reason` | Full cancellation reason with kind, origin, timestamp, and cause chain |

### 4.6 Witness Validation Rules

A witness transition from `prev` to `next` is valid when ALL hold:

| Rule | Check | Error on Violation |
|------|-------|-------------------|
| Same task | `prev.task_id == next.task_id` | `ASX_E_WITNESS_TASK_MISMATCH` |
| Same region | `prev.region_id == next.region_id` | `ASX_E_WITNESS_REGION_MISMATCH` |
| Same epoch | `prev.epoch == next.epoch` | `ASX_E_WITNESS_EPOCH_MISMATCH` |
| Phase monotone | `next.phase.rank >= prev.phase.rank` | `ASX_E_WITNESS_PHASE_REGRESSION` |
| Severity monotone | `next.reason.severity >= prev.reason.severity` | `ASX_E_WITNESS_REASON_WEAKENED` |

### 4.7 Attribution Chain

`CancelReason` carries a recursive cause chain:

| Field | Type | Description |
|-------|------|-------------|
| `kind` | `asx_cancel_kind` | The cancellation kind |
| `origin_region` | `asx_region_id` | Region that initiated cancellation |
| `origin_task` | `asx_task_id` (optional) | Task that initiated (if applicable) |
| `timestamp` | `asx_time` | When the cancellation was requested |
| `message` | `const char*` (optional) | Human-readable message |
| `cause` | `asx_cancel_reason*` (optional) | Parent cause in the chain |
| `truncated` | `bool` | Whether the chain was truncated at limits |

**Chain limits (configurable):**
- `max_chain_depth`: default 16
- `max_chain_memory`: default 4096 bytes (~88 bytes per level)
- Truncated chains set `truncated=true` and record truncation depth

### 4.8 Cancellation Metadata (Legacy Section)

Each cancellation carries these operational fields:

| Field | Type | Description |
|-------|------|-------------|
| `reason_kind` | enum | Why cancellation was initiated (see 4.4) |
| `attribution_chain` | bounded chain | Recursive cause chain with configurable depth/memory limits |
| `cleanup_budget` | `asx_budget` | Budget allocated for cleanup phase (determined by cancel kind) |
| `epoch` | `uint64_t` | Monotonically increasing cancel epoch for ordering |
| `phase` | `asx_cancel_phase` | Current phase of the cancellation protocol |

### 4.5 Cancellation Propagation Rules

1. When a region begins closing, cancel is propagated to all child tasks
2. Cancel propagates **depth-first** through the region tree
3. Each child task receives its own cancel witness with attribution chain extended
4. Cancel does **not** propagate to sibling regions (only parent-to-child)
5. A task that is already in `CancelRequested` or later ignores duplicate cancel signals (idempotent delivery)
6. Cancel propagation is deterministic: same tree structure + same trigger = same propagation order

### 4.6 Cleanup Budget Contract

1. When a task enters `Cancelling`, a cleanup budget is activated
2. The cleanup budget specifies maximum time/poll-cycles for cleanup
3. If cleanup exceeds budget, the scheduler may force-complete the task
4. Force-completion records the original cancel reason plus `cleanup_budget_exceeded` flag
5. Cleanup budget exhaustion is a deterministic, logged event (not silent)

---

## 5. Outcome Severity Lattice

### 5.1 Severity Ordering

```
Ok < Err < Cancelled < Panicked
```

This is a total order. The "worst" outcome dominates in joins/aggregations.

### 5.2 Outcome Values

| Outcome | Enum Value | Severity Rank | Description |
|---------|-----------|---------------|-------------|
| `Ok` | `ASX_OUTCOME_OK` | 0 (lowest) | Task completed successfully |
| `Err` | `ASX_OUTCOME_ERR` | 1 | Task encountered an error |
| `Cancelled` | `ASX_OUTCOME_CANCELLED` | 2 | Task was cancelled via cancellation protocol |
| `Panicked` | `ASX_OUTCOME_PANICKED` | 3 (highest) | Task encountered an unrecoverable failure |

### 5.3 Join Semantics

When aggregating outcomes from multiple children (e.g., region close):

```
join(a, b) = max(severity(a), severity(b))
```

Properties:

- **Commutative:** `join(a, b) == join(b, a)`
- **Associative:** `join(join(a, b), c) == join(a, join(b, c))`
- **Idempotent:** `join(a, a) == a`
- **Identity element:** `Ok` (joining with `Ok` preserves the other outcome)
- **Absorbing element:** `Panicked` (joining with `Panicked` always yields `Panicked`)

### 5.4 Outcome Join Truth Table

| Left | Right | Result |
|------|-------|--------|
| `Ok` | `Ok` | `Ok` |
| `Ok` | `Err` | `Err` |
| `Ok` | `Cancelled` | `Cancelled` |
| `Ok` | `Panicked` | `Panicked` |
| `Err` | `Err` | `Err` |
| `Err` | `Cancelled` | `Cancelled` |
| `Err` | `Panicked` | `Panicked` |
| `Cancelled` | `Cancelled` | `Cancelled` |
| `Cancelled` | `Panicked` | `Panicked` |
| `Panicked` | `Panicked` | `Panicked` |

### 5.5 Region Outcome Computation

A region's outcome is the join of all child task outcomes:

```
region_outcome = fold(join, Ok, [child_1_outcome, child_2_outcome, ..., child_n_outcome])
```

If a region has no children, its outcome is `Ok`.

---

## 6. Cross-Domain Ordering Constraints

### 6.1 Region-Task Ordering

1. A task can only be created in a region that is `Open`
2. A task's owning region must remain in a non-`Closed` state while the task is non-terminal
3. Region `Draining` -> `Finalizing` transition requires all owned tasks to be `Completed`
4. Task completion notifies the owning region for drain progress tracking

### 6.2 Task-Obligation Ordering

1. An obligation can only be created by a task whose owning region is `Open`
2. Obligations are associated with both the creating task and the owning region
3. Task `Completed` does **not** automatically resolve outstanding obligations
4. Outstanding obligations at region `Finalizing` are detected and leaked

### 6.3 Cancel-Region Ordering

1. Region `Closing` triggers cancel propagation to child tasks
2. Cancel propagation completes before region can advance to `Draining`
3. Task cancel completion contributes to region drain progress
4. All cancel-completing tasks must reach `Completed` before region leaves `Draining`

### 6.4 Deterministic Ordering Keys

For deterministic scheduling and replay:

| Context | Tie-Break Key | Ordering |
|---------|--------------|----------|
| Ready queue | `(lane_priority, logical_deadline, task_id, insertion_seq)` | Ascending (lower = higher priority) |
| Timer wheel | `(expiry_tick, insertion_seq)` | Ascending (earlier = fires first) |
| Cancel propagation | Depth-first traversal of region tree | Deterministic tree walk order |
| Event journal | `(event_seq)` | Strictly monotonic per runtime |

---

## 7. Quiescence Invariant

### 7.1 Definition

A runtime is **quiescent** when:

1. No live tasks (all tasks in `Completed` state)
2. No live obligations (all obligations in terminal state: `Committed`, `Aborted`, or `Leaked`)
3. No live non-finalized region work (all regions in `Closed` state or never opened)
4. No pending timer expirations in the timer wheel
5. No pending channel messages awaiting delivery
6. (Profile-dependent) No pending I/O registrations

### 7.2 Quiescence Checks

| Check | Condition | Error if Violated |
|-------|-----------|-------------------|
| Task quiescence | `active_task_count == 0` | `ASX_E_TASKS_STILL_ACTIVE` |
| Obligation quiescence | `reserved_obligation_count == 0` | `ASX_E_OBLIGATIONS_UNRESOLVED` |
| Region quiescence | All regions `Closed` | `ASX_E_REGIONS_NOT_CLOSED` |
| Timer quiescence | Timer wheel empty | `ASX_E_TIMERS_PENDING` |
| Channel quiescence | All channels drained | `ASX_E_CHANNEL_NOT_DRAINED` |

### 7.3 Quiescence and Runtime Shutdown

1. Runtime shutdown initiates close on the root region
2. Close cascades through region tree (depth-first)
3. Scheduler drives all tasks through cancel/complete paths
4. Timer wheel is drained (expired timers fire; pending timers are cancelled)
5. Channels are drained (pending sends are rejected or completed)
6. Runtime reports quiescence or failure to reach quiescence with diagnostic

---

## 8. Forbidden Behavior Catalog

### 8.1 Critical Forbidden Behaviors (Must-Fail Immediately)

| ID | Forbidden Behavior | Expected Result | Fixture Category |
|----|-------------------|-----------------|------------------|
| FB-001 | Create child task in non-`Open` region | `ASX_E_REGION_NOT_OPEN` | region-gate |
| FB-002 | Create obligation in non-`Open` region | `ASX_E_REGION_NOT_OPEN` | region-gate |
| FB-003 | Double-commit obligation | `ASX_E_OBLIGATION_ALREADY_RESOLVED` | obligation-linearity |
| FB-004 | Double-abort obligation | `ASX_E_OBLIGATION_ALREADY_RESOLVED` | obligation-linearity |
| FB-005 | Commit then abort obligation | `ASX_E_OBLIGATION_ALREADY_RESOLVED` | obligation-linearity |
| FB-006 | Abort then commit obligation | `ASX_E_OBLIGATION_ALREADY_RESOLVED` | obligation-linearity |
| FB-007 | Backward state transition (any domain) | `ASX_E_INVALID_TRANSITION` | transition-legality |
| FB-008 | Skip intermediate state in region close | `ASX_E_INVALID_TRANSITION` | transition-legality |
| FB-009 | Skip intermediate state in task lifecycle (e.g., Created->Cancelling, Running->Finalizing) | `ASX_E_INVALID_TRANSITION` | transition-legality |
| FB-010 | Operate on stale/freed handle | `ASX_E_STALE_HANDLE` | handle-safety |
| FB-011 | Close region with unresolved obligations | (obligation leaked, `ASX_E_UNRESOLVED_OBLIGATIONS` logged) | obligation-leak |
| FB-012 | Close region with active child tasks | Region blocks in `Draining` until children complete | region-drain |
| FB-013 | Cancel already-completed task | Idempotent no-op (not an error) | cancel-idempotent |
| FB-014 | Access region arena after `Closed` | `ASX_E_REGION_CLOSED` | region-access |
| FB-015 | Non-deterministic behavior in deterministic mode | Digest mismatch detected by ghost determinism monitor | determinism |

### 8.2 Resource Exhaustion Forbidden Behaviors

| ID | Forbidden Behavior | Expected Result | Fixture Category |
|----|-------------------|-----------------|------------------|
| FB-100 | Exceed max ready queue capacity | `ASX_E_RESOURCE_EXHAUSTED` (reject, no partial state) | exhaustion |
| FB-101 | Exceed max timer node count | `ASX_E_RESOURCE_EXHAUSTED` (reject, no partial state) | exhaustion |
| FB-102 | Exceed max cancel queue capacity | `ASX_E_RESOURCE_EXHAUSTED` (reject, no partial state) | exhaustion |
| FB-103 | Exceed runtime memory ceiling | `ASX_E_RESOURCE_EXHAUSTED` (failure-atomic, no corruption) | exhaustion |
| FB-104 | Exceed trace event capacity | `ASX_E_RESOURCE_EXHAUSTED` or ring-buffer overwrite (profile-dependent) | exhaustion |

### 8.3 Protocol Violation Forbidden Behaviors

| ID | Forbidden Behavior | Expected Result | Fixture Category |
|----|-------------------|-----------------|------------------|
| FB-200 | Yield across obligation boundary without copy | Ghost borrow ledger violation (debug) | protocol-safety |
| FB-201 | Mutable access during shared borrow epoch | Ghost borrow ledger violation (debug) | protocol-safety |
| FB-202 | Cross-thread access without transfer certificate | Ghost affinity violation (debug) | thread-safety |
| FB-203 | Non-checkpoint long-running loop in cancel path | CI lint/static analysis flag | checkpoint-coverage |

---

## 9. Fixture ID Mapping

Each transition rule and forbidden behavior maps to candidate fixture IDs for conformance testing.

### 9.1 Region Fixtures

| Fixture ID | Description | Tests |
|-----------|-------------|-------|
| `region-lifecycle-001` | Open -> Closing -> Draining -> Finalizing -> Closed (happy path) | Legal transition sequence |
| `region-lifecycle-002` | Open -> Closing with active children (drain required) | Drain blocking behavior |
| `region-lifecycle-003` | Nested region cascade close | Parent close propagates to children |
| `region-lifecycle-004` | Region close with unresolved obligations | Leak detection and reporting |
| `region-lifecycle-005` | Attempted backward transition (Closing -> Open) | Must fail with `ASX_E_INVALID_TRANSITION` |
| `region-lifecycle-006` | Attempted skip transition (Open -> Draining) | Must fail with `ASX_E_INVALID_TRANSITION` |
| `region-lifecycle-007` | Create task in non-Open region | Must fail with `ASX_E_REGION_NOT_OPEN` |
| `region-lifecycle-008` | Region arena access after Closed | Must fail with `ASX_E_REGION_CLOSED` |
| `region-lifecycle-009` | Empty region close (no children) | Fast path through all states |
| `region-lifecycle-010` | Region close under resource exhaustion | Failure-atomic close behavior |

### 9.2 Task Fixtures

| Fixture ID | Description | Tests |
|-----------|-------------|-------|
| `task-lifecycle-001` | Created -> Running -> Completed(Ok) (happy path) | Legal transition sequence |
| `task-lifecycle-002` | Full cancel: Created -> Running -> CancelRequested -> Cancelling -> Finalizing -> Completed(Cancelled) | All cancel phases traversed |
| `task-lifecycle-003` | CancelRequested -> Completed (natural completion before observation) | Natural outcome preserved, not `Cancelled` |
| `task-lifecycle-004` | Created -> CancelRequested (cancel before first poll) | T2: Legal transition |
| `task-lifecycle-005` | Created -> Completed(Err) (error at spawn) | T3: Legal transition |
| `task-lifecycle-006` | Cancel strengthen: multiple `request_cancel()` with increasing severity | T6/T9/T12: Reason/budget updated, returns false |
| `task-lifecycle-007` | Cancel strengthen budget combine: min-plus algebra | Combined quota=min, combined priority=max |
| `task-lifecycle-008` | Attempted backward transition (Running -> Created) | Must fail |
| `task-lifecycle-009` | Attempted skip transition (Running -> Cancelling) | Must fail (must go through CancelRequested) |
| `task-lifecycle-010` | Completed is absorbing: all transitions from Completed rejected | Must fail for all 6 possible targets |
| `task-lifecycle-011` | acknowledge_cancel() returns CancelReason and applies cleanup budget | T7: Budget applied, polls_remaining set |
| `task-lifecycle-012` | finalize_done() produces CancelWitness | T13: Witness with correct task_id, region_id, epoch, phase |
| `task-lifecycle-013` | cancel_epoch increments only on first cancel | Epoch=0 then 1, constant on strengthening |

### 9.3 Obligation Fixtures

| Fixture ID | Description | Tests |
|-----------|-------------|-------|
| `obligation-lifecycle-001` | Reserved -> Committed (happy path) | Legal transition |
| `obligation-lifecycle-002` | Reserved -> Aborted (rollback path) | Legal transition |
| `obligation-lifecycle-003` | Reserved -> Leaked (region finalization) | Leak detection |
| `obligation-lifecycle-004` | Double-commit | Must fail with `ASX_E_OBLIGATION_ALREADY_RESOLVED` |
| `obligation-lifecycle-005` | Double-abort | Must fail with `ASX_E_OBLIGATION_ALREADY_RESOLVED` |
| `obligation-lifecycle-006` | Commit then abort | Must fail with `ASX_E_OBLIGATION_ALREADY_RESOLVED` |
| `obligation-lifecycle-007` | Abort then commit | Must fail with `ASX_E_OBLIGATION_ALREADY_RESOLVED` |
| `obligation-lifecycle-008` | Linearity ledger zero check at region close | All bits cleared |
| `obligation-lifecycle-009` | Multiple obligations in single region | Independent lifecycle tracking |
| `obligation-lifecycle-010` | Obligation in non-Open region | Must fail with `ASX_E_REGION_NOT_OPEN` |

### 9.4 Cancellation Fixtures

| Fixture ID | Description | Tests |
|-----------|-------------|-------|
| `cancel-protocol-001` | Full cancel protocol happy path | All phases traversed |
| `cancel-protocol-002` | Cancel propagation through region tree | Depth-first order |
| `cancel-protocol-003` | Cancel with cleanup budget | Budget enforcement |
| `cancel-protocol-004` | Cancel budget exceeded | Force-completion behavior |
| `cancel-protocol-005` | Multiple cancel on same target | Idempotent |
| `cancel-protocol-006` | Cancel attribution chain | Correct chain recorded |
| `cancel-protocol-007` | Cancel reason kinds | Each reason kind produces correct metadata |
| `cancel-protocol-008` | Backward cancel phase transition | Must fail |
| `cancel-protocol-009` | Nested cancel (cancel during cancelling) | Handled correctly |
| `cancel-protocol-010` | Deterministic cancel propagation order | Same order on replay |

### 9.5 Outcome Fixtures

| Fixture ID | Description | Tests |
|-----------|-------------|-------|
| `outcome-lattice-001` | Severity ordering correctness | `Ok < Err < Cancelled < Panicked` |
| `outcome-lattice-002` | Join commutativity | `join(a,b) == join(b,a)` for all pairs |
| `outcome-lattice-003` | Join associativity | `join(join(a,b),c) == join(a,join(b,c))` |
| `outcome-lattice-004` | Join identity (Ok) | `join(Ok, x) == x` for all x |
| `outcome-lattice-005` | Join absorbing (Panicked) | `join(Panicked, x) == Panicked` for all x |
| `outcome-lattice-006` | Region outcome aggregation | Correct fold over children |
| `outcome-lattice-007` | Empty region outcome | `Ok` |

---

## 10. Invariant Schema Cross-Reference

This section maps each transition table to the machine-readable invariant schema rows that will be generated in `invariants/*.yaml` (per bd-296.4).

### 10.1 Schema Row Format (Conceptual)

```yaml
- domain: region          # region | task | obligation | cancel
  from_state: Open
  to_state: Closing
  trigger: region_close
  legal: true
  preconditions:
    - region.state == Open
  postconditions:
    - region.state == Closing
    - region.admission_gate == closed
  error_code: null
  fixture_ids:
    - region-lifecycle-001
    - region-lifecycle-002
```

### 10.2 Coverage Matrix

| Domain | Total States | Legal Transitions | Forbidden Transitions | Self-Transitions | Fixtures |
|--------|-------------|-------------------|----------------------|-----------------|----------|
| Region | 5 | 5 (+ skip path) | 12 | 0 | 13 |
| Task | 6 | 10 | 23 | 3 (strengthening) | 13 |
| Obligation | 4 | 3 | 9 | 0 | 11 |
| Cancellation | 4 phases | 7 | 6 | 4 (idempotent) | 11 |
| Cancel Kinds | 11 kinds | N/A (severity ladder) | N/A | N/A | N/A |
| Outcome | 4 | N/A (lattice) | N/A | N/A | 7 |
| **Total** | **34** | **25+** | **50** | **7** | **55** |

**Note on task transitions:** 13 total valid transitions = 10 state-changing + 3 strengthening self-transitions (T6, T9, T12).

### 10.3 Downstream Dependencies

This document is a canonical input for:

- **bd-296.17**: Extract deterministic channel/timer kernel semantics and tie-break ordering contract
- **bd-296.18**: Extract quiescence, close, cleanup, and leak-detection invariants for finalization paths
- **bd-296.4**: Author machine-readable invariant schema and generation pipeline
- **bd-296.6**: Publish Rust->C guarantee-substitution matrix
- **bd-296.1**: Create exhaustive `docs/EXISTING_ASUPERSYNC_STRUCTURE.md`
- **bd-296.19**: Build source-to-fixture provenance map
- **bd-1md.13**: Capture core semantic fixture families from Rust reference
- **bd-1md.15**: Capture vertical and continuity fixture families

---

## Appendix A: Error Code Reference (Transition-Related)

| Error Code | Value | Description |
|-----------|-------|-------------|
| `ASX_E_INVALID_TRANSITION` | TBD | Attempted illegal state transition |
| `ASX_E_REGION_NOT_OPEN` | TBD | Operation requires region in `Open` state |
| `ASX_E_REGION_CLOSED` | TBD | Operation on region that has reached `Closed` |
| `ASX_E_OBLIGATION_ALREADY_RESOLVED` | TBD | Attempt to resolve an already-resolved obligation |
| `ASX_E_OBLIGATION_LEAKED` | TBD | Obligation reached `Leaked` state |
| `ASX_E_UNRESOLVED_OBLIGATIONS` | TBD | Region finalization found unresolved obligations |
| `ASX_E_INCOMPLETE_CHILDREN` | TBD | Region finalization found non-terminal children |
| `ASX_E_STALE_HANDLE` | TBD | Handle generation mismatch (use-after-free defense) |
| `ASX_E_RESOURCE_EXHAUSTED` | TBD | Resource contract ceiling exceeded |
| `ASX_E_TASKS_STILL_ACTIVE` | TBD | Quiescence check failed: active tasks remain |
| `ASX_E_OBLIGATIONS_UNRESOLVED` | TBD | Quiescence check failed: obligations remain |
| `ASX_E_REGIONS_NOT_CLOSED` | TBD | Quiescence check failed: regions not closed |
| `ASX_E_TIMERS_PENDING` | TBD | Quiescence check failed: timers pending |
| `ASX_E_CHANNEL_NOT_DRAINED` | TBD | Quiescence check failed: channel not drained |

---

## Appendix B: State Encoding Reference

For the bitmasked generational typestate handles (`[ 16-bit type_tag | 16-bit state_mask | 32-bit arena_index ]`):

### B.1 Type Tags

| Type | Tag Value | Bit Pattern |
|------|----------|-------------|
| Region | `0x0001` | `0000 0000 0000 0001` |
| Task | `0x0002` | `0000 0000 0000 0010` |
| Obligation | `0x0003` | `0000 0000 0000 0011` |
| Cancel Witness | `0x0004` | `0000 0000 0000 0100` |
| Timer | `0x0005` | `0000 0000 0000 0101` |
| Channel | `0x0006` | `0000 0000 0000 0110` |

### B.2 State Masks (Region Example)

| State | Mask Value | Bit Pattern |
|-------|-----------|-------------|
| `Open` | `0x0001` | `0000 0000 0000 0001` |
| `Closing` | `0x0002` | `0000 0000 0000 0010` |
| `Draining` | `0x0004` | `0000 0000 0000 0100` |
| `Finalizing` | `0x0008` | `0000 0000 0000 1000` |
| `Closed` | `0x0010` | `0000 0000 0001 0000` |

API endpoints perform `handle.state_mask & expected_mask` for O(1) state validation.

---

*This document is the canonical reference for lifecycle transition semantics in the asx ANSI C port. All implementation must conform to these tables. Deviations require explicit approval and fixture additions.*
