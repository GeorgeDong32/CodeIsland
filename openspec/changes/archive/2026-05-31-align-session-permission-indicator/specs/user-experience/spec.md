# Delta Spec: user-experience

## Changes

### Session Card Permission Indicator

- **Modified**: The session card indicator is now driven by `session.permissionMode` instead of `appState.isAutoApproveActive(for:)`.
- **Modified**: Icon and color vary by permission mode:
  - `bypassPermissions` → `⏵⏵`, `#ff6666` (red)
  - `auto` → `⏵⏵`, `#ffcc00` (yellow)
  - `acceptEdits` → `⏵⏵`, `#af87fe` (purple)
  - `plan` → `⏸`, `#669998` (teal)
  - `default` → no indicator
- **Modified**: Click-to-toggle-auto-approve behavior is preserved only for fast-forward modes (`auto`, `acceptEdits`, `bypassPermissions`). The `plan` indicator is static.
- **Added**: A local mapping helper (`PermissionIndicatorConfig`) co-locates icon, color, and click-behavior configuration per mode.
