#!/usr/bin/env bash
# codec_parity.sh — e2e family for codec equivalence and parity scenarios (bd-1md.16)
#
# Exercises: JSON/BIN round-trip, cross-codec semantic equivalence,
# replay key identity, semantic key codec-agnosticism, and fixture validation.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared harness
source "$SCRIPT_DIR/harness.sh"

# -------------------------------------------------------------------
# Init
# -------------------------------------------------------------------

e2e_init "codec-parity" "E2E-CODEC-PARITY"

# -------------------------------------------------------------------
# Build C test binary
# -------------------------------------------------------------------

E2E_BIN="${E2E_ARTIFACT_DIR}/e2e_codec_parity"

if ! e2e_build "${SCRIPT_DIR}/e2e_codec_parity.c" "$E2E_BIN"; then
    e2e_scenario "codec_parity.build" "compilation failed" "fail"
    e2e_finish
    exit $?
fi
e2e_scenario "codec_parity.build" "" "pass"

# -------------------------------------------------------------------
# Run binary and parse scenario results
# -------------------------------------------------------------------

e2e_run_binary "$E2E_BIN" "${E2E_ARTIFACT_DIR}/codec_parity.stderr" "codec_parity"

# -------------------------------------------------------------------
# Finish
# -------------------------------------------------------------------

set +e
e2e_finish
FINISH_RC=$?
set -e

exit $FINISH_RC
