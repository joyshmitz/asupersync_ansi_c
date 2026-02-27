/*
 * lifecycle.c — region/task/obligation lifecycle engine (walking skeleton)
 *
 * Minimal implementation for bd-ix8.8: proves layer wiring between
 * handle packing, transition tables, and runtime API.
 *
 * Uses fixed-size static arenas. Phase 3 will replace with
 * hook-backed dynamic allocation (bd-hwb.3, bd-2cw.1).
 *
 * SPDX-License-Identifier: MIT
 */

#include <asx/asx.h>
#include <asx/runtime/runtime.h>
#include <asx/core/transition.h>
#include "runtime_internal.h"

/* -------------------------------------------------------------------
 * Global arenas (walking skeleton: fixed-size, no dynamic allocation)
 * ------------------------------------------------------------------- */

asx_region_slot g_regions[ASX_MAX_REGIONS];
uint32_t        g_region_count;

asx_task_slot   g_tasks[ASX_MAX_TASKS];
uint32_t        g_task_count;

/* -------------------------------------------------------------------
 * Reset (test support)
 * ------------------------------------------------------------------- */

void asx_runtime_reset(void)
{
    uint32_t i;
    for (i = 0; i < ASX_MAX_REGIONS; i++) {
        g_regions[i].state      = ASX_REGION_OPEN;
        g_regions[i].task_count = 0;
        g_regions[i].task_total = 0;
        g_regions[i].alive      = 0;
    }
    g_region_count = 0;
    for (i = 0; i < ASX_MAX_TASKS; i++) {
        g_tasks[i].state     = ASX_TASK_CREATED;
        g_tasks[i].region    = ASX_INVALID_ID;
        g_tasks[i].poll_fn   = NULL;
        g_tasks[i].user_data = NULL;
        g_tasks[i].outcome   = asx_outcome_make(ASX_OUTCOME_OK);
        g_tasks[i].alive     = 0;
    }
    g_task_count = 0;
}

/* -------------------------------------------------------------------
 * Internal helpers
 * ------------------------------------------------------------------- */

static asx_region_slot *region_lookup(asx_region_id id)
{
    uint16_t tag;
    uint32_t idx;

    if (!asx_handle_is_valid(id)) return NULL;
    tag = asx_handle_type_tag(id);
    if (tag != ASX_TYPE_REGION) return NULL;
    idx = asx_handle_index(id);
    if (idx >= ASX_MAX_REGIONS) return NULL;
    if (!g_regions[idx].alive) return NULL;
    return &g_regions[idx];
}

static asx_task_slot *task_lookup(asx_task_id id)
{
    uint16_t tag;
    uint32_t idx;

    if (!asx_handle_is_valid(id)) return NULL;
    tag = asx_handle_type_tag(id);
    if (tag != ASX_TYPE_TASK) return NULL;
    idx = asx_handle_index(id);
    if (idx >= ASX_MAX_TASKS) return NULL;
    if (!g_tasks[idx].alive) return NULL;
    return &g_tasks[idx];
}

/* -------------------------------------------------------------------
 * Region lifecycle
 * ------------------------------------------------------------------- */

asx_status asx_region_open(asx_region_id *out_id)
{
    uint32_t idx;

    if (out_id == NULL) return ASX_E_INVALID_ARGUMENT;
    if (g_region_count >= ASX_MAX_REGIONS) return ASX_E_RESOURCE_EXHAUSTED;

    idx = g_region_count++;
    g_regions[idx].state      = ASX_REGION_OPEN;
    g_regions[idx].task_count = 0;
    g_regions[idx].task_total = 0;
    g_regions[idx].alive      = 1;

    *out_id = asx_handle_pack(ASX_TYPE_REGION,
                              (uint16_t)(1u << (unsigned)ASX_REGION_OPEN),
                              idx);
    return ASX_OK;
}

asx_status asx_region_close(asx_region_id id)
{
    asx_region_slot *r = region_lookup(id);
    asx_status st;

    if (r == NULL) return ASX_E_NOT_FOUND;

    /* Transition Open → Closing */
    st = asx_region_transition_check(r->state, ASX_REGION_CLOSING);
    if (st != ASX_OK) return st;

    r->state = ASX_REGION_CLOSING;
    return ASX_OK;
}

asx_status asx_region_get_state(asx_region_id id,
                                asx_region_state *out_state)
{
    asx_region_slot *r;

    if (out_state == NULL) return ASX_E_INVALID_ARGUMENT;
    r = region_lookup(id);
    if (r == NULL) return ASX_E_NOT_FOUND;

    *out_state = r->state;
    return ASX_OK;
}

/* -------------------------------------------------------------------
 * Task lifecycle
 * ------------------------------------------------------------------- */

asx_status asx_task_spawn(asx_region_id region,
                          asx_task_poll_fn poll_fn,
                          void *user_data,
                          asx_task_id *out_id)
{
    asx_region_slot *r;
    uint32_t idx;

    if (out_id == NULL) return ASX_E_INVALID_ARGUMENT;
    if (poll_fn == NULL) return ASX_E_INVALID_ARGUMENT;

    r = region_lookup(region);
    if (r == NULL) return ASX_E_NOT_FOUND;

    /* Only open regions can spawn tasks */
    if (!asx_region_can_spawn(r->state)) return ASX_E_REGION_NOT_OPEN;

    if (g_task_count >= ASX_MAX_TASKS) return ASX_E_RESOURCE_EXHAUSTED;

    idx = g_task_count++;
    g_tasks[idx].state     = ASX_TASK_CREATED;
    g_tasks[idx].region    = region;
    g_tasks[idx].poll_fn   = poll_fn;
    g_tasks[idx].user_data = user_data;
    g_tasks[idx].outcome   = asx_outcome_make(ASX_OUTCOME_OK);
    g_tasks[idx].alive     = 1;

    r->task_count++;
    r->task_total++;

    *out_id = asx_handle_pack(ASX_TYPE_TASK,
                              (uint16_t)(1u << (unsigned)ASX_TASK_CREATED),
                              idx);
    return ASX_OK;
}

asx_status asx_task_get_state(asx_task_id id,
                              asx_task_state *out_state)
{
    asx_task_slot *t;

    if (out_state == NULL) return ASX_E_INVALID_ARGUMENT;
    t = task_lookup(id);
    if (t == NULL) return ASX_E_NOT_FOUND;

    *out_state = t->state;
    return ASX_OK;
}

asx_status asx_task_get_outcome(asx_task_id id,
                                asx_outcome *out_outcome)
{
    asx_task_slot *t;

    if (out_outcome == NULL) return ASX_E_INVALID_ARGUMENT;
    t = task_lookup(id);
    if (t == NULL) return ASX_E_NOT_FOUND;
    if (!asx_task_is_terminal(t->state)) return ASX_E_TASK_NOT_COMPLETED;

    *out_outcome = t->outcome;
    return ASX_OK;
}
