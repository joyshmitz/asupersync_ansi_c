#!/usr/bin/env bash
# =============================================================================
# check_proof_block_gate.sh — Anti-butchering proof-block gate (bd-66l.7)
#
# Enforces a machine-checkable "Guarantee Impact" metadata block for
# semantic-sensitive changes (kernel/runtime semantics surfaces).
#
# Sources scanned for Guarantee Impact metadata:
#   1) PR body (when running in GitHub Actions pull_request context)
#   2) Commit messages in evaluated diff range
#   3) Optional file via --text-file / ASX_GUARANTEE_IMPACT_FILE
#   4) Optional text via ASX_GUARANTEE_IMPACT_TEXT
#
# Exit codes:
#   0 = pass (or no semantic-sensitive changes)
#   1 = gate violation
#   2 = usage/config/runtime error
#
# SPDX-License-Identifier: MIT
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ARTIFACT_DIR="$REPO_ROOT/build/conformance"
TIMESTAMP_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_FILE="$ARTIFACT_DIR/anti_butcher_${TIMESTAMP_UTC}.json"

STRICT="${ASX_PROOF_BLOCK_STRICT:-${CI:-0}}"
VERBOSE=0
JSON_STDOUT=0
EXTRA_TEXT_FILE="${ASX_GUARANTEE_IMPACT_FILE:-}"

SENSITIVE_GLOBS=(
    "src/core/*"
    "src/runtime/*"
    "src/channel/*"
    "src/time/*"
    "include/asx/*"
    "include/asx/runtime/*"
)

REQUIRED_FIELDS=(
    "gs_id"
    "change"
    "preserved invariants"
    "proof artifacts"
    "fallback mode"
    "deterministic isomorphism note"
    "semantic delta budget"
    "traceability refs"
    "artifact links"
)

