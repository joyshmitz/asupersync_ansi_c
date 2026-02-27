#!/usr/bin/env bash
# continuity.sh — e2e family for crash/restart replay continuity (bd-1md.18)
#
# Exercises: binary trace export/import, replay verification,
# continuity check across simulated restarts, divergence detection,
# and digest stability.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ASX_E2E_POLICY_ID="${ASX_E2E_POLICY_ID:-CONT-CRASH-RESTART}"
source "$SCRIPT_DIR/harness.sh"

e2e_init "continuity" "E2E-VERT-CONTINUITY"

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_continuity"

if ! e2e_build "${SCRIPT_DIR}/e2e_continuity.c" "$E2E_BIN"; then
    e2e_scenario "continuity.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "continuity.build" "" "pass"

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/continuity.stderr" "continuity"
OUTPUT="$E2E_LAST_OUTPUT"

DIGEST=""
if echo "$OUTPUT" | grep -q "^DIGEST "; then
    DIGEST="$(echo "$OUTPUT" | grep "^DIGEST " | tail -1 | cut -d' ' -f2)"
fi
if [ -n "$DIGEST" ]; then
    e2e_scenario "continuity.trace_digest" "" "pass" "sha256:${DIGEST}"
fi

set +e
e2e_finish
FINISH_RC=$?
set -e
exit $FINISH_RC
