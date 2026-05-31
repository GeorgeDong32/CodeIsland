## Why

The session card AUTO indicator (⏵⏵) currently uses a single yellow color regardless of which permission mode the CLI is actually in. Users expect the indicator to visually match what they see in the Claude Code terminal — different colors for different permission modes, a pause icon for plan mode, and no indicator for default mode.

## What Changes

- Replace the single AUTO-only indicator with a permission-mode-driven indicator in `SessionIdentityLine`
- Map `bypassPermissions` → `⏵⏵` in `#ff6666` (red)
- Map `auto` → `⏵⏵` in `#ffcc00` (yellow, current color)
- Map `acceptEdits` → `⏵⏵` in `#af87fe` (purple)
- Map `plan` → `⏸` in `#669998` (teal)
- Map `default` → no indicator
- Preserve click-to-toggle-auto-approve behavior for fast-forward modes only (`auto`, `acceptEdits`, `bypassPermissions`)
- `plan` indicator is static display only — clicking it does not toggle auto approve

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `user-experience`: Session card permission indicator now renders icon and color based on hook-reported `permission_mode` instead of local AUTO state only

## Impact

- `Sources/CodeIsland/NotchPanelView.swift` — Replace AUTO-gated indicator with permission-mode mapping in `SessionIdentityLine`
- `Sources/CodeIsland/AppState.swift` — No changes; existing permission-mode sync in `handleEvent` is reused
- `Sources/CodeIslandCore/SessionSnapshot.swift` — No changes; `permissionMode` field is reused
