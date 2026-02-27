#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: run_compiler_matrix.sh [--run-id <id>] [--log-file <path>] [--dry-run]

Environment:
  REQUIRED_COMPILERS         Comma-separated required compiler keys (default: gcc,clang)
  ALLOW_MISSING_TOOLCHAINS   1 to downgrade missing required compilers to unsupported without failing
  FAIL_ON_LAYOUT_REGRESSION  1 to fail run when invariant layout deltas are flagged
  CC_GCC, CC_CLANG, CC_MSVC  Override compiler binaries
EOF
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit_jsonl() {
  local log_file="$1"
  local run_id="$2"
  local compiler_key="$3"
  local compiler_bin="$4"
  local bits="$5"
  local profile="$6"
  local endian="$7"
  local status="$8"
  local exit_code="$9"
  local diagnostic="${10}"
  local command="${11}"
  local output_path="${12}"
  local layout_report="${13:-}"
  local layout_status="${14:-not_run}"

  mkdir -p "$(dirname "$log_file")"
  printf '{"kind":"matrix-build","run_id":"%s","compiler":"%s","compiler_bin":"%s","bits":"%s","profile":"%s","endian":"%s","status":"%s","exit_code":%s,"diagnostic":"%s","command":"%s","output":"%s","layout_report":"%s","layout_status":"%s"}\n' \
    "$(json_escape "$run_id")" \
    "$(json_escape "$compiler_key")" \
    "$(json_escape "$compiler_bin")" \
    "$(json_escape "$bits")" \
    "$(json_escape "$profile")" \
    "$(json_escape "$endian")" \
    "$(json_escape "$status")" \
    "$exit_code" \
    "$(json_escape "$diagnostic")" \
    "$(json_escape "$command")" \
    "$(json_escape "$output_path")" \
    "$(json_escape "$layout_report")" \
    "$(json_escape "$layout_status")" >>"$log_file"
}

emit_delta_jsonl() {
  local log_file="$1"
  local run_id="$2"
  local status="$3"
  local exit_code="$4"
  local diagnostic="$5"
  local report_path="$6"
  local index_path="$7"

  mkdir -p "$(dirname "$log_file")"
  printf '{"kind":"matrix-layout-delta","run_id":"%s","status":"%s","exit_code":%s,"diagnostic":"%s","delta_report":"%s","index_path":"%s"}\n' \
    "$(json_escape "$run_id")" \
    "$(json_escape "$status")" \
    "$exit_code" \
    "$(json_escape "$diagnostic")" \
    "$(json_escape "$report_path")" \
    "$(json_escape "$index_path")" >>"$log_file"
}

is_required_compiler() {
  local key="$1"
  local normalized=",${REQUIRED_COMPILERS},"
  [[ "$normalized" == *",$key,"* ]]
}

resolve_compiler_bin() {
  local key="$1"
  case "$key" in
    gcc) printf '%s' "${CC_GCC:-gcc}" ;;
    clang) printf '%s' "${CC_CLANG:-clang}" ;;
    msvc) printf '%s' "${CC_MSVC:-cl}" ;;
    *)
      echo "unknown compiler key '$key'" >&2
      return 2
      ;;
  esac
}

supports_bitness() {
  local compiler_bin="$1"
  local bits="$2"

  if [[ "$bits" != "32" ]]; then
    return 0
  fi

  printf '#include <stdint.h>\nint main(void){return 0;}\n' | \
    "$compiler_bin" "-m${bits}" -std=c99 -x c -c -o /dev/null - >/dev/null 2>&1
}

run_id="matrix-$(date -u +%Y%m%dT%H%M%SZ)"
dry_run=0
artifact_root="${ARTIFACT_ROOT:-$SCRIPT_DIR/artifacts/build}"
log_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --log-file)
      log_file="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

REQUIRED_COMPILERS="${REQUIRED_COMPILERS:-gcc,clang}"
ALLOW_MISSING_TOOLCHAINS="${ALLOW_MISSING_TOOLCHAINS:-0}"
FAIL_ON_LAYOUT_REGRESSION="${FAIL_ON_LAYOUT_REGRESSION:-0}"

mkdir -p "$artifact_root"
if [[ -z "$log_file" ]]; then
  log_file="$artifact_root/${run_id}.jsonl"
fi
: >"$log_file"

layout_index_file="$artifact_root/${run_id}-layout-index.tsv"
: >"$layout_index_file"

declare -a MATRIX=(
  "gcc:64:CORE"
  "gcc:32:CORE"
  "clang:64:CORE"
  "clang:32:CORE"
  "gcc:64:EMBEDDED_ROUTER"
  "clang:64:FREESTANDING"
  "msvc:64:CORE"
)

total=0
failed=0
unsupported=0
planned=0

