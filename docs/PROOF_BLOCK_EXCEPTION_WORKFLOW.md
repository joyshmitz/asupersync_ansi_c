# Proof-Block Exception Workflow

> **Bead:** `bd-66l.7`
> **Gate:** `lint-anti-butchering` (`tools/ci/check_anti_butchering.sh`)
> **Enforcement contract:** `docs/GUARANTEE_SUBSTITUTION_MATRIX.md` section 4-5

## Overview

The anti-butchering proof-block gate enforces that semantic-sensitive
changes include a complete `Guarantee Impact` metadata block. When a
change cannot provide the standard block, this workflow governs how
exceptions are requested, approved, and tracked.

## When the Gate Triggers

The gate scans changed files against semantic-sensitive paths:

| Path prefix | Scope |
|-------------|-------|
| `src/core/` | State machines, types, cancel, budget, cleanup, ghost |
| `src/runtime/` | Hooks, lifecycle, scheduler, cancellation, trace, adapters |
| `src/channel/` | MPSC ordering, channel semantics |
| `src/time/` | Timer wheel, deadline mechanics |
| `include/asx/core/` | Public core headers |
| `include/asx/asx_ids.h` | Canonical type/enum definitions |
| `include/asx/asx_status.h` | Error code taxonomy |
| `docs/GUARANTEE_SUBSTITUTION_MATRIX.md` | Substitution contract itself |
| `docs/LIFECYCLE_TRANSITION_TABLES.md` | Transition authority |

If any of these paths are modified, the commit message or PR body must
contain a valid `Guarantee Impact` block.

## Standard Compliance

Add the following block to your commit message:

```
Guarantee Impact:
- gs_id: GS-00X
- change: <old mechanism> -> <new mechanism>
- preserved invariants: <explicit list>
- proof artifacts: <tests/fixtures/parity rows>
- fallback mode: <safe-mode behavior>
- deterministic isomorphism note: <ordering/tie-break impact>
- semantic delta budget: 0
```

See `docs/GUARANTEE_SUBSTITUTION_MATRIX.md` section 4 for field details.

## File-Level Waiver

For files that are touched frequently without semantic impact (e.g.,
adding a new non-kernel function to a sensitive module), add a
file-level waiver annotation in the first 30 lines:

```c
/* ASX_PROOF_BLOCK_WAIVER("reason: module-internal helper, no kernel semantic change") */
```

The gate skips files with this annotation. Waivers are auditable in
the gate's JSON artifact.

## Exception Request Process

When a semantic-sensitive change genuinely cannot provide the full
proof block (e.g., exploratory refactoring, dependency updates), use
the exception flow:

### Step 1: Add Exception Block

Include in the commit message alongside the partial Guarantee Impact:

```
Guarantee Impact:
- gs_id: GS-00X
- change: <description>
- preserved invariants: (pending — tracked in bd-XXXX)
- proof artifacts: (deferred — exception below)
- fallback mode: <current behavior unchanged>
- deterministic isomorphism note: no tie-break change
- semantic delta budget: 0

Exception:
- exception_id: EXC-YYYY-MM-DD-NNN
- exception_rationale: <why full proof cannot be provided now>
- exception_approver: <owner name or "pending">
- exception_deadline: <date by which proof will be supplied>
- tracking_bead: bd-XXXX
```

### Step 2: Owner Approval

The exception must be approved by a project owner before merge. The
approver field must be filled with a valid name (not "pending") for
the gate to accept the exception.

### Step 3: Track Resolution

The `tracking_bead` field links to a bead that tracks when the full
proof will be supplied. The exception is not considered resolved until
that bead is closed.

## Non-Zero Semantic Delta Budget

If the semantic delta budget is non-zero (the change intentionally
alters semantic behavior), additional fields are required:

```
- semantic delta budget: N
- budget_rationale: <why the semantic change is necessary>
- budget_approver: <owner who approved the delta>
```

Non-zero budgets are tracked in the gate artifact for audit purposes.

## Viewing Gate Results

The gate produces a JSON artifact at:
```
build/conformance/anti_butcher_<run_id>.json
```

This artifact contains:
- List of sensitive files changed
- Guarantee Impact block parse results
- Missing field inventory
- Exception validation results
- Pass/fail status

## Rerunning the Gate

```bash
# Default: check HEAD vs HEAD~1
make lint-anti-butchering

# Check a PR branch against main
ASX_ANTI_BUTCHER_BASE_REF=main \
ASX_ANTI_BUTCHER_HEAD_REF=HEAD \
  tools/ci/check_anti_butchering.sh

# Check with verbose output
tools/ci/check_anti_butchering.sh --verbose

# JSON output for CI consumption
tools/ci/check_anti_butchering.sh --json
```

## Automatic Rejection Conditions

Per `GUARANTEE_SUBSTITUTION_MATRIX.md` section 5, these conditions
cannot be waived:

1. Touches GS-001..GS-008 mechanism without *any* proof artifacts
2. Weakens handle validation, transition guards, or linearity
3. Introduces nondeterministic tie-break in deterministic mode
4. Changes cancellation/exhaustion without fixture updates
5. Profile-specific fork changing semantic digest
6. Defers kernel-scope row without owner approval
7. Claims performance wins while removing fallback/safe-mode

These conditions require full compliance, not exceptions.
