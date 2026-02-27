#!/usr/bin/env bash
# robustness_fault.sh — e2e family for fault-injection boundaries (bd-1md.17)
#
# Exercises: clock anomalies (backward/overflow/zero), seeded entropy
# determinism, allocator failure paths, trace digest stability under
# faults, and region fault containment.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared harness
source "$SCRIPT_DIR/harness.sh"

# -------------------------------------------------------------------
# Init
# -------------------------------------------------------------------

e2e_init "robustness-fault" "E2E-ROBUST-FAULT"

# -------------------------------------------------------------------
# Build C test binary
# -------------------------------------------------------------------

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_robustness_fault"

if ! e2e_build "${SCRIPT_DIR}/e2e_robustness_fault.c" "$E2E_BIN"; then
    e2e_scenario "robustness_fault.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "robustness_fault.build" "" "pass"

# -------------------------------------------------------------------
# Run binary and parse scenario results
# -------------------------------------------------------------------

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/robustness_fault.stderr" "robustness_fault"
OUTPUT="$E2E_LAST_OUTPUT"

# -------------------------------------------------------------------
# Capture trace digest if emitted
# -------------------------------------------------------------------

DIGEST=""
if echo "$OUTPUT" | grep -q "^DIGEST "; then
    DIGEST="$(echo "$OUTPUT" | grep "^DIGEST " | tail -1 | cut -d' ' -f2)"
fi

if [ -n "$DIGEST" ]; then
    e2e_scenario "robustness_fault.trace_digest" "" "pass" "sha256:${DIGEST}"
fi

# -------------------------------------------------------------------
# Finish
# -------------------------------------------------------------------

set +e
e2e_finish
FINISH_RC=$?
set -e

exit $FINISH_RC
