#!/usr/bin/env bash
# robustness_exhaustion.sh — e2e family for resource exhaustion boundaries (bd-1md.17)
#
# Exercises: arena/channel/timer/obligation capacity limits, budget
# exhaustion, failure-atomic rollback, and deterministic error codes.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared harness
source "$SCRIPT_DIR/harness.sh"

# -------------------------------------------------------------------
# Init
# -------------------------------------------------------------------

e2e_init "robustness-exhaustion" "E2E-ROBUST-EXHAUSTION"

# -------------------------------------------------------------------
# Build C test binary
# -------------------------------------------------------------------

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_robustness_exhaustion"

if ! e2e_build "${SCRIPT_DIR}/e2e_robustness_exhaustion.c" "$E2E_BIN"; then
    e2e_scenario "robustness_exhaustion.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "robustness_exhaustion.build" "" "pass"

# -------------------------------------------------------------------
# Run binary and parse scenario results
# -------------------------------------------------------------------

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/robustness_exhaustion.stderr" "robustness_exhaustion"

# -------------------------------------------------------------------
# Finish
# -------------------------------------------------------------------

set +e
e2e_finish
FINISH_RC=$?
set -e

exit $FINISH_RC
