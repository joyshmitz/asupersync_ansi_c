#!/usr/bin/env bash
# robustness.sh — e2e family for robustness boundary and fault-injection scenarios (bd-1md.17)
#
# Exercises: resource exhaustion, stale handle rejection, region poisoning,
# fault containment isolation, ghost violation recording, capture arena
# rollback, deterministic exhaustion, budget exhaustion.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared harness
source "$SCRIPT_DIR/harness.sh"

# -------------------------------------------------------------------
# Init
# -------------------------------------------------------------------

e2e_init "robustness" "E2E-ROBUSTNESS"

# -------------------------------------------------------------------
# Build C test binary
# -------------------------------------------------------------------

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_robustness"

if ! e2e_build "${SCRIPT_DIR}/e2e_robustness.c" "$E2E_BIN" "-DASX_DEBUG_GHOST"; then
    e2e_scenario "robustness.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "robustness.build" "" "pass"

# -------------------------------------------------------------------
# Run binary and parse scenario results
# -------------------------------------------------------------------

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/robustness.stderr" "robustness"

# -------------------------------------------------------------------
# Finish
# -------------------------------------------------------------------

set +e
e2e_finish
FINISH_RC=$?
set -e

exit $FINISH_RC
