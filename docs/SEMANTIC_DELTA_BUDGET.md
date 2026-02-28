# Semantic Delta Budget Gate

> **Bead:** `bd-66l.3`
> **Gate:** `conformance`, `codec-equivalence`, `profile-parity` (embedded in `tools/ci/run_conformance.sh`)
> **Enforcement contract:** `docs/GUARANTEE_SUBSTITUTION_MATRIX.md` section 4-5

## Overview

The semantic delta budget gate enforces zero behavioral drift between the
Rust reference and C port. Every conformance, codec-equivalence, and
profile-parity run computes the number of semantic deltas (digest
mismatches beyond harness defects). By default the allowed budget is **0**.

Any non-zero delta fails the gate unless an approved exception exists.

## How the Gate Works

1. **Conformance run** compares C outputs against Rust reference fixtures.
2. Each mismatch is classified:
   - `harness_defect` — build/infrastructure failure, **never budgetable**
   - semantic delta — real behavioral difference, subject to budget
3. The gate checks: `semantic_delta_count <= allowed_budget`
4. If the exception file contains matching approved records, `allowed_budget`
   is raised to the highest approved budget among matches.
5. Non-budgetable failures always fail the gate regardless of budget.

## Default Behavior

```
ASX_SEMANTIC_DELTA_BUDGET=0   # default, enforced in CI
```

With no exception file or an empty exception file (`[]`), any semantic
delta fails the gate. This is the intended default to prevent silent
behavioral erosion.

## Exception File

Path: `docs/SEMANTIC_DELTA_EXCEPTIONS.json` (override via
`ASX_SEMANTIC_DELTA_EXCEPTION_FILE` environment variable).

Format: JSON array of exception records.

### Exception Record Schema

```json
{
  "id": "EXC-YYYY-MM-DD-NNN",
  "status": "approved",
  "approver": "owner_name",
  "budget": 1,
  "mode": "conformance",
  "scenario_ids": ["fixture_scenario_001"],
  "rationale": "Why this delta is acceptable",
  "tracking_bead": "bd-XXXX",
  "deadline": "YYYY-MM-DD",
  "created_at": "YYYY-MM-DD"
}
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Stable exception identifier (format: `EXC-YYYY-MM-DD-NNN`) |
| `status` | string | Must be `"approved"` for the gate to consider it |
| `approver` | string | Non-empty name of the approving owner |
| `budget` | number | Maximum allowed semantic deltas (>= 0) |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mode` | string | `"any"` | Gate mode: `"conformance"`, `"codec-equivalence"`, `"profile-parity"`, or `"any"` |
| `scenario_ids` | string[] | `[]` (wildcard) | Fixture scenarios covered; empty or `["*"]` matches all |
| `rationale` | string | — | Why the delta is acceptable |
| `tracking_bead` | string | — | Bead tracking when the exception will be resolved |
| `deadline` | string | — | Date by which the delta should be resolved |
| `created_at` | string | — | When the exception was created |

### Matching Rules

An exception matches the current run when ALL conditions hold:

1. `status == "approved"`
2. `id` is non-empty
3. `approver` is non-empty
4. `budget` is a number >= 0
5. `mode` matches the current run mode OR is `"any"`
6. `scenario_ids` covers impacted scenarios:
   - Contains `"*"` (wildcard), OR
   - All impacted scenario IDs are present in `scenario_ids`

When multiple exceptions match, the highest `budget` value wins.

## Exception Workflow

### Step 1: Identify the Delta

Run conformance locally:

```bash
make conformance
```

The gate output includes:
```
[asx] conformance[conformance]: semantic_delta_count=N allowed_budget=0 ...
```

The artifact at `build/conformance/semantic_delta_<run_id>.json` contains
`changed_semantic_units` with per-unit details:

```json
{
  "changed_semantic_units": [
    {
      "kind": "...",
      "scenario_id": "...",
      "delta_classification": "...",
      "diagnostic": "..."
    }
  ]
}
```

### Step 2: Create Exception Record

Add an entry to `docs/SEMANTIC_DELTA_EXCEPTIONS.json`:

```json
[
  {
    "id": "EXC-2026-02-28-001",
    "status": "pending",
    "approver": "",
    "budget": 1,
    "mode": "conformance",
    "scenario_ids": ["specific_scenario_id"],
    "rationale": "Explain why this delta is intentional",
    "tracking_bead": "bd-XXXX",
    "deadline": "2026-03-15"
  }
]
```

### Step 3: Owner Approval

The exception must be approved before the gate accepts it:

1. Set `"status": "approved"`
2. Set `"approver"` to the reviewing owner's name
3. Commit the change with a Guarantee Impact block (per `bd-66l.7`)

Exceptions with `"status": "pending"` are ignored by the gate.

### Step 4: Track Resolution

The `tracking_bead` links to the bead that will resolve the delta.
The exception should be removed once the bead is closed and the delta
is eliminated.

### Step 5: Cleanup

When the root cause is fixed, remove the exception record and verify
the gate passes with budget 0:

```bash
ASX_SEMANTIC_DELTA_BUDGET=0 make conformance
```

## Non-Budgetable Failures

Failures classified as `harness_defect` cannot be budgeted. These
represent build failures, test infrastructure issues, or data format
errors that must be fixed before the gate can evaluate semantic deltas.

## CI Integration

The semantic delta budget gate runs as part of:

```bash
make conformance          # Rust fixture parity
make codec-equivalence    # JSON vs BIN digest parity
make profile-parity       # Cross-profile digest parity
```

All three modes share the same exception file and budget policy.

The `check-ci` Makefile target includes all three modes.

## Artifact Structure

```
build/conformance/
  semantic_delta_<run_id>.json     # Budget gate result
  conformance_<run_id>.json        # Full conformance report
  conformance_<run_id>.summary.json # Summary with budget fields
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ASX_SEMANTIC_DELTA_BUDGET` | `0` | Default allowed budget |
| `ASX_SEMANTIC_DELTA_EXCEPTION_FILE` | `docs/SEMANTIC_DELTA_EXCEPTIONS.json` | Exception ledger path |

## Automatic Rejection Conditions

Per `GUARANTEE_SUBSTITUTION_MATRIX.md` section 5, these cannot be
waived by budget exceptions:

1. Non-budgetable failures (harness defects, build failures)
2. Changes that weaken handle validation or transition guards
3. Changes introducing nondeterministic tie-break in deterministic mode

These conditions require code fixes, not budget increases.
