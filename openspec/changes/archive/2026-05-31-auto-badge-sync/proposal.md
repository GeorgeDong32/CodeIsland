## Why

The session card AUTO indicator (⏵⏵) was hard-coded red and only reflected CodeIsland's local auto-approve state, with no visibility into the CLI's actual permission mode. When users toggled auto mode directly in Claude Code CLI, the session card indicator would go out of sync — showing ⏵⏵ even after the CLI exited auto, or not showing it when the CLI entered auto independently.

## What Changes

- Change the AUTO ⏵⏵ indicator color from red to yellow (#FFCC00) in the session card identity line
- Display the hook-reported `permission_mode` as secondary text in the session card header when available
- Bidirectional sync: activate CodeIsland's AUTO state when the CLI reports an auto permission mode, and deactivate when the CLI reports a non-auto mode
- Map CLI permission modes (`auto`, `acceptEdits`, `bypassPermissions`) to corresponding `AutoApproveMode` snapshots

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `user-experience`: Session card AUTO indicator now uses yellow color and syncs with CLI permission mode; hook-reported permission mode displayed as secondary metadata

## Impact

- `Sources/CodeIsland/NotchPanelView.swift` — SessionIdentityLine color change and permission mode display
- `Sources/CodeIsland/AppState.swift` — Bidirectional sync logic in handleEvent after reduceEvent
- `Sources/CodeIslandCore/SessionSnapshot.swift` — Reuses existing `permissionMode` field (no changes)
