/*
 * runtime/runtime.h — minimal walking-skeleton runtime API (bd-ix8.8)
 *
 * This header provides the initial public API for region/task lifecycle,
 * scheduling, and quiescence. The implementation is intentionally minimal
 * and explicitly non-final — it exists to prove layer wiring and provide
 * a baseline safety net for Phase 3 expansion.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef ASX_RUNTIME_H
#define ASX_RUNTIME_H

#include <asx/asx_export.h>
#include <asx/asx_status.h>
#include <asx/asx_ids.h>
#include <asx/core/outcome.h>
#include <asx/core/budget.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------
 * Arena capacity (walking skeleton: fixed-size static arenas)
 * Phase 3 will replace with dynamic hook-backed allocation.
 * ------------------------------------------------------------------- */

#define ASX_MAX_REGIONS      8
#define ASX_MAX_TASKS        64
#define ASX_MAX_OBLIGATIONS  128
#define ASX_REGION_CAPTURE_ARENA_BYTES 16384u

/* -------------------------------------------------------------------
 * Task poll function signature
 *
 * A task's poll function is called by the scheduler. It returns:
 *   ASX_OK         — task completed successfully
 *   ASX_E_PENDING  — task needs more polls (not yet ready)
 *   any error      — task failed
 * ------------------------------------------------------------------- */

typedef asx_status (*asx_task_poll_fn)(void *user_data, asx_task_id self);

/* Optional destructor for region-owned captured task state. */
typedef void (*asx_task_state_dtor_fn)(void *state, uint32_t state_size);

/* Coroutine resume token embedded in captured task state structs. */
typedef struct asx_co_state {
    uint32_t line;
} asx_co_state;

#define ASX_CO_STATE_INIT { 0u }

/* Protothread helpers:
 *  - ASX_CO_BEGIN must be paired with ASX_CO_END in the same function.
 *  - ASX_CO_YIELD returns ASX_E_PENDING and resumes at the next call.
 *  - State must live in region-owned captured task memory. */
#define ASX_CO_BEGIN(CO_STATE_PTR)                 \
    switch ((CO_STATE_PTR)->line) {                \
    case 0u:

#define ASX_CO_YIELD(CO_STATE_PTR)                 \
    do {                                           \
        (CO_STATE_PTR)->line = (uint32_t)__LINE__; \
        return ASX_E_PENDING;                      \
        case __LINE__:;                            \
    } while (0)

#define ASX_CO_END(CO_STATE_PTR)                   \
    }                                              \
    (CO_STATE_PTR)->line = 0u;                     \
    return ASX_OK

/* -------------------------------------------------------------------
 * Region lifecycle
 * ------------------------------------------------------------------- */

/* Open a new region. Returns ASX_OK and sets *out_id on success. */
ASX_API ASX_MUST_USE asx_status asx_region_open(asx_region_id *out_id);

/* Initiate region close. Transitions: Open → Closing. */
ASX_API ASX_MUST_USE asx_status asx_region_close(asx_region_id id);

/* Query the current state of a region. */
ASX_API ASX_MUST_USE asx_status asx_region_get_state(asx_region_id id,
                                                     asx_region_state *out_state);

/* -------------------------------------------------------------------
 * Region poison / containment
 *
 * When a region is poisoned, all mutating operations (spawn, close,
 * schedule) return ASX_E_REGION_POISONED. Read-only queries (get_state,
 * is_poisoned) remain available for diagnostics. Poisoning is
 * irreversible within a region lifetime — the region must be drained
 * or abandoned. This provides deterministic containment after
 * invariant violations without undefined behavior.
 * ------------------------------------------------------------------- */

/* Poison a region, preventing further mutating operations.
 * Returns ASX_OK on success or if already poisoned (idempotent). */
ASX_API ASX_MUST_USE asx_status asx_region_poison(asx_region_id id);

/* Query whether a region is poisoned. Sets *out to 1 if poisoned. */
ASX_API ASX_MUST_USE asx_status asx_region_is_poisoned(asx_region_id id,
                                                        int *out);

/* -------------------------------------------------------------------
 * Task lifecycle
 * ------------------------------------------------------------------- */

/* Spawn a task within a region. The poll_fn will be called by the
 * scheduler until it returns ASX_OK or an error. */
ASX_API ASX_MUST_USE asx_status asx_task_spawn(asx_region_id region,
                                               asx_task_poll_fn poll_fn,
                                               void *user_data,
                                               asx_task_id *out_id);

