/*
 * quiescence.c — close/finalize/quiescence driver (walking skeleton)
 *
 * Minimal implementation for bd-ix8.8: region drain and quiescence
 * assertion. Drives region through Close → Drain → Finalize → Closed.
 *
 * Phase 3 will add obligation tracking, finalizer chains, and leak
 * detection (bd-2cw.1). Semantics from QUIESCENCE_FINALIZATION_INVARIANTS.md.
 *
 * SPDX-License-Identifier: MIT
 */

#include <asx/asx.h>
#include <asx/runtime/runtime.h>
#include <asx/core/transition.h>
#include "runtime_internal.h"

/* -------------------------------------------------------------------
 * Quiescence check
 * ------------------------------------------------------------------- */

asx_status asx_quiescence_check(asx_region_id id)
{
    uint32_t idx;

    if (!asx_handle_is_valid(id)) return ASX_E_NOT_FOUND;
    idx = asx_handle_index(id);
    if (idx >= ASX_MAX_REGIONS) return ASX_E_NOT_FOUND;
    if (!g_regions[idx].alive) return ASX_E_NOT_FOUND;

    /* Quiescent iff region is CLOSED and no live tasks remain */
    if (g_regions[idx].state != ASX_REGION_CLOSED) {
        return ASX_E_QUIESCENCE_NOT_REACHED;
    }
    if (g_regions[idx].task_count > 0) {
        return ASX_E_QUIESCENCE_TASKS_LIVE;
    }

    return ASX_OK;
}

/* -------------------------------------------------------------------
 * Region drain: scheduler + close protocol
 *
 * Drives the region through its full shutdown sequence:
 *   1. Close (Open → Closing)
 *   2. Run scheduler to completion
 *   3. Drain (Closing → Draining → Finalizing → Closed)
 * ------------------------------------------------------------------- */

asx_status asx_region_drain(asx_region_id id, asx_budget *budget)
{
    uint32_t idx;
    asx_status st;

    if (budget == NULL) return ASX_E_INVALID_ARGUMENT;
    if (!asx_handle_is_valid(id)) return ASX_E_NOT_FOUND;
    idx = asx_handle_index(id);
    if (idx >= ASX_MAX_REGIONS) return ASX_E_NOT_FOUND;
    if (!g_regions[idx].alive) return ASX_E_NOT_FOUND;

    /* Step 1: Close the region if still open */
    if (g_regions[idx].state == ASX_REGION_OPEN) {
        st = asx_region_transition_check(ASX_REGION_OPEN, ASX_REGION_CLOSING);
        if (st != ASX_OK) return st;
        g_regions[idx].state = ASX_REGION_CLOSING;
    }

    /* Step 2: Run scheduler to drain tasks */
    if (g_regions[idx].task_count > 0) {
        st = asx_scheduler_run(id, budget);
        if (st != ASX_OK && st != ASX_E_POLL_BUDGET_EXHAUSTED) {
            return st;
        }
        if (g_regions[idx].task_count > 0) {
            return ASX_E_QUIESCENCE_TASKS_LIVE;
        }
    }

    /* Step 3: Advance through closing protocol */
    if (g_regions[idx].state == ASX_REGION_CLOSING) {
        /* No children (walking skeleton) → fast path: skip Draining */
        st = asx_region_transition_check(ASX_REGION_CLOSING,
                                         ASX_REGION_FINALIZING);
        if (st != ASX_OK) return st;
        g_regions[idx].state = ASX_REGION_FINALIZING;
    }

    if (g_regions[idx].state == ASX_REGION_DRAINING) {
        st = asx_region_transition_check(ASX_REGION_DRAINING,
                                         ASX_REGION_FINALIZING);
        if (st != ASX_OK) return st;
        g_regions[idx].state = ASX_REGION_FINALIZING;
    }

    if (g_regions[idx].state == ASX_REGION_FINALIZING) {
        st = asx_region_transition_check(ASX_REGION_FINALIZING,
                                         ASX_REGION_CLOSED);
        if (st != ASX_OK) return st;
        g_regions[idx].state = ASX_REGION_CLOSED;
    }

    return ASX_OK;
}
