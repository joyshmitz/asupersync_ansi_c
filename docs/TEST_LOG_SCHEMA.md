# Test Log Schema and Artifact Taxonomy (bd-1md.11)

## Overview

All test layers emit structured JSONL log records conforming to
`schemas/test_log.schema.json`. This enables machine-readable CI
validation, regression triage, and artifact lifecycle management.

## Log Emission

### Enabling Structured Logs

Include `test_log.h` before `test_harness.h` in test files:

```c
#include "test_log.h"
#include "test_harness.h"
```

Then initialize/close in `main()`:

```c
int main(void) {
    test_log_open("unit", "core/budget", "test_budget");
    RUN_TEST(my_test);
    TEST_REPORT();
    test_log_close();
    return test_failures;
}
```

Logs are written to `build/test-logs/` (override with `ASX_TEST_LOG_DIR`).

### Record Schema

Every JSONL record contains these required fields:

| Field | Type | Description |
|-------|------|-------------|
| `ts` | ISO 8601 | Timestamp with timezone |
| `run_id` | string | Unique run identifier |
| `layer` | enum | `unit`, `invariant`, `conformance`, `e2e`, `bench`, `fuzz` |
| `subsystem` | string | Module under test (e.g. `core/budget`) |
| `status` | enum | `pass`, `fail`, `skip`, `error` |

Optional fields:

| Field | Type | Description |
|-------|------|-------------|
| `suite` | string | Test suite name |
| `test` | string | Individual test name |
| `event_index` | integer | Monotonic sequence within run |
| `profile` | string | ASX profile in use |
| `codec` | enum | `json` or `bin` |
| `seed` | integer | Deterministic seed |
| `digest` | string | Semantic digest (`sha256:...` or `fnv1a:...`) |
| `scenario_id` | string | Fixture scenario ID |
| `duration_ns` | integer | Test duration in nanoseconds |
| `error` | object | Error metadata (on failure) |
| `metrics` | object | Performance metrics (bench layer) |
| `parity` | enum | Parity check result (conformance) |
| `delta_classification` | enum | Delta classification for failures |
| `artifacts` | array | Associated artifact references |

## Artifact Taxonomy

### Directory Layout

```
build/test-logs/
  unit-test_budget.jsonl          # Unit test logs
  unit-test_scheduler.jsonl
  invariant-skeleton_test.jsonl
  conformance-*.jsonl             # Conformance runner logs

tools/ci/artifacts/
  conformance/                    # Conformance reports and diffs
    {run_id}-{mode}.jsonl
    {run_id}-{mode}.summary.json
    {run_id}-{mode}.diffs.jsonl
    {run_id}-{mode}-diffs/        # Per-failure diff artifacts
```

### Artifact Kinds

| Kind | Layer | Description | Retention |
|------|-------|-------------|-----------|
| `trace_snapshot` | any | Trace ring buffer export | 30 days |
| `parity_diff` | conformance | Field-level mismatch report | permanent |
| `minimizer_output` | fuzz | Minimized counterexample | permanent |
| `replay_bundle` | conformance, e2e | Seed + input for deterministic replay | 90 days |
| `build_log` | any | Compilation stdout/stderr | 7 days |
| `stderr_log` | any | Test stderr capture | 7 days |
| `core_dump` | any | Crash dump (if applicable) | 7 days |

### Retention Policy

- **Permanent**: Parity diffs and minimized counterexamples (evidence of regression).
- **90 days**: Replay bundles and scenario artifacts.
- **30 days**: Trace snapshots and intermediate outputs.
- **7 days**: Build logs, stderr logs, core dumps (ephemeral diagnostics).

CI cleanup: `find build/test-logs -mtime +7 -delete` for ephemeral artifacts.

## CI Validation

### Running the Validator

```bash
tools/ci/validate_test_logs.sh [--log-dir <dir>] [--strict]
```

The validator checks:
- All required fields present in every JSONL record
- `status` and `layer` values are valid enum members
- Records are well-formed JSON

In `--strict` mode, missing log directory or empty logs cause failure.

### Integration with Makefile

```bash
make test                          # Emits logs to build/test-logs/
tools/ci/validate_test_logs.sh     # Validates emitted logs
```

## Triage Playbook

### Quick Triage from Logs

```bash
# Find all failures
grep '"status":"fail"' build/test-logs/*.jsonl

# Find failures in a specific subsystem
grep '"subsystem":"runtime/cancellation"' build/test-logs/*.jsonl | grep '"fail"'

# Extract error locations
grep '"fail"' build/test-logs/*.jsonl | grep -o '"file":"[^"]*","line":[0-9]*'

# Count pass/fail per suite
for f in build/test-logs/*.jsonl; do
  pass=$(grep -c '"pass"' "$f" 2>/dev/null || echo 0)
  fail=$(grep -c '"fail"' "$f" 2>/dev/null || echo 0)
  echo "$(basename "$f"): $pass pass, $fail fail"
done
```

### Regression Localization

1. Compare JSONL logs from two runs with `diff` or `jq`.
2. Filter by `delta_classification: "c_regression"` for semantic drift.
3. Check `error.file` and `error.line` for exact failure location.
4. Use `seed` field to reproduce deterministic failures.
5. Cross-reference `scenario_id` with fixture families for parity issues.
