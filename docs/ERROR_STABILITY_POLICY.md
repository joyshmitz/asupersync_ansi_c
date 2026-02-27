# Error Stability Policy

**Version:** 1.0
**Applies to:** `asx_status` enum in `include/asx/asx_status.h`
**Bead:** bd-hwb.7

## Stability Guarantee

All error codes in `asx_status` are **semantically frozen** once published:

1. **Meanings never change.** An existing error code retains its documented semantics across all library versions.
2. **Codes never removed.** Deprecated codes remain in the enum with their original numeric value.
3. **Numeric values never reassigned.** Each integer maps to exactly one status meaning forever.

## Growth Rules

The error taxonomy follows **additive-only** growth:

- New error codes MAY be added to any existing family.
- New error families MAY be added with new numeric ranges.
- Existing ranges are exclusive to their family (e.g., 3xx is always region errors).

### Family Allocation

| Range  | Family                  | Status   |
|--------|-------------------------|----------|
| 0      | Success (`ASX_OK`)      | Frozen   |
| 1-9    | Non-error status        | Frozen   |
| 1xx    | General errors          | Frozen   |
| 2xx    | Transition errors       | Frozen   |
| 3xx    | Region errors           | Frozen   |
| 4xx    | Task errors             | Frozen   |
| 5xx    | Obligation errors       | Frozen   |
| 6xx    | Cancel errors           | Frozen   |
| 7xx    | Channel errors          | Frozen   |
| 8xx    | Timer errors            | Frozen   |
| 9xx    | Quiescence errors       | Frozen   |
| 10xx   | Resource exhaustion     | Frozen   |
| 11xx   | Handle errors           | Frozen   |
| 12xx   | Hook/runtime contract   | Frozen   |
| 13xx+  | Reserved for future     | Reserved |

## Client Compatibility

Callers SHOULD:

- Switch on specific codes they handle, with a default/else branch for unknown codes.
- Use `asx_is_error(st)` for generic error detection.
- Use `asx_status_str(st)` for diagnostics (never parse the string for control flow).

Callers MUST NOT:

- Rely on numeric ordering between families for severity ranking.
- Assume the set of codes in a family is complete (new codes may appear).

## Must-Use Enforcement

All functions returning `asx_status` that represent fallible operations carry `ASX_MUST_USE`. This produces compiler warnings when return values are discarded. The must-use surface is enumerable via:

```c
uint32_t n = asx_must_use_surface_count();
for (uint32_t i = 0; i < n; i++) {
    printf("%s\n", asx_must_use_surface_name(i));
}
```

## Error Ledger

The zero-allocation error ledger (`ASX_TRY`, `asx_error_ledger_*`) records breadcrumbs with file/line/operation context. Ledger entries include:

- `status` — the error code
- `operation` — stringified expression or function name
- `file` / `line` — source location
- `sequence` — monotonic counter for deterministic ordering

The ledger uses a ring buffer (depth 16 per task) and never allocates.

## Versioning

The error taxonomy version tracks the library version (`ASX_API_VERSION_*`). When new codes are added, the patch version increments. Family-level additions increment the minor version.
