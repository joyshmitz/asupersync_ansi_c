#!/usr/bin/env bash
set -euo pipefail

# run_smoke.sh — CI smoke runner for differential fuzz harness (bd-1md.3)
#
# Usage:
#   tools/fuzz/run_smoke.sh              # smoke mode (100 iterations)
#   tools/fuzz/run_smoke.sh --nightly    # nightly mode (100000 iterations)
#
# Environment:
#   FUZZ_SEED=<u64>         Override initial seed (default: timestamp-derived)
#   FUZZ_ITERATIONS=<n>     Override iteration count
#   FUZZ_REPORT_DIR=<dir>   Report output directory (default: tools/ci/artifacts/fuzz)
#
# SPDX-License-Identifier: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE="smoke"
if [[ "${1:-}" == "--nightly" ]]; then
    MODE="nightly"
fi

# Defaults per mode
if [[ "$MODE" == "nightly" ]]; then
    DEFAULT_ITERATIONS=100000
    DEFAULT_MAX_OPS=96
    DEFAULT_MUTATIONS=8
    FUZZ_FLAGS="--verbose"
else
    DEFAULT_ITERATIONS=100
    DEFAULT_MAX_OPS=32
    DEFAULT_MUTATIONS=4
    FUZZ_FLAGS=""
fi

ITERATIONS="${FUZZ_ITERATIONS:-$DEFAULT_ITERATIONS}"
SEED="${FUZZ_SEED:-$(date +%s)}"
REPORT_DIR="${FUZZ_REPORT_DIR:-$REPO_ROOT/tools/ci/artifacts/fuzz}"
RUN_ID="fuzz-${MODE}-$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$REPORT_DIR"

REPORT_FILE="$REPORT_DIR/${RUN_ID}.jsonl"
SUMMARY_FILE="$REPORT_DIR/${RUN_ID}.summary.json"

echo "[asx] fuzz[$MODE]: building harness..." >&2

if ! make -C "$REPO_ROOT" fuzz-build >"$REPORT_DIR/${RUN_ID}.build.log" 2>&1; then
    echo "[asx] fuzz[$MODE]: FAIL (build failed; inspect $REPORT_DIR/${RUN_ID}.build.log)" >&2
    exit 1
fi

FUZZ_BIN="$REPO_ROOT/build/fuzz/fuzz_differential"

echo "[asx] fuzz[$MODE]: running (seed=$SEED iterations=$ITERATIONS)..." >&2

set +e
"$FUZZ_BIN" \
    --seed "$SEED" \
    --iterations "$ITERATIONS" \
    --max-ops "$DEFAULT_MAX_OPS" \
    --mutations "$DEFAULT_MUTATIONS" \
    --report "$REPORT_FILE" \
    $FUZZ_FLAGS
fuzz_rc=$?
set -e

# Extract summary from JSONL report
if command -v jq >/dev/null 2>&1 && [[ -f "$REPORT_FILE" ]]; then
    jq -s '
        . as $records |
        ($records | map(select(.kind == "summary")) | first // {}) as $summary |
        ($records | map(select(.kind != "summary")) | length) as $mismatch_count |
        $summary + {
            mode: "'"$MODE"'",
            run_id: "'"$RUN_ID"'",
            report_file: "'"$REPORT_FILE"'",
            mismatch_count: $mismatch_count
        }
    ' "$REPORT_FILE" > "$SUMMARY_FILE"
else
    echo "{\"run_id\":\"$RUN_ID\",\"mode\":\"$MODE\",\"exit_code\":$fuzz_rc}" > "$SUMMARY_FILE"
fi

echo "[asx] fuzz[$MODE]: report=$REPORT_FILE summary=$SUMMARY_FILE" >&2

if [[ "$fuzz_rc" -ne 0 ]]; then
    echo "[asx] fuzz[$MODE]: FAIL (exit code $fuzz_rc)" >&2
    exit 1
fi

echo "[asx] fuzz[$MODE]: PASS" >&2
exit 0
