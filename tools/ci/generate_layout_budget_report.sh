#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: generate_layout_budget_report.sh
  --compiler <compiler>
  --target-id <id>
  --profile <CORE|POSIX|WIN32|FREESTANDING|EMBEDDED_ROUTER|HFT|AUTOMOTIVE>
  --out-dir <dir>
  [--bits <32|64>]
  [--resource-class <R1|R2|R3|none>]
  [--run-id <id>]
  [--extra-cflags "<flags>"]

Generates deterministic compile-time memory-layout and budget reports:
  - <out-dir>/<run-id>-<target-id>-layout-budget.kv
  - <out-dir>/<run-id>-<target-id>-layout-budget.json

Prints the JSON report path on stdout on success.
EOF
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

to_decimal() {
  local raw="$1"
  if [[ "$raw" =~ ^-?[0-9]+$ || "$raw" =~ ^-?0[xX][0-9a-fA-F]+$ ]]; then
    printf '%d' "$((raw))"
    return 0
  fi
  return 1
}

compiler=""
target_id=""
profile="CORE"
out_dir=""
bits=""
resource_class="none"
run_id="layout-$(date -u +%Y%m%dT%H%M%SZ)"
extra_cflags=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compiler)
      compiler="$2"
      shift 2
      ;;
    --target-id)
      target_id="$2"
      shift 2
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --bits)
      bits="$2"
      shift 2
      ;;
    --resource-class)
      resource_class="$2"
      shift 2
      ;;
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --extra-cflags)
      extra_cflags="$2"
      shift 2
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

if [[ -z "$compiler" || -z "$target_id" || -z "$out_dir" ]]; then
  echo "Missing required arguments" >&2
  usage >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

mkdir -p "$out_dir"

safe_target="${target_id//\//_}"
stem="${run_id}-${safe_target}-layout-budget"
asm_path="$out_dir/${stem}.s"
log_path="$out_dir/${stem}.log"
kv_path="$out_dir/${stem}.kv"
json_path="$out_dir/${stem}.json"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/asx-layout-probe.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

probe_src="$tmp_dir/probe.c"
raw_values="$tmp_dir/raw-values.txt"
metrics_sorted="$tmp_dir/metrics-sorted.txt"
metrics_lines="$tmp_dir/metrics-lines.txt"

cat >"$probe_src" <<'EOF'
#include <stddef.h>
#include <asx/asx.h>
#include <asx/core/cleanup.h>

#define ASX_ALIGNOF(T) ((unsigned long)offsetof(struct { char c; T v; }, v))

const unsigned long asx_probe_size_asx_region_id = sizeof(asx_region_id);
const unsigned long asx_probe_size_asx_task_id = sizeof(asx_task_id);
const unsigned long asx_probe_size_asx_obligation_id = sizeof(asx_obligation_id);
const unsigned long asx_probe_size_asx_timer_id = sizeof(asx_timer_id);
const unsigned long asx_probe_size_asx_channel_id = sizeof(asx_channel_id);
const unsigned long asx_probe_size_asx_time = sizeof(asx_time);
const unsigned long asx_probe_size_asx_status = sizeof(asx_status);
const unsigned long asx_probe_size_asx_outcome_severity = sizeof(asx_outcome_severity);
const unsigned long asx_probe_size_asx_cancel_kind = sizeof(asx_cancel_kind);
const unsigned long asx_probe_size_asx_cancel_phase = sizeof(asx_cancel_phase);

const unsigned long asx_probe_size_void_ptr = sizeof(void *);
const unsigned long asx_probe_size_size_t = sizeof(size_t);

const unsigned long asx_probe_size_asx_budget = sizeof(asx_budget);
const unsigned long asx_probe_align_asx_budget = ASX_ALIGNOF(asx_budget);

const unsigned long asx_probe_size_asx_outcome = sizeof(asx_outcome);
const unsigned long asx_probe_align_asx_outcome = ASX_ALIGNOF(asx_outcome);

const unsigned long asx_probe_size_asx_cancel_reason = sizeof(asx_cancel_reason);
const unsigned long asx_probe_align_asx_cancel_reason = ASX_ALIGNOF(asx_cancel_reason);

const unsigned long asx_probe_size_asx_runtime_config = sizeof(asx_runtime_config);
const unsigned long asx_probe_align_asx_runtime_config = ASX_ALIGNOF(asx_runtime_config);

const unsigned long asx_probe_size_asx_runtime_hooks = sizeof(asx_runtime_hooks);
const unsigned long asx_probe_align_asx_runtime_hooks = ASX_ALIGNOF(asx_runtime_hooks);

const unsigned long asx_probe_size_asx_error_ledger_entry = sizeof(asx_error_ledger_entry);
const unsigned long asx_probe_align_asx_error_ledger_entry = ASX_ALIGNOF(asx_error_ledger_entry);

const unsigned long asx_probe_size_asx_cleanup_stack = sizeof(asx_cleanup_stack);
const unsigned long asx_probe_align_asx_cleanup_stack = ASX_ALIGNOF(asx_cleanup_stack);

