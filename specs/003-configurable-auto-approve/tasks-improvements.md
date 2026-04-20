# Tasks: Code Review Improvements — Auto-Approve Tools

**Input**: Code review findings from self-review on feature `003-configurable-auto-approve`
**Prerequisites**: plan.md (completed), spec.md (completed)

**Tests**: Not requested — test tasks omitted.

**Organization**: Each improvement item is an independently testable task based on review findings.

## Format: `[ID] [P?] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

---

## Phase 1: Review Improvements

**Purpose**: Address the 3 improvement suggestions from code review

- [x] T001 [P] Add thread-safety comment on `isAutoApproveTool(_:)` in `Sources/CodeIsland/Settings.swift` — document that callers must be on MainActor (same as SettingsManager) since UserDefaults read is safe but actor isolation is assumed
- [x] T002 [P] Add unit test for `isAutoApproveTool` default fallback behavior (no UserDefaults key → returns true for tools in default set, false for unknown tools) in `Sources/CodeIslandTests/SettingsAutoApproveTests.swift`
- [x] T003 [P] Add unit test for `setAutoApproveTool` + `isAutoApproveTool` round-trip (set OFF → returns false, set ON → returns true) in `Sources/CodeIslandTests/SettingsAutoApproveTests.swift`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1**: All 3 tasks are independent and can run in parallel

### Parallel Opportunities

- T001, T002, T003 can all run in parallel (different files)

---

## Parallel Example

```bash
# Launch all improvement tasks in parallel:
Task: "Add thread-safety comment in Sources/CodeIsland/Settings.swift"
Task: "Add default fallback test in Sources/CodeIslandTests/SettingsAutoApproveTests.swift"
Task: "Add round-trip test in Sources/CodeIslandTests/SettingsAutoApproveTests.swift"
```

---

## Implementation Strategy

All 3 tasks are small improvements that can be done in a single pass:
1. T001 — One-line documentation comment
2. T002 + T003 — Unit tests for the new settings API
