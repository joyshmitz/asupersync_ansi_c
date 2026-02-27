/*
 * outcome.c — outcome severity lattice implementation
 *
 * SPDX-License-Identifier: MIT
 */

#include <asx/core/outcome.h>

asx_outcome_severity asx_outcome_severity_of(const asx_outcome *o) {
    if (!o) return ASX_OUTCOME_OK;
    return o->severity;
}

asx_outcome asx_outcome_join(const asx_outcome *a, const asx_outcome *b) {
    asx_outcome result;
    if (!a && !b) {
        result.severity = ASX_OUTCOME_OK;
    } else if (!a) {
        result = *b;
    } else if (!b) {
        result = *a;
    } else if (a->severity >= b->severity) {
        result = *a; /* left-bias on equal severity */
    } else {
        result = *b;
    }
    return result;
}