usage() {
    cat <<'USAGE'
Usage: check_proof_block_gate.sh [options]

Options:
  --strict              Enforce failures even outside CI
  --json                Print final JSON report to stdout
  --text-file <path>    Extra text source containing Guarantee Impact block
  -h, --help            Show this help

Environment:
  CI=1                               Enables strict mode by default
  ASX_PROOF_BLOCK_STRICT=1|0         Override strict behavior
  ASX_GUARANTEE_IMPACT_FILE=<path>   Extra text source file
  ASX_GUARANTEE_IMPACT_TEXT=<text>   Extra text source payload
  ASX_PROOF_BLOCK_BASE=<rev>         Explicit diff base
  ASX_PROOF_BLOCK_HEAD=<rev>         Explicit diff head
USAGE
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) STRICT=1; shift ;;
        --json) JSON_STDOUT=1; shift ;;
        --text-file)
            [[ $# -ge 2 ]] || usage
            EXTRA_TEXT_FILE="$2"
            shift 2
            ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g'
}

emit_json_array() {
    local -n arr_ref=$1
    local i
    printf '['
    for ((i = 0; i < ${#arr_ref[@]}; i++)); do
        if [[ $i -gt 0 ]]; then
            printf ','
        fi
        printf '"%s"' "$(json_escape "${arr_ref[$i]}")"
    done
    printf ']'
}

is_sensitive_path() {
    local p="$1"
    local g
    for g in "${SENSITIVE_GLOBS[@]}"; do
        if [[ "$p" == $g ]]; then
            return 0
        fi
    done
    return 1
}

detect_range() {
    local base="${ASX_PROOF_BLOCK_BASE:-}"
    local head="${ASX_PROOF_BLOCK_HEAD:-}"

    if [[ -n "$base" && -n "$head" ]]; then
        printf '%s %s\n' "$base" "$head"
        return 0
    fi

    if [[ -n "${GITHUB_EVENT_PATH:-}" ]] && command -v jq >/dev/null 2>&1; then
        local event_name
        event_name="$(jq -r '.action? // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
        if jq -e '.pull_request' "$GITHUB_EVENT_PATH" >/dev/null 2>&1; then
            base="$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")"
            head="$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")"
            if [[ -n "$base" && -n "$head" ]]; then
                printf '%s %s\n' "$base" "$head"
                return 0
            fi
        fi
        if [[ -n "$event_name" && $VERBOSE -eq 1 ]]; then
            echo "[asx] proof-block: event action=${event_name}" >&2
        fi
    fi

    if git -C "$REPO_ROOT" rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        printf 'HEAD~1 HEAD\n'
        return 0
    fi

    printf ' \n'
}

collect_changed_files() {
    local base="$1"
    local head="$2"
    local files=()

    if [[ -n "$base" && -n "$head" ]]; then
        if ! git -C "$REPO_ROOT" cat-file -e "$base^{commit}" >/dev/null 2>&1; then
            git -C "$REPO_ROOT" fetch --no-tags --depth=1 origin "$base" >/dev/null 2>&1 || true
        fi
        if ! git -C "$REPO_ROOT" cat-file -e "$head^{commit}" >/dev/null 2>&1; then
            git -C "$REPO_ROOT" fetch --no-tags --depth=1 origin "$head" >/dev/null 2>&1 || true
        fi
        if git -C "$REPO_ROOT" cat-file -e "$base^{commit}" >/dev/null 2>&1 &&
           git -C "$REPO_ROOT" cat-file -e "$head^{commit}" >/dev/null 2>&1; then
            while IFS= read -r f; do
                [[ -n "$f" ]] && files+=("$f")
            done < <(git -C "$REPO_ROOT" diff --name-only "$base" "$head")
        fi
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && files+=("$f")
        done < <(git -C "$REPO_ROOT" diff --name-only)
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && files+=("$f")
        done < <(git -C "$REPO_ROOT" diff --name-only --cached)
    fi

    printf '%s\n' "${files[@]}" | awk 'NF { print }' | sort -u
}

extract_field_value() {
    local key="$1"
    local text="$2"
    local line
    line="$(printf '%s\n' "$text" | grep -Eim1 "^[[:space:]]*-[[:space:]]*${key}:[[:space:]]*.+$" || true)"
    if [[ -z "$line" ]]; then
        printf ''
        return 0
    fi
    printf '%s' "$line" | sed -E "s/^[[:space:]]*-[[:space:]]*${key}:[[:space:]]*//I"
}

mkdir -p "$ARTIFACT_DIR"

read -r RANGE_BASE RANGE_HEAD < <(detect_range)

mapfile -t CHANGED_FILES < <(collect_changed_files "$RANGE_BASE" "$RANGE_HEAD")
SENSITIVE_FILES=()
for f in "${CHANGED_FILES[@]}"; do
    if is_sensitive_path "$f"; then
        SENSITIVE_FILES+=("$f")
    fi
done

if [[ ${#SENSITIVE_FILES[@]} -eq 0 ]]; then
    cat > "$REPORT_FILE" <<EOF
{
  "gate": "anti-butchering-proof-block",
  "pass": true,
  "required": false,
  "strict": $([[ "$STRICT" = "1" ]] && echo true || echo false),
  "reason": "no semantic-sensitive files changed",
  "traceability_index": "docs/PLAN_EXECUTION_TRACEABILITY_INDEX.md",
  "changed_files": $(emit_json_array CHANGED_FILES),
  "sensitive_files": [],
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    if [[ $JSON_STDOUT -eq 1 ]]; then
        cat "$REPORT_FILE"
    elif [[ $VERBOSE -eq 1 ]]; then
        echo "[asx] proof-block: PASS (no semantic-sensitive changes)"
    fi
    exit 0
fi

METADATA_TEXT=""

if [[ -n "${EXTRA_TEXT_FILE}" && -f "${EXTRA_TEXT_FILE}" ]]; then
    METADATA_TEXT+=$'\n'
    METADATA_TEXT+="$(cat "${EXTRA_TEXT_FILE}")"
fi

if [[ -n "${ASX_GUARANTEE_IMPACT_TEXT:-}" ]]; then
    METADATA_TEXT+=$'\n'
    METADATA_TEXT+="${ASX_GUARANTEE_IMPACT_TEXT}"
fi

if [[ -n "${GITHUB_EVENT_PATH:-}" ]] && [[ -f "${GITHUB_EVENT_PATH}" ]] && command -v jq >/dev/null 2>&1; then
    if jq -e '.pull_request' "$GITHUB_EVENT_PATH" >/dev/null 2>&1; then
        PR_BODY="$(jq -r '.pull_request.body // empty' "$GITHUB_EVENT_PATH")"
        if [[ -n "$PR_BODY" ]]; then
            METADATA_TEXT+=$'\n'
            METADATA_TEXT+="$PR_BODY"
        fi
    fi
fi

if [[ -n "$RANGE_BASE" && -n "$RANGE_HEAD" ]]; then
    LOG_TEXT="$(git -C "$REPO_ROOT" log --format=%B "${RANGE_BASE}..${RANGE_HEAD}" 2>/dev/null || true)"
else
    LOG_TEXT="$(git -C "$REPO_ROOT" log -1 --format=%B 2>/dev/null || true)"
fi
if [[ -n "$LOG_TEXT" ]]; then
    METADATA_TEXT+=$'\n'
    METADATA_TEXT+="$LOG_TEXT"
fi

LOWER_TEXT="$(printf '%s\n' "$METADATA_TEXT" | tr '[:upper:]' '[:lower:]')"

MISSING_FIELDS=()
for field in "${REQUIRED_FIELDS[@]}"; do
    if ! printf '%s\n' "$LOWER_TEXT" | grep -Eqi "^[[:space:]]*-[[:space:]]*${field}:[[:space:]]*.+$"; then
        MISSING_FIELDS+=("$field")
    fi
done

GS_ID_VAL="$(extract_field_value "gs_id" "$METADATA_TEXT")"
CHANGE_VAL="$(extract_field_value "change" "$METADATA_TEXT")"
INV_VAL="$(extract_field_value "preserved invariants" "$METADATA_TEXT")"
ARTIFACT_VAL="$(extract_field_value "proof artifacts" "$METADATA_TEXT")"
FALLBACK_VAL="$(extract_field_value "fallback mode" "$METADATA_TEXT")"
ISO_VAL="$(extract_field_value "deterministic isomorphism note" "$METADATA_TEXT")"
DELTA_VAL="$(extract_field_value "semantic delta budget" "$METADATA_TEXT")"
TRACE_VAL="$(extract_field_value "traceability refs" "$METADATA_TEXT")"
ARTIFACT_LINKS_VAL="$(extract_field_value "artifact links" "$METADATA_TEXT")"
EXCEPTION_ID_VAL="$(extract_field_value "exception id" "$METADATA_TEXT")"
EXCEPTION_REASON_VAL="$(extract_field_value "exception rationale" "$METADATA_TEXT")"
EXCEPTION_APPROVER_VAL="$(extract_field_value "exception approver" "$METADATA_TEXT")"

VALIDATION_ERRORS=()

if [[ -z "$GS_ID_VAL" || ! "$GS_ID_VAL" =~ GS-[0-9]{3} ]]; then
    VALIDATION_ERRORS+=("gs_id must include at least one GS-### identifier")
fi

if [[ -z "$ARTIFACT_VAL" || ! "$ARTIFACT_VAL" =~ (tests/|tools/|docs/|build/) ]]; then
    VALIDATION_ERRORS+=("proof artifacts must include repo artifact/test/doc path references")
fi

if [[ -z "$TRACE_VAL" || ! "$TRACE_VAL" =~ (TRC-|TG-|PLAN_EXECUTION_TRACEABILITY_INDEX\.md) ]]; then
    VALIDATION_ERRORS+=("traceability refs must include TRC-/TG- ids or PLAN_EXECUTION_TRACEABILITY_INDEX reference")
fi

if [[ -z "$ARTIFACT_LINKS_VAL" || ! "$ARTIFACT_LINKS_VAL" =~ (build/|tools/|docs/|tests/) ]]; then
    VALIDATION_ERRORS+=("artifact links must include concrete repo-relative evidence paths")
fi

DELTA_NORMALIZED="$(printf '%s' "$DELTA_VAL" | tr -d '[:space:]')"
if [[ -n "$DELTA_NORMALIZED" && "$DELTA_NORMALIZED" != "0" && "$DELTA_NORMALIZED" != "0.0" ]]; then
    if [[ -z "$EXCEPTION_ID_VAL" ]]; then
        VALIDATION_ERRORS+=("non-zero semantic delta budget requires 'exception id'")
    fi
    if [[ -z "$EXCEPTION_REASON_VAL" ]]; then
        VALIDATION_ERRORS+=("non-zero semantic delta budget requires 'exception rationale'")
    fi
    if [[ -z "$EXCEPTION_APPROVER_VAL" ]]; then
        VALIDATION_ERRORS+=("non-zero semantic delta budget requires 'exception approver'")
    fi
    if [[ -n "$EXCEPTION_ID_VAL" ]]; then
        if ! grep -Fq "$EXCEPTION_ID_VAL" "$REPO_ROOT/docs/OPEN_DECISIONS_ADR.md" &&
           ! grep -Fq "$EXCEPTION_ID_VAL" "$REPO_ROOT/docs/OWNER_DECISION_LOG.md"; then
            VALIDATION_ERRORS+=("exception id '$EXCEPTION_ID_VAL' not found in ADR/decision log")
        fi
    fi
fi

PASS=true
if [[ ${#MISSING_FIELDS[@]} -gt 0 || ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
    PASS=false
fi

if [[ "$PASS" = "false" && "$STRICT" != "1" ]]; then
    # Non-strict mode reports issue but does not fail local developer workflows.
    PASS=true
fi

cat > "$REPORT_FILE" <<EOF
{
  "gate": "anti-butchering-proof-block",
  "pass": $([[ "$PASS" = "true" ]] && echo true || echo false),
  "required": true,
  "strict": $([[ "$STRICT" = "1" ]] && echo true || echo false),
  "traceability_index": "docs/PLAN_EXECUTION_TRACEABILITY_INDEX.md",
  "diff_range": {
    "base": "$(json_escape "$RANGE_BASE")",
    "head": "$(json_escape "$RANGE_HEAD")"
  },
  "changed_files": $(emit_json_array CHANGED_FILES),
  "sensitive_files": $(emit_json_array SENSITIVE_FILES),
  "missing_fields": $(emit_json_array MISSING_FIELDS),
  "validation_errors": $(emit_json_array VALIDATION_ERRORS),
  "parsed": {
    "gs_id": "$(json_escape "$GS_ID_VAL")",
    "change": "$(json_escape "$CHANGE_VAL")",
    "preserved_invariants": "$(json_escape "$INV_VAL")",
    "proof_artifacts": "$(json_escape "$ARTIFACT_VAL")",
    "fallback_mode": "$(json_escape "$FALLBACK_VAL")",
    "deterministic_isomorphism_note": "$(json_escape "$ISO_VAL")",
    "semantic_delta_budget": "$(json_escape "$DELTA_VAL")",
    "traceability_refs": "$(json_escape "$TRACE_VAL")",
    "artifact_links": "$(json_escape "$ARTIFACT_LINKS_VAL")",
    "exception_id": "$(json_escape "$EXCEPTION_ID_VAL")",
    "exception_rationale": "$(json_escape "$EXCEPTION_REASON_VAL")",
    "exception_approver": "$(json_escape "$EXCEPTION_APPROVER_VAL")"
  },
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

if [[ $JSON_STDOUT -eq 1 ]]; then
    cat "$REPORT_FILE"
fi

if [[ "$PASS" = "true" ]]; then
    if [[ $JSON_STDOUT -eq 0 ]]; then
        echo "[asx] proof-block: PASS"
        echo "[asx] proof-block: report=${REPORT_FILE}"
    fi
    exit 0
fi

if [[ $JSON_STDOUT -eq 0 ]]; then
    echo "[asx] proof-block: FAIL" >&2
    if [[ ${#MISSING_FIELDS[@]} -gt 0 ]]; then
        echo "  missing fields: ${MISSING_FIELDS[*]}" >&2
    fi
    if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
        local_idx=0
        while [[ $local_idx -lt ${#VALIDATION_ERRORS[@]} ]]; do
            echo "  validation: ${VALIDATION_ERRORS[$local_idx]}" >&2
            local_idx=$((local_idx + 1))
        done
    fi
    echo "  report: ${REPORT_FILE}" >&2
fi

exit 1
