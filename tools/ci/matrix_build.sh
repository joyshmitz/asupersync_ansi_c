#!/bin/sh
# =============================================================================
# matrix_build.sh — compiler/platform matrix build driver (bd-ix8.3)
#
# Runs the asx build across available compiler/bitness/profile combinations.
# Produces deterministic, parseable log output (one line per target).
#
# Exit code: 0 if all required targets pass, nonzero otherwise.
# Optional targets that are skipped (missing toolchain) do not cause failure.
#
# Usage:
#   tools/ci/matrix_build.sh           # run full matrix
#   tools/ci/matrix_build.sh --quick   # gcc+clang 64-bit only
#
# Output format:
#   PASS|FAIL|SKIP  compiler  bits  profile  [reason]
#
# SPDX-License-Identifier: MIT
# =============================================================================

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_DIR="$PROJECT_ROOT/tools/ci/artifacts/build"
QUICK=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Parse args
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

mkdir -p "$ARTIFACT_DIR"

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

log_result() {
    status="$1"; compiler="$2"; bits="$3"; profile="$4"; reason="${5:-}"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf "%-4s  %-8s  %-4s  %-20s  %s  %s\n" \
        "$status" "$compiler" "$bits" "$profile" "$timestamp" "$reason"
    case "$status" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    esac
}

has_compiler() {
    command -v "$1" >/dev/null 2>&1
}

# Check if -m32 compilation is supported (with standard headers)
has_32bit_support() {
    compiler="$1"
    echo '#include <stdint.h>
int main(void){return 0;}' | "$compiler" -m32 -std=c99 -x c -c -o /dev/null - 2>/dev/null
}

# Run a single build configuration
run_build() {
    compiler="$1"
    bits="$2"
    profile="$3"

    if ! has_compiler "$compiler"; then
        log_result "SKIP" "$compiler" "$bits" "$profile" "compiler not found"
        return 0
    fi

    if [ "$bits" = "32" ] && ! has_32bit_support "$compiler"; then
        log_result "SKIP" "$compiler" "$bits" "$profile" "32-bit not supported"
        return 0
    fi

    logfile="$ARTIFACT_DIR/${compiler}_${bits}_${profile}.log"

    if make -C "$PROJECT_ROOT" clean build \
        CC="$compiler" \
        BITS="$bits" \
        PROFILE="$profile" \
        > "$logfile" 2>&1; then
        log_result "PASS" "$compiler" "$bits" "$profile"
    else
        log_result "FAIL" "$compiler" "$bits" "$profile" "see $logfile"
        return 1
    fi
}

# Run build + test for a configuration
run_build_and_test() {
    compiler="$1"
    bits="$2"
    profile="$3"

    if ! has_compiler "$compiler"; then
        log_result "SKIP" "$compiler" "$bits" "$profile" "compiler not found"
        return 0
    fi

    if [ "$bits" = "32" ] && ! has_32bit_support "$compiler"; then
        log_result "SKIP" "$compiler" "$bits" "$profile" "32-bit not supported"
        return 0
    fi

    logfile="$ARTIFACT_DIR/${compiler}_${bits}_${profile}.log"

    # Build-only for 32-bit (linking may require multilib)
    if [ "$bits" = "32" ]; then
        if make -C "$PROJECT_ROOT" clean build \
            CC="$compiler" \
            BITS="$bits" \
            PROFILE="$profile" \
            > "$logfile" 2>&1; then
            log_result "PASS" "$compiler" "$bits" "$profile" "compile-only"
        else
            log_result "FAIL" "$compiler" "$bits" "$profile" "see $logfile"
            return 1
        fi
    else
        if make -C "$PROJECT_ROOT" clean build test \
            CC="$compiler" \
            BITS="$bits" \
            PROFILE="$profile" \
            > "$logfile" 2>&1; then
            log_result "PASS" "$compiler" "$bits" "$profile"
        else
            log_result "FAIL" "$compiler" "$bits" "$profile" "see $logfile"
            return 1
        fi
    fi
}

# -----------------------------------------------------------------------
# Portability assumptions check (compile-time)
# -----------------------------------------------------------------------
run_portability_check() {
    compiler="$1"
    if ! has_compiler "$compiler"; then
        return 0
    fi

    logfile="$ARTIFACT_DIR/${compiler}_portability_check.log"
    if "$compiler" -std=c99 -Wall -Wextra -Werror \
        -I"$PROJECT_ROOT/include" \
        -DASX_PROFILE_CORE \
        -c -o /dev/null \
        "$PROJECT_ROOT/tools/ci/portability_check.c" \
        > "$logfile" 2>&1; then
        log_result "PASS" "$compiler" "64" "portability-check"
    else
        log_result "FAIL" "$compiler" "64" "portability-check" "see $logfile"
    fi
}

# -----------------------------------------------------------------------
# Matrix execution
# -----------------------------------------------------------------------

echo "================================================================"
echo "asx compiler/platform matrix build"
echo "================================================================"
echo ""
printf "%-4s  %-8s  %-4s  %-20s  %-20s  %s\n" \
    "STAT" "COMPILER" "BITS" "PROFILE" "TIMESTAMP" "NOTE"
echo "----  --------  ----  --------------------  --------------------  ----"

# Required matrix (failures are blocking)
MATRIX_FAILED=0

# GCC 64-bit (required)
run_build_and_test gcc 64 CORE || MATRIX_FAILED=1

# Clang 64-bit (required)
run_build_and_test clang 64 CORE || MATRIX_FAILED=1

if [ "$QUICK" -eq 0 ]; then
    # GCC 32-bit (optional — requires multilib)
    run_build gcc 32 CORE || true

    # Clang 32-bit (optional)
    run_build clang 32 CORE || true

    # Profile variants (64-bit gcc)
    for profile in FREESTANDING EMBEDDED_ROUTER; do
        run_build_and_test gcc 64 "$profile" || MATRIX_FAILED=1
    done

    # Profile variants (64-bit clang)
    for profile in FREESTANDING EMBEDDED_ROUTER; do
        run_build_and_test clang 64 "$profile" || MATRIX_FAILED=1
    done

    # MSVC (optional — only available on Windows)
    if has_compiler cl; then
        run_build cl 64 CORE || MATRIX_FAILED=1
    else
        log_result "SKIP" "msvc" "64" "CORE" "cl.exe not found"
    fi

    # Portability checks
    run_portability_check gcc
    run_portability_check clang
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Matrix summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
echo "Artifacts: $ARTIFACT_DIR/"
echo "================================================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "MATRIX RESULT: FAIL"
    exit 1
else
    echo "MATRIX RESULT: PASS"
    exit 0
fi
