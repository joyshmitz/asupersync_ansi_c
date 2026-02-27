#!/usr/bin/env bash
# continuity_restart.sh — e2e family for crash/restart replay continuity (bd-1md.18)
#
# Exercises: trace export/import round-trip, continuity check after
# restart simulation, mismatch detection, corrupted trace detection,
# and snapshot capture/digest determinism.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ASX_E2E_POLICY_ID="${ASX_E2E_POLICY_ID:-CONT-CRASH-RESTART}"
source "$SCRIPT_DIR/harness.sh"

e2e_init "continuity-restart" "E2E-CONT-RESTART"

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_continuity_restart"

if ! e2e_build "${SCRIPT_DIR}/e2e_continuity_restart.c" "$E2E_BIN"; then
    e2e_scenario "continuity_restart.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "continuity_restart.build" "" "pass"

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/continuity_restart.stderr" "continuity_restart"
OUTPUT="$E2E_LAST_OUTPUT"

DIGEST=""
if echo "$OUTPUT" | grep -q "^DIGEST "; then
    DIGEST="$(echo "$OUTPUT" | grep "^DIGEST " | tail -1 | cut -d' ' -f2)"
fi
if [ -n "$DIGEST" ]; then
    e2e_scenario "continuity_restart.trace_digest" "" "pass" "sha256:${DIGEST}"
fi

set +e
e2e_finish
FINISH_RC=$?
set -e
exit $FINISH_RC