/* Spawn a task with captured state allocated from the region arena.
 * The returned state pointer is stable for the task lifetime and is
 * automatically passed as user_data to poll_fn. */
ASX_API ASX_MUST_USE asx_status asx_task_spawn_captured(asx_region_id region,
                                                        asx_task_poll_fn poll_fn,
                                                        uint32_t state_size,
                                                        asx_task_state_dtor_fn state_dtor,
                                                        asx_task_id *out_id,
                                                        void **out_state);

/* Query the current state of a task. */
ASX_API ASX_MUST_USE asx_status asx_task_get_state(asx_task_id id,
                                                   asx_task_state *out_state);

/* Query the outcome of a completed task. */
ASX_API ASX_MUST_USE asx_status asx_task_get_outcome(asx_task_id id,
                                                     asx_outcome *out_outcome);

/* -------------------------------------------------------------------
 * Obligation lifecycle
 * ------------------------------------------------------------------- */

/* Reserve an obligation within a region. The obligation starts in
 * the RESERVED state and must eventually be committed or aborted. */
ASX_API ASX_MUST_USE asx_status asx_obligation_reserve(asx_region_id region,
                                                        asx_obligation_id *out_id);

/* Commit a reserved obligation. Transitions: Reserved → Committed. */
ASX_API ASX_MUST_USE asx_status asx_obligation_commit(asx_obligation_id id);

/* Abort a reserved obligation. Transitions: Reserved → Aborted. */
ASX_API ASX_MUST_USE asx_status asx_obligation_abort(asx_obligation_id id);

/* Query the current state of an obligation. */
ASX_API ASX_MUST_USE asx_status asx_obligation_get_state(asx_obligation_id id,
                                                          asx_obligation_state *out_state);

/* -------------------------------------------------------------------
 * Scheduler
 * ------------------------------------------------------------------- */

/* Run the scheduler loop until all tasks in the region complete or
 * the budget is exhausted. Returns ASX_OK when quiescent. */
ASX_API ASX_MUST_USE asx_status asx_scheduler_run(asx_region_id region,
                                                  asx_budget *budget);

/* -------------------------------------------------------------------
 * Scheduler event sequencing (deterministic replay support)
 *
 * The scheduler emits a monotonically increasing sequence number for
 * each event (task poll, task completion, budget exhaustion). These
 * are deterministic for identical input and seed — suitable for
 * replay identity verification.
 *
 * Tie-break rule: tasks are polled in arena index order within a
 * round. Index order is stable and deterministic.
 * ------------------------------------------------------------------- */

typedef enum {
    ASX_SCHED_EVENT_POLL       = 0,  /* task polled */
    ASX_SCHED_EVENT_COMPLETE   = 1,  /* task completed (OK or error) */
    ASX_SCHED_EVENT_BUDGET     = 2,  /* budget exhausted */
    ASX_SCHED_EVENT_QUIESCENT  = 3   /* all tasks complete */
} asx_scheduler_event_kind;

typedef struct {
    asx_scheduler_event_kind kind;
    asx_task_id              task_id;   /* ASX_INVALID_ID for non-task events */
    uint32_t                 sequence;  /* monotonic per scheduler_run call */
    uint32_t                 round;     /* scheduler round (0-based) */
} asx_scheduler_event;

/* Read the total event count from the last scheduler_run call. */
ASX_API uint32_t asx_scheduler_event_count(void);

/* Read event at index (0-based). Returns 1 on success, 0 on out-of-bounds. */
ASX_API int asx_scheduler_event_get(uint32_t index, asx_scheduler_event *out);

/* Reset event log (called automatically by asx_scheduler_run). */
ASX_API void asx_scheduler_event_reset(void);

/* -------------------------------------------------------------------
 * Quiescence
 * ------------------------------------------------------------------- */

/* Check if a region has reached quiescence (all tasks completed,
 * region is CLOSED). Returns ASX_OK if quiescent. */
ASX_API ASX_MUST_USE asx_status asx_quiescence_check(asx_region_id id);

/* Drain a region: run scheduler then close through to CLOSED.
 * This is the high-level "shut down cleanly" operation. */
ASX_API ASX_MUST_USE asx_status asx_region_drain(asx_region_id id,
                                                 asx_budget *budget);

/* Reset all runtime state (test support only).
 * Clears all regions and tasks. Not for production use. */
ASX_API void asx_runtime_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* ASX_RUNTIME_H */
