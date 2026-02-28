#!/usr/bin/env bash
# =============================================================================
# check_semantic_delta_budget.sh — semantic delta budget gate (bd-66l.3)
#
# Enforces zero-delta-by-default policy for semantic behavior changes.
# Scans conformance, codec-equivalence, and profile-parity artifacts for
# regressions, and fails unless all deltas are approved via exception metadata.
#
# Artifact:
#   build/conformance/semantic_delta_budget_<run_id>.json
#
# Exit codes:
#   0: pass (zero deltas or all exceptions approved)
#   1: gate failure (unapproved semantic deltas)
#
# SPDX-License-Identifier: MIT
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_ID="${ASX_CI_RUN_TAG:-delta-budget-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="$REPO_ROOT/build/conformance"
ARTIFACT_FILE="$ARTIFACT_DIR/semantic_delta_budget_${RUN_ID}.json"
CONFORMANCE_DIR="$ARTIFACT_DIR"

mkdir -p "$ARTIFACT_DIR"

# ---------------------------------------------------------------------------
# Collect regression signals from conformance artifacts
# ---------------------------------------------------------------------------

delta_count=0
delta_sources=()

scan_conformance_artifacts() {
    local pattern="$1"
    local source_label="$2"

    for f in "$CONFORMANCE_DIR"/$pattern; do
        [ -f "$f" ] || continue

        # Look for c_regression or mismatch classifications
        local regressions
        regressions="$(jq -r '
            .. | objects |
            select(.delta_classification == "c_regression" or
                   .status == "mismatch" or
                   .codec_equiv_status == "mismatch" or
                   .profile_parity_status == "mismatch") |
            .delta_classification // .status // "mismatch"
        ' "$f" 2>/dev/null | wc -l || echo 0)"

        if [ "$regressions" -gt 0 ]; then
            delta_count=$((delta_count + regressions))
            delta_sources+=("$source_label:$f:$regressions")
        fi
    done
}

# Scan conformance artifacts
scan_conformance_artifacts "conformance_*.json" "conformance"
scan_conformance_artifacts "codec_equiv_*.json" "codec-equivalence"
scan_conformance_artifacts "profile_parity_*.json" "profile-parity"
scan_conformance_artifacts "adapter_iso_*.json" "adapter-isomorphism"

# ---------------------------------------------------------------------------
# Collect exception metadata from environment or commit message
# ---------------------------------------------------------------------------

exception_text=""
exception_source="none"

if [[ -n "${ASX_SEMANTIC_DELTA_EXCEPTION:-}" ]]; then
    exception_text="${ASX_SEMANTIC_DELTA_EXCEPTION}"
    exception_source="env"
elif [[ -n "${ASX_GUARANTEE_IMPACT_TEXT:-}" ]]; then
    exception_text="${ASX_GUARANTEE_IMPACT_TEXT}"
    exception_source="guarantee_impact_env"
else
    exception_text="$(git -C "$REPO_ROOT" log -1 --pretty=%B 2>/dev/null || true)"
    if [[ -n "$exception_text" ]]; then
        exception_source="commit_message"
    fi
fi

# Parse exception fields if deltas found
exception_id=""
exception_rationale=""
exception_approver=""
exception_valid=false

if [[ "$delta_count" -gt 0 && -n "$exception_text" ]]; then
    exception_id="$(printf '%s\n' "$exception_text" | command grep -Eio 'exception[[:space:]]+id:[[:space:]]*(.+)' | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)"
    exception_rationale="$(printf '%s\n' "$exception_text" | command grep -Eio 'exception[[:space:]]+rationale:[[:space:]]*(.+)' | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)"
    exception_approver="$(printf '%s\n' "$exception_text" | command grep -Eio 'exception[[:space:]]+approver:[[:space:]]*(.+)' | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)"

    if [[ -n "$exception_id" && -n "$exception_rationale" && -n "$exception_approver" ]]; then
        exception_valid=true
    fi
fi

# ---------------------------------------------------------------------------
# Determine pass/fail
# ---------------------------------------------------------------------------

if [[ "$delta_count" -eq 0 ]]; then
    status="pass"
    pass=true
    reason="zero semantic deltas detected — budget satisfied"
elif [[ "$exception_valid" == true ]]; then
    status="pass_with_exception"
    pass=true
    reason="$delta_count semantic delta(s) detected — approved via exception $exception_id"
else
    status="fail"
    pass=false
    reason="$delta_count unapproved semantic delta(s) detected — budget violated"
fi

# ---------------------------------------------------------------------------
# Build delta sources JSON
# ---------------------------------------------------------------------------

if [[ ${#delta_sources[@]} -eq 0 ]]; then
    sources_json='[]'
else
    sources_json="$(printf '%s\n' "${delta_sources[@]}" | jq -R . | jq -s .)"
fi

# ---------------------------------------------------------------------------
# Write artifact
# ---------------------------------------------------------------------------

jq -n \
  --arg kind "semantic_delta_budget" \
  --arg run_id "$RUN_ID" \
  --arg status "$status" \
  --argjson pass "$pass" \
  --arg reason "$reason" \
  --argjson delta_count "$delta_count" \
  --argjson delta_sources "$sources_json" \
  --arg exception_source "$exception_source" \
  --arg exception_id "${exception_id:-}" \
  --arg exception_rationale "${exception_rationale:-}" \
  --arg exception_approver "${exception_approver:-}" \
  --argjson exception_valid "$exception_valid" \
  --arg rerun "tools/ci/check_semantic_delta_budget.sh" \
  '{
    kind: $kind,
    run_id: $run_id,
    status: $status,
    pass: $pass,
    reason: $reason,
    budget: {
      expected: 0,
      actual: $delta_count,
      satisfied: $pass
    },
    delta_sources: $delta_sources,
    exception: {
      source: $exception_source,
      id: $exception_id,
      rationale: $exception_rationale,
      approver: $exception_approver,
      valid: $exception_valid
    },
    rerun: $rerun
  }' >"$ARTIFACT_FILE"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

echo "[asx] semantic-delta-budget: status=$status delta_count=$delta_count artifact=$ARTIFACT_FILE" >&2

if [[ "$pass" == true ]]; then
    echo "[asx] semantic-delta-budget: PASS" >&2
    exit 0
else
    echo "[asx] semantic-delta-budget: FAIL — $delta_count unapproved semantic delta(s)" >&2
    for src in "${delta_sources[@]}"; do
        echo "  delta: $src" >&2
    done
    echo "[asx] semantic-delta-budget: to approve, provide exception metadata:" >&2
    echo "  - exception id: EXC-NNNN" >&2
    echo "  - exception rationale: <reason for accepting non-zero delta>" >&2
    echo "  - exception approver: <name or agent id>" >&2
    exit 1
fi
