#!/usr/bin/env bash
# core_lifecycle.sh — e2e family for core runtime lifecycle scenarios (bd-1md.16)
#
# Exercises: region/task/obligation lifecycle, cancellation propagation,
# quiescence close paths, timer wheel, bounded MPSC channel, and
# deterministic trace digest.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared harness
source "$SCRIPT_DIR/harness.sh"

# -------------------------------------------------------------------
# Init
# -------------------------------------------------------------------

e2e_init "core-lifecycle" "E2E-CORE-LIFECYCLE"

# -------------------------------------------------------------------
# Build C test binary
# -------------------------------------------------------------------

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_core_lifecycle"

if ! e2e_build "${SCRIPT_DIR}/e2e_core_lifecycle.c" "$E2E_BIN"; then
    e2e_scenario "core_lifecycle.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "core_lifecycle.build" "" "pass"

# -------------------------------------------------------------------
# Run binary and parse scenario results
# -------------------------------------------------------------------

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/core_lifecycle.stderr" "core_lifecycle"
OUTPUT="$E2E_LAST_OUTPUT"

# -------------------------------------------------------------------
# Compute trace digest from the final run for manifest
# -------------------------------------------------------------------

# If the binary produced a digest line, record it
DIGEST=""
if echo "$OUTPUT" | grep -q "^DIGEST "; then
    DIGEST="$(echo "$OUTPUT" | grep "^DIGEST " | tail -1 | cut -d' ' -f2)"
fi

if [ -n "$DIGEST" ]; then
    e2e_scenario "core_lifecycle.trace_digest" "" "pass" "sha256:${DIGEST}"
fi

# -------------------------------------------------------------------
# Finish
# -------------------------------------------------------------------

set +e
e2e_finish
FINISH_RC=$?
set -e

exit $FINISH_RC
