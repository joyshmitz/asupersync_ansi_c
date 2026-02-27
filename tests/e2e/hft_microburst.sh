#!/usr/bin/env bash
# hft_microburst.sh — e2e family for HFT microburst/overload scenarios (bd-1md.18)
#
# Exercises: capacity saturation, round-robin fairness, budget-bounded
# partial completion, mass cancel drain, and replay digest determinism.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ASX_E2E_PROFILE="${ASX_E2E_PROFILE:-HFT}"
export ASX_E2E_POLICY_ID="${ASX_E2E_POLICY_ID:-VERT-HFT-MICROBURST}"
source "$SCRIPT_DIR/harness.sh"

e2e_init "hft-microburst" "E2E-VERT-HFT"

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_hft_microburst"

if ! e2e_build "${SCRIPT_DIR}/e2e_hft_microburst.c" "$E2E_BIN"; then
    e2e_scenario "hft_microburst.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "hft_microburst.build" "" "pass"

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/hft_microburst.stderr" "hft_microburst"
OUTPUT="$E2E_LAST_OUTPUT"

DIGEST=""
if echo "$OUTPUT" | grep -q "^DIGEST "; then
    DIGEST="$(echo "$OUTPUT" | grep "^DIGEST " | tail -1 | cut -d' ' -f2)"
fi
if [ -n "$DIGEST" ]; then
    e2e_scenario "hft_microburst.trace_digest" "" "pass" "sha256:${DIGEST}"
fi

set +e
e2e_finish
FINISH_RC=$?
set -e
exit $FINISH_RC
