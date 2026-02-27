#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: compute_layout_budget_delta.sh
  --run-id <id>
  --index-file <path>
  --output <path>

Index file format (tab-separated):
  <target_id>\t<kv_report_path>

Produces a deterministic JSON delta report and exits with:
  0  success, no invariant regressions
  3  success, invariant regressions flagged
  1  error while computing report
EOF
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

is_invariant_metric() {
  case "$1" in
    size.asx_region_id|\
    size.asx_task_id|\
    size.asx_obligation_id|\
    size.asx_timer_id|\
    size.asx_channel_id|\
    size.asx_time|\
    size.asx_status|\
    size.asx_outcome_severity|\
    size.asx_cancel_kind|\
    size.asx_cancel_phase|\
    size.asx_budget|\
    budget.cleanup_stack_capacity|\
    budget.error_ledger_depth|\
    budget.error_ledger_task_slots)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

load_metrics() {
  local kv_path="$1"
  local map_name="$2"
  declare -n map_ref="$map_name"

  while IFS='=' read -r key value; do
    case "$key" in
      size.*|align.*|budget.*)
        if [[ "$value" =~ ^-?[0-9]+$ ]]; then
          map_ref["$key"]="$value"
        fi
        ;;
      *)
        ;;
    esac
  done <"$kv_path"
}

run_id=""
index_file=""
output_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --index-file)
      index_file="$2"
      shift 2
      ;;
    --output)
      output_path="$2"
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

if [[ -z "$run_id" || -z "$index_file" || -z "$output_path" ]]; then
  echo "Missing required arguments" >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$index_file" ]]; then
  echo "Index file not found: $index_file" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/asx-layout-delta.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

entries_file="$tmp_dir/entries.tsv"
differences_file="$tmp_dir/differences.tsv"
regressions_file="$tmp_dir/regressions.tsv"
invariants_file="$tmp_dir/invariants.txt"

grep -v '^[[:space:]]*$' "$index_file" >"$entries_file" || true
entry_count="$(wc -l <"$entries_file" | tr -d ' ')"

cat >"$invariants_file" <<'EOF'
size.asx_region_id
size.asx_task_id
size.asx_obligation_id
size.asx_timer_id
size.asx_channel_id
size.asx_time
size.asx_status
size.asx_outcome_severity
size.asx_cancel_kind
size.asx_cancel_phase
size.asx_budget
budget.cleanup_stack_capacity
budget.error_ledger_depth
budget.error_ledger_task_slots
EOF

if [[ "$entry_count" -lt 2 ]]; then
  mkdir -p "$(dirname "$output_path")"
  {
    printf '{\n'
    printf '  "schema": "asx.layout_budget_delta.v1",\n'
    printf '  "run_id": "%s",\n' "$(json_escape "$run_id")"
    printf '  "status": "insufficient_data",\n'
    printf '  "targets_compared": %s,\n' "$entry_count"
    printf '  "regression_count": 0,\n'
    printf '  "difference_count": 0,\n'
    printf '  "regressions": [],\n'
    printf '  "differences": []\n'
    printf '}\n'
  } >"$output_path"
  exit 0
fi

IFS=$'\t' read -r baseline_target baseline_kv <"$entries_file"
if [[ -z "$baseline_target" || -z "$baseline_kv" || ! -f "$baseline_kv" ]]; then
  echo "Invalid baseline entry in $index_file" >&2
  exit 1
fi

declare -A baseline_metrics
load_metrics "$baseline_kv" baseline_metrics

: >"$differences_file"
: >"$regressions_file"

tail -n +2 "$entries_file" | while IFS=$'\t' read -r target kv_path; do
  [[ -z "$target" || -z "$kv_path" ]] && continue
  if [[ ! -f "$kv_path" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$target" "__missing_report__" "0" "0" "0" >>"$regressions_file"
    continue
  fi

  declare -A target_metrics=()
  load_metrics "$kv_path" target_metrics

  for metric in "${!baseline_metrics[@]}"; do
    baseline_value="${baseline_metrics[$metric]}"
    target_value="${target_metrics[$metric]:-}"
    if [[ -z "$target_value" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$target" "$metric" "$baseline_value" "0" "0" >>"$regressions_file"
      continue
    fi

    delta=$((target_value - baseline_value))
    if [[ "$delta" -ne 0 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$target" "$metric" "$baseline_value" "$target_value" "$delta" >>"$differences_file"
      if is_invariant_metric "$metric"; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$target" "$metric" "$baseline_value" "$target_value" "$delta" >>"$regressions_file"
      fi
    fi
  done
done

difference_count="$(wc -l <"$differences_file" | tr -d ' ')"
regression_count="$(wc -l <"$regressions_file" | tr -d ' ')"

status="pass"
if [[ "$regression_count" -gt 0 ]]; then
  status="regression"
fi

mkdir -p "$(dirname "$output_path")"
{
  printf '{\n'
  printf '  "schema": "asx.layout_budget_delta.v1",\n'
  printf '  "run_id": "%s",\n' "$(json_escape "$run_id")"
  printf '  "baseline_target": "%s",\n' "$(json_escape "$baseline_target")"
  printf '  "status": "%s",\n' "$status"
  printf '  "targets_compared": %s,\n' "$entry_count"
  printf '  "difference_count": %s,\n' "$difference_count"
  printf '  "regression_count": %s,\n' "$regression_count"

  printf '  "invariant_metrics": [\n'
  inv_first=1
  while IFS= read -r invariant; do
    [[ -z "$invariant" ]] && continue
    if [[ "$inv_first" -eq 0 ]]; then
      printf ',\n'
    fi
    printf '    "%s"' "$(json_escape "$invariant")"
    inv_first=0
  done <"$invariants_file"
  printf '\n  ],\n'

  printf '  "regressions": [\n'
  reg_first=1
  while IFS=$'\t' read -r target metric baseline_value target_value delta; do
    [[ -z "$target" ]] && continue
    if [[ "$reg_first" -eq 0 ]]; then
      printf ',\n'
    fi
    printf '    {"target":"%s","metric":"%s","baseline":%s,"value":%s,"delta":%s}' \
      "$(json_escape "$target")" \
      "$(json_escape "$metric")" \
      "$baseline_value" \
      "$target_value" \
      "$delta"
    reg_first=0
  done <"$regressions_file"
  printf '\n  ],\n'

  printf '  "differences": [\n'
  diff_first=1
  while IFS=$'\t' read -r target metric baseline_value target_value delta; do
    [[ -z "$target" ]] && continue
    if [[ "$diff_first" -eq 0 ]]; then
      printf ',\n'
    fi
    printf '    {"target":"%s","metric":"%s","baseline":%s,"value":%s,"delta":%s}' \
      "$(json_escape "$target")" \
      "$(json_escape "$metric")" \
      "$baseline_value" \
      "$target_value" \
      "$delta"
    diff_first=0
  done <"$differences_file"
  printf '\n  ]\n'
  printf '}\n'
} >"$output_path"

if [[ "$regression_count" -gt 0 ]]; then
  exit 3
fi
exit 0
