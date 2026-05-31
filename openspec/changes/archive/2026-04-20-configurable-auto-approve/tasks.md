# Tasks: Configurable Auto-Approve Tools

**Input**: Design documents from `specs/003-configurable-auto-approve/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, quickstart.md

**Tests**: Not explicitly requested in specification — test tasks omitted.

**Organization**: Tasks grouped by user story for independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)

---

## Phase 1: Foundational (Settings Infrastructure)

**Purpose**: Add the configuration storage layer that all user stories depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T001 Add `autoApproveTool(_:)` key function to `SettingsKey` in `Sources/CodeIsland/Settings.swift`
- [x] T002 Add `autoApproveDefaultTools` default set to `SettingsDefaults` in `Sources/CodeIsland/Settings.swift`
- [x] T003 Add `allAutoApproveTools` static array, `isAutoApproveTool(_:)` and `setAutoApproveTool(_:enabled:)` methods to `SettingsManager` in `Sources/CodeIsland/Settings.swift`

**Checkpoint**: Settings infrastructure ready — `SettingsManager.shared.isAutoApproveTool("ExitPlanMode")` returns correct values

---

## Phase 2: User Story 1 - Toggle Auto-Approve for Individual Tools (Priority: P1) 🎯 MVP

**Goal**: Users can see and toggle individual tool auto-approve settings in the Behavior page

**Independent Test**: Open Settings → Behavior → verify "Auto-Approve Tools" section with 10 toggles → toggle OFF one tool → trigger it in CLI → manual approval UI appears

### Implementation for User Story 1

- [x] T004 [P] [US1] Add new Section with ForEach toggle list in `BehaviorPage` in `Sources/CodeIsland/SettingsView.swift`
- [x] T005 [P] [US1] Remove `autoApproveTools` static constant and replace hardcoded check with `SettingsManager.shared.isAutoApproveTool()` in `Sources/CodeIsland/HookServer.swift`

**Checkpoint**: Core feature complete — toggles in settings directly control auto-approve behavior

---

## Phase 3: User Story 2 - Preserve Existing Behavior by Default (Priority: P2)

**Goal**: Upgrade users see zero behavior change; defaults match previous hardcoded list

**Independent Test**: Fresh launch without changing settings → trigger any tool in original autoApproveTools → still auto-approved silently

### Implementation for User Story 2

- [x] T006 [US2] Verify defaults: ensure no UserDefaults keys are written until user changes a toggle — validate `SettingsDefaults.autoApproveDefaultTools` contains all 10 tools in `Sources/CodeIsland/Settings.swift`

**Checkpoint**: Backwards compatibility verified — existing behavior unchanged

---

## Phase 4: User Story 3 - Clear Labeling and Localization (Priority: P3)

**Goal**: Section title and description localized in all 5 languages (en, zh, ja, ko, tr)

**Independent Test**: Switch language → Behavior settings → verify localized section header and description

### Implementation for User Story 3

- [x] T007 [P] [US3] Add `auto_approve_tools` and `auto_approve_tools_desc` keys to all 5 language dictionaries in `Sources/CodeIsland/L10n.swift`
- [x] T008 [US3] Update the Section in `BehaviorPage` to use `l10n["auto_approve_tools"]` for header and optionally add description text in `Sources/CodeIsland/SettingsView.swift`

**Checkpoint**: Full localization — all supported languages display correctly

---

## Phase 5: Polish & Verification

**Purpose**: Build verification and cross-cutting validation

- [x] T009 Build project with `swift build` to verify compilation
- [ ] T010 Manual end-to-end verification per `quickstart.md` test scenarios

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — start immediately
- **User Story 1 (Phase 2)**: Depends on Phase 1 (T001-T003)
- **User Story 2 (Phase 3)**: Implicitly covered by Phase 1 defaults — T006 is a verification task
- **User Story 3 (Phase 4)**: Depends on Phase 2 (T004 needs section to exist before localizing)
- **Polish (Phase 5)**: Depends on all user stories complete

### User Story Dependencies

- **US1**: Depends on Phase 1 settings infrastructure
- **US2**: Covered by Phase 1 default values — verification only
- **US3**: Depends on US1 (needs the UI section to exist before adding localization)

### Parallel Opportunities

- T004 and T005 can run in parallel (different files)
- T006 can run in parallel with T007 (different files, different concerns)

---

## Parallel Example: User Story 1

```bash
# Launch both implementation tasks in parallel:
Task: "Add toggle Section in BehaviorPage in Sources/CodeIsland/SettingsView.swift"
Task: "Replace hardcoded check in HookServer.swift with SettingsManager call"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Settings infrastructure (T001-T003)
2. Complete Phase 2: Core toggle + HookServer integration (T004-T005)
3. **STOP and VALIDATE**: Test toggles in Settings → verify HookServer respects them
4. Feature is functional at this point

### Incremental Delivery

1. Phase 1 + Phase 2 → Working toggles that control auto-approve (MVP!)
2. Phase 3 → Verify backwards compatibility (likely already correct from defaults)
3. Phase 4 → Add localization polish
4. Phase 5 → Build and verify
