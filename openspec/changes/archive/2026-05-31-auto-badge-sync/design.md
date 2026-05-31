## Context

CodeIsland's session card displays an AUTO indicator (⏵⏵) when auto-approve is active. Currently this state is purely local — toggled by the user in the approval UI — and has no connection to the CLI's actual permission mode. The CLI reports `permission_mode` in hook events via `SessionSnapshot.permissionMode`, but this data was not used to sync the UI state.

## Goals

- Change the AUTO indicator color from red to yellow (#FFCC00)
- Display hook-reported permission mode as secondary metadata in the session card
- Keep CodeIsland's AUTO state synchronized with CLI permission mode bidirectionally
- Reuse existing `SessionSnapshot.permissionMode` and `AppState.autoApproveSessionId` fields without adding new state

## Non-Goals

- Changing the `ApprovalBar` AUTO APPROVE state strip color (remains red)
- Changing the YOLO badge color
- Adding new hook protocol fields or transcript parsing
- Creating a strongly-typed permission mode enum
- Adding global theme or design token system

## Decisions

### 1. Sync in `handleEvent` after `reduceEvent`

**Choice**: Check `permissionMode` in `AppState.handleEvent` after the reducer runs and effects are executed.

**Why**: The reducer updates `SessionSnapshot.permissionMode` from hook payload data. Checking immediately after ensures the sync happens in the same event processing cycle. This avoids modifying `CodeIslandCore`'s reducer (which has no access to `AppState.autoApproveSessionId`).

**Alternative**: Return a side effect from the reducer. Rejected because `autoApproveSessionId` is `AppState`-local state not visible to `CodeIslandCore`.

### 2. Auto-activate on CLI auto mode

**Choice**: When `permissionMode` is `auto`, `acceptEdits`, or `bypassPermissions`, set `autoApproveSessionId` and derive `autoApproveModeSnapshot` from the mode string.

**Why**: Users expect the UI to reflect CLI state. If they toggle auto in the CLI, CodeIsland should show the ⏵⏵ indicator without requiring a manual click.

### 3. Permission mode as secondary text, not badge

**Choice**: Display `permissionMode` as a plain `Text` with `.secondary` opacity, not a colored capsule badge.

**Why**: Minimum visual disruption. The session identity line is already compact. A capsule badge would compete with the ⏵⏵ indicator and session labels.

## Risks / Trade-offs

- **Stale permission mode**: Hook events may not always include `permission_mode`, so the displayed value could be outdated. Mitigation: UI treats it as observed metadata, not authoritative state.
- **Race between deactivate and new event**: If CLI rapidly toggles modes, multiple events may arrive before UI refreshes. Mitigation: Each event re-evaluates the full mode, so the last event wins.
- **Non-Claude sessions**: Other CLIs may not report `permission_mode` at all. The sync logic only fires when `permissionMode` is non-nil, so it's a no-op for those sessions.

## Migration Plan

No migration needed. The change is purely additive UI behavior. If issues arise, the sync block in `handleEvent` can be removed to revert to the previous local-only AUTO behavior.

## Open Questions

None.
