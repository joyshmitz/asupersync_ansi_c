#!/bin/sh
# check_api_docs.sh — lint gate for public API documentation coverage
#
# Validates that every ASX_API function in public headers has a preceding
# documentation comment. In --strict mode, also checks for error code
# mentions, precondition documentation, and thread-safety notes.
#
# Usage:
#   ./tools/ci/check_api_docs.sh [include_dir] [--strict]
#
# Exit codes:
#   0  All functions documented
#   1  Violations found
#
# SPDX-License-Identifier: MIT

set -e

INCLUDE_DIR="include/asx"
STRICT=0

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        -*) ;;
        *) INCLUDE_DIR="$arg" ;;
    esac
done

VIOLATIONS=0
WARNINGS=0
CHECKED=0

# Colors for terminal output (disabled if not a tty)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

log_pass() {
    printf "${GREEN}  PASS${NC}: %s\n" "$1"
}

log_fail() {
    printf "${RED}  FAIL${NC}: %s\n" "$1"
    VIOLATIONS=$((VIOLATIONS + 1))
}

log_warn() {
    printf "${YELLOW}  WARN${NC}: %s\n" "$1"
    WARNINGS=$((WARNINGS + 1))
}

# Collect the full comment block preceding a declaration.
# Walks backward from the line before the declaration until a line
# without a comment marker is found (or start of file).
get_doc_block() {
    _file="$1"
    _decl_line="$2"
    _end=$((_decl_line - 1))
    _start=$_end
    while [ "$_start" -ge 1 ]; do
        _line=$(sed -n "${_start}p" "$_file")
        case "$_line" in
            *'/*'*|*'*'*) _start=$((_start - 1)) ;;
            *) break ;;
        esac
    done
    _start=$((_start + 1))
    if [ "$_start" -gt "$_end" ]; then
        echo ""
    else
        sed -n "${_start},${_end}p" "$_file"
    fi
}

# Find all public header files
HEADERS=$(find "$INCLUDE_DIR" -name '*.h' -type f | sort)

for header in $HEADERS; do
    # Extract line numbers of ASX_API declarations (not inside comments)
    # Match lines with ASX_API that are actual function declarations:
    # exclude comments, preprocessor directives, and typedef lines
    LINE_NUMS=$(grep -n 'ASX_API' "$header" \
        | grep -v '/\*.*ASX_API' \
        | grep -v '^ *\*' \
        | grep -v '#' \
        | cut -d: -f1)

    for lineno in $LINE_NUMS; do
        # Get the function signature (first meaningful identifier after return type)
        FUNC_LINE=$(sed -n "${lineno}p" "$header")

        # Extract function name: look for asx_ identifier
        FUNC_NAME=$(echo "$FUNC_LINE" | grep -o 'asx_[a-z_]*' | head -1)
        if [ -z "$FUNC_NAME" ]; then
            NEXT_LINE=$((lineno + 1))
            FUNC_LINE2=$(sed -n "${NEXT_LINE}p" "$header")
            FUNC_NAME=$(echo "$FUNC_LINE2" | grep -o 'asx_[a-z_]*' | head -1)
            # Include the next line in signature for multi-line declarations
            FUNC_LINE="$FUNC_LINE $FUNC_LINE2"
        fi

        if [ -z "$FUNC_NAME" ]; then
            FUNC_NAME="(unknown at line $lineno)"
        fi

        CHECKED=$((CHECKED + 1))

        # Get the full doc block
        DOC_BLOCK=$(get_doc_block "$header" "$lineno")

        # --- Basic check: comment block exists ---
        if [ -z "$DOC_BLOCK" ]; then
            log_fail "$header:$lineno  $FUNC_NAME — missing documentation comment"
            continue
        fi

        # --- Strict checks (only when --strict) ---
        if [ "$STRICT" -eq 0 ]; then
            continue
        fi

        # Check if function RETURNS asx_status (not just uses it as param)
        # The return type appears between ASX_API and the function name
        RETURNS_STATUS=0
        RETURN_PART=$(echo "$FUNC_LINE" | sed 's/(.*//' | sed 's/ASX_MUST_USE//')
        if echo "$RETURN_PART" | grep -q 'asx_status'; then
            RETURNS_STATUS=1
        fi

        # Check if function has pointer parameters
        HAS_POINTER_PARAMS=0
        if echo "$FUNC_LINE" | grep -q '\*'; then
            HAS_POINTER_PARAMS=1
        fi

        # 1. asx_status-returning functions must mention error codes
        if [ "$RETURNS_STATUS" -eq 1 ]; then
            if ! echo "$DOC_BLOCK" | grep -qi 'ASX_E_\|ASX_OK\|Returns'; then
                log_fail "$header:$lineno  $FUNC_NAME — missing error code documentation (Returns/ASX_E_/ASX_OK)"
            fi
        fi

        # 2. Functions with pointer params should document preconditions
        if [ "$HAS_POINTER_PARAMS" -eq 1 ]; then
            if ! echo "$DOC_BLOCK" | grep -qi 'precondition\|must not be NULL\|must be.*valid\|not NULL'; then
                log_warn "$header:$lineno  $FUNC_NAME — missing precondition documentation for pointer params"
            fi
        fi

        # 3. Thread-safety should be mentioned
        if ! echo "$DOC_BLOCK" | grep -qi 'thread.safe\|thread-safe\|single.threaded\|Thread-safety'; then
            log_warn "$header:$lineno  $FUNC_NAME — missing thread-safety documentation"
        fi
    done
done

echo ""
echo "=== API Documentation Lint Summary ==="
echo "Headers scanned:   $(echo "$HEADERS" | wc -l | tr -d ' ')"
echo "Functions checked:  $CHECKED"
echo "Violations:         $VIOLATIONS"
if [ "$STRICT" -eq 1 ]; then
    echo "Warnings:           $WARNINGS"
    echo "Mode:               strict"
else
    echo "Mode:               basic"
fi

if [ "$VIOLATIONS" -gt 0 ]; then
    echo ""
    printf "${RED}FAILED${NC}: %d violation(s) found\n" "$VIOLATIONS"
    echo "See docs/API_DOCUMENTATION_CONTRACT.md for requirements."
    exit 1
else
    printf "${GREEN}PASSED${NC}: all %d functions pass documentation checks\n" "$CHECKED"
    if [ "$WARNINGS" -gt 0 ]; then
        printf "${YELLOW}NOTE${NC}: %d warning(s) — consider fixing before next release\n" "$WARNINGS"
    fi
    exit 0
fi