for entry in "${MATRIX[@]}"; do
  IFS=':' read -r compiler_key bits profile <<<"$entry"
  ((total += 1))

  compiler_bin="$(resolve_compiler_bin "$compiler_key")"
  target_id="${compiler_key}-${bits}-${profile}"
  output_log="$artifact_root/${run_id}-${target_id}.log"

  if ! command -v "$compiler_bin" >/dev/null 2>&1; then
    diagnostic="compiler '$compiler_bin' not found; install toolchain or set CC_${compiler_key^^}=<path>"
    emit_jsonl "$log_file" "$run_id" "$compiler_key" "$compiler_bin" "$bits" "$profile" "unknown" "unsupported" 127 \
      "$diagnostic" "n/a" "$output_log" "" "not_run"
    ((unsupported += 1))
    if is_required_compiler "$compiler_key" && [[ "$ALLOW_MISSING_TOOLCHAINS" != "1" ]]; then
      ((failed += 1))
    fi
    continue
  fi

  if [[ "$dry_run" == "1" ]]; then
    emit_jsonl "$log_file" "$run_id" "$compiler_key" "$compiler_bin" "$bits" "$profile" "unknown" "planned" 0 \
      "dry-run: build skipped" "make -C $REPO_ROOT build CC=$compiler_bin PROFILE=$profile BITS=$bits DETERMINISTIC=1 CODEC=JSON" "$output_log" "" "planned"
    ((planned += 1))
    continue
  fi

  if ! supports_bitness "$compiler_bin" "$bits"; then
    diagnostic="compiler '$compiler_bin' cannot build ${bits}-bit targets in this environment (missing multilib headers/libs)"
    emit_jsonl "$log_file" "$run_id" "$compiler_key" "$compiler_bin" "$bits" "$profile" "unknown" "unsupported" 127 \
      "$diagnostic" "n/a" "$output_log" "" "not_run"
    ((unsupported += 1))
    continue
  fi

  endian="unknown"
  endian_diag=""
  if endian="$("$SCRIPT_DIR/check_endian_assumptions.sh" \
      --compiler "$compiler_bin" \
      --bits "$bits" \
      --run-id "$run_id" \
      --target "$target_id" \
      --log-file "$log_file" 2>"$artifact_root/${run_id}-${target_id}.endian.err")"; then
    :
  else
    endian_diag="$(tr '\n' ' ' <"$artifact_root/${run_id}-${target_id}.endian.err" | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //;s/ $//')"
    if [[ -z "$endian_diag" ]]; then
      endian_diag="endian check failed"
    fi
    emit_jsonl "$log_file" "$run_id" "$compiler_key" "$compiler_bin" "$bits" "$profile" "unknown" "fail" 1 \
      "$endian_diag" "tools/ci/check_endian_assumptions.sh --compiler $compiler_bin --bits $bits" "$output_log" "" "not_run"
    ((failed += 1))
    continue
  fi

  layout_report=""
  layout_status="not_run"
  row_status="pass"
  row_exit_code=0
  row_diag="matrix build passed"

  make_cmd=(make -C "$REPO_ROOT" build "CC=$compiler_bin" "PROFILE=$profile" "BITS=$bits" "DETERMINISTIC=1" "CODEC=JSON")
  if "${make_cmd[@]}" >"$output_log" 2>&1; then
    if [[ "$compiler_key" == "msvc" ]]; then
      layout_status="unsupported"
    else
      layout_err_file="$artifact_root/${run_id}-${target_id}.layout.err"
      if layout_report="$("$SCRIPT_DIR/generate_layout_budget_report.sh" \
          --compiler "$compiler_bin" \
          --target-id "$target_id" \
          --profile "$profile" \
          --bits "$bits" \
          --run-id "$run_id" \
          --out-dir "$artifact_root" 2>"$layout_err_file")"; then
        layout_status="pass"
        printf '%s\t%s\n' "$target_id" "${layout_report%.json}.kv" >>"$layout_index_file"
      else
        layout_status="fail"
        row_status="fail"
        row_exit_code=1
        layout_diag="$(tr '\n' ' ' <"$layout_err_file" | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //;s/ $//')"
        if [[ -z "$layout_diag" ]]; then
          layout_diag="layout/budget report generation failed"
        fi
        row_diag="$layout_diag"
        ((failed += 1))
      fi
    fi
    emit_jsonl "$log_file" "$run_id" "$compiler_key" "$compiler_bin" "$bits" "$profile" "$endian" "$row_status" "$row_exit_code" \
      "$row_diag" "${make_cmd[*]}" "$output_log" "$layout_report" "$layout_status"
  else
    diagnostic="matrix build failed; inspect $output_log for compiler diagnostics"
    emit_jsonl "$log_file" "$run_id" "$compiler_key" "$compiler_bin" "$bits" "$profile" "$endian" "fail" 1 \
      "$diagnostic" "${make_cmd[*]}" "$output_log" "" "not_run"
    ((failed += 1))
  fi
done

delta_report="$artifact_root/${run_id}-layout-budget-delta.json"
delta_status="not_run"
delta_exit=0
delta_diag="layout/budget delta report skipped"

if [[ "$dry_run" == "1" ]]; then
  delta_status="planned"
  delta_diag="dry-run: delta report not computed"
elif [[ -s "$layout_index_file" ]]; then
  set +e
  "$SCRIPT_DIR/compute_layout_budget_delta.sh" \
    --run-id "$run_id" \
    --index-file "$layout_index_file" \
    --output "$delta_report"
  delta_rc=$?
  set -e
  case "$delta_rc" in
    0)
      delta_status="pass"
      delta_diag="layout/budget delta report generated"
      ;;
    3)
      delta_status="regression"
      delta_diag="invariant layout/budget regressions flagged (see delta report)"
      if [[ "$FAIL_ON_LAYOUT_REGRESSION" == "1" ]]; then
        ((failed += 1))
        delta_exit=1
      fi
      ;;
    *)
      delta_status="fail"
      delta_diag="failed to compute layout/budget delta report"
      delta_exit=1
      ((failed += 1))
      ;;
  esac
else
  delta_status="not_run"
  delta_diag="no layout reports were generated"
fi

emit_delta_jsonl "$log_file" "$run_id" "$delta_status" "$delta_exit" "$delta_diag" "$delta_report" "$layout_index_file"

echo "[asx-matrix] run_id=$run_id log_file=$log_file total=$total planned=$planned unsupported=$unsupported failed=$failed delta_status=$delta_status"
if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