const unsigned long asx_probe_budget_cleanup_stack_capacity = ASX_CLEANUP_STACK_CAPACITY;
const unsigned long asx_probe_budget_error_ledger_depth = ASX_ERROR_LEDGER_DEPTH;
const unsigned long asx_probe_budget_error_ledger_task_slots = ASX_ERROR_LEDGER_TASK_SLOTS;
const unsigned long asx_probe_budget_error_ledger_capacity_entries =
    (unsigned long)ASX_ERROR_LEDGER_DEPTH * (unsigned long)ASX_ERROR_LEDGER_TASK_SLOTS;
const unsigned long asx_probe_budget_error_ledger_entry_bytes = sizeof(asx_error_ledger_entry);
const unsigned long asx_probe_budget_error_ledger_capacity_bytes =
    (unsigned long)ASX_ERROR_LEDGER_DEPTH * (unsigned long)ASX_ERROR_LEDGER_TASK_SLOTS *
    (unsigned long)sizeof(asx_error_ledger_entry);
const unsigned long asx_probe_budget_cleanup_stack_bytes = sizeof(asx_cleanup_stack);
const unsigned long asx_probe_budget_runtime_config_bytes = sizeof(asx_runtime_config);
const unsigned long asx_probe_budget_runtime_hooks_bytes = sizeof(asx_runtime_hooks);
EOF

declare -a compile_cmd
compile_cmd=("$compiler" "-std=c99" "-I$repo_root/include" "-DASX_PROFILE_${profile}")
if [[ -n "$bits" ]]; then
  compile_cmd+=("-m${bits}")
fi
if [[ -n "$extra_cflags" ]]; then
  # shellcheck disable=SC2206
  extra_tokens=($extra_cflags)
  compile_cmd+=("${extra_tokens[@]}")
fi
compile_cmd+=("-S" "-o" "$asm_path" "$probe_src")

if ! "${compile_cmd[@]}" >"$log_path" 2>&1; then
  echo "layout probe compile failed for target '$target_id' (see $log_path)" >&2
  exit 1
fi

awk '
  {
    if (match($0, /^[[:space:]]*(asx_probe_[A-Za-z0-9_]+):[[:space:]]*$/, m)) {
      symbol = m[1];
      next;
    }
    if (symbol != "" &&
        match($0, /^[[:space:]]*\.(quad|long|word|byte|2byte|4byte|8byte|xword|dword)[[:space:]]+([^[:space:],#]+)/, m)) {
      print symbol "=" m[2];
      symbol = "";
    }
  }
' "$asm_path" >"$raw_values"

if [[ ! -s "$raw_values" ]]; then
  echo "layout probe parse failed for target '$target_id' (no probe constants found in $asm_path)" >&2
  exit 1
fi

{
  echo "schema=asx.layout_budget.v1"
  echo "run_id=$run_id"
  echo "target_id=$target_id"
  echo "compiler=$compiler"
  echo "profile=ASX_PROFILE_${profile}"
  if [[ -n "$bits" ]]; then
    echo "bits=$bits"
  else
    echo "bits=unknown"
  fi
  echo "resource_class=$resource_class"
  echo "asm_path=$asm_path"
} >"$kv_path"

while IFS='=' read -r symbol raw_value; do
  metric=""
  case "$symbol" in
    asx_probe_size_*)
      metric="size.${symbol#asx_probe_size_}"
      ;;
    asx_probe_align_*)
      metric="align.${symbol#asx_probe_align_}"
      ;;
    asx_probe_budget_*)
      metric="budget.${symbol#asx_probe_budget_}"
      ;;
    *)
      continue
      ;;
  esac

  if ! value="$(to_decimal "$raw_value")"; then
    echo "non-numeric probe value '$raw_value' for '$symbol'" >&2
    exit 1
  fi
  printf '%s=%s\n' "$metric" "$value" >>"$metrics_lines"
done <"$raw_values"

sort "$metrics_lines" >"$metrics_sorted"
cat "$metrics_sorted" >>"$kv_path"

{
  printf '{\n'
  printf '  "schema": "asx.layout_budget.v1",\n'
  printf '  "run_id": "%s",\n' "$(json_escape "$run_id")"
  printf '  "target_id": "%s",\n' "$(json_escape "$target_id")"
  printf '  "compiler": "%s",\n' "$(json_escape "$compiler")"
  printf '  "profile": "%s",\n' "$(json_escape "ASX_PROFILE_${profile}")"
  if [[ -n "$bits" ]]; then
    printf '  "bits": "%s",\n' "$(json_escape "$bits")"
  else
    printf '  "bits": "unknown",\n'
  fi
  printf '  "resource_class": "%s",\n' "$(json_escape "$resource_class")"
  printf '  "asm_path": "%s",\n' "$(json_escape "$asm_path")"
  printf '  "metrics": [\n'

  first=1
  while IFS='=' read -r metric value; do
    [[ -z "$metric" ]] && continue
    if [[ "$first" -eq 0 ]]; then
      printf ',\n'
    fi
    printf '    {"name":"%s","value":%s}' "$(json_escape "$metric")" "$value"
    first=0
  done <"$metrics_sorted"

  printf '\n  ]\n'
  printf '}\n'
} >"$json_path"

printf '%s\n' "$json_path"
