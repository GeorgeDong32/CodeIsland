# Delta Spec: user-experience

## Changes

### Session Card AUTO Indicator

- **Modified**: AUTO ⏵⏵ indicator color changed from `Color(red: 1.0, green: 0.27, blue: 0.27)` (red) to `Color(red: 1.0, green: 0.8, blue: 0.0)` (yellow, #FFCC00)

### Permission Mode Display

- **Added**: Hook-reported `permission_mode` displayed as secondary text in `SessionIdentityLine` when `session.permissionMode` is non-nil and non-empty
  - Font: `sessionFontSize - 2`, medium weight, monospaced
  - Color: `sessionColor.opacity(0.5)` (secondary)
  - `.lineLimit(1)` and `.truncationMode(.tail)` for overflow safety

### AUTO State Synchronization

- **Added**: Bidirectional sync between CLI `permission_mode` and CodeIsland `autoApproveSessionId`
  - When `permissionMode` ∈ {`auto`, `acceptEdits`, `bypassPermissions`}: activate AUTO for that session
  - When `permissionMode` is a non-auto value and session has active AUTO: deactivate AUTO
  - Mode mapping: `bypassPermissions` → `.bypassPermissions`, `acceptEdits` → `.addRules`, `auto` → `.auto`
