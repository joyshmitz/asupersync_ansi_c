#!/usr/bin/env bash
# robustness_endian.sh — e2e family for endian/unaligned boundary safety (bd-1md.17)
#
# Exercises: LE/BE round-trip for u16/u32/u64, unaligned buffer access,
# endian canary validation, cross-format wire byte checks, and boundary
# edge cases.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared harness
source "$SCRIPT_DIR/harness.sh"

# -------------------------------------------------------------------
# Init
# -------------------------------------------------------------------

e2e_init "robustness-endian" "E2E-ROBUST-ENDIAN"

# -------------------------------------------------------------------
# Build C test binary
# -------------------------------------------------------------------

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_robustness_endian"

if ! e2e_build "${SCRIPT_DIR}/e2e_robustness_endian.c" "$E2E_BIN"; then
    e2e_scenario "robustness_endian.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "robustness_endian.build" "" "pass"

# -------------------------------------------------------------------
# Run binary and parse scenario results
# -------------------------------------------------------------------

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/robustness_endian.stderr" "robustness_endian"

# -------------------------------------------------------------------
# Finish
# -------------------------------------------------------------------

set +e
e2e_finish
FINISH_RC=$?
set -e

exit $FINISH_RC
