# Remove AUTO APPROVE Banner from Approval Card

## Why

The "⏵⏵ AUTO APPROVE  点击禁用" red banner rendered inside the permission approval card (NotchPanelView.swift lines 1036-1061) was introduced in 4 月 `configurable-auto-approve` to indicate a session was in auto-approve (bypassPermissions) mode, and replaced the Allow/Deny buttons entirely. After 5 月 `auto-badge-sync` aligned the SessionCard top badge with the hook-reported `permission_mode` (yellow ⏵⏵, red ⏵⏵ for bypass, etc.), the banner's "indicate state" job moved to the badge. Today the banner is a pure obstruction: its trigger (`AppState.swift:1010-1029`, any `permission_mode` ∈ {`auto`, `acceptEdits`, `bypassPermissions`} on any hook event) fires on every Bash/Edit/Read event, hides the Allow/Deny buttons, and forces the user to either click the banner to disable AUTO or wait for the queue. Users have reported this blocks legitimate per-tool approval.

## What Changes

- **Delete** the red "AUTO APPROVE" status bar inside the permission approval card (NotchPanelView.swift lines 1036-1061, plus the `isAutoApproveActive` computed property at lines 972-975 and the `toggleAutoApprove()` view-side helper at lines 1179-1186).
- **Keep** `AppState.autoApproveSessionId` / `autoApproveModeSnapshot` / `flushPendingPermissionsForAutoApprove` — they are still consumed by `HookServer` to emit `setMode: bypassPermissions` on the next `PermissionRequest`, and the state machine is still needed for cleanup when the user manually exits auto-approve (e.g. via SettingsView or via the long-press ALWAYS button in older builds).
- **Keep** the SessionCard top ⏵⏵ permission indicator (already driven by `session.permissionMode` since `auto-badge-sync` — independent of this banner).
- **Keep** `SettingsKey.autoApproveMode` / per-tool auto-approve toggles (separate mechanism, unrelated).
- **Add** a new `user-experience` Requirement: approval card content SHALL always include Allow/Deny (or per-tool Plan/AskUser) action affordances; AUTO state SHALL be indicated only by the SessionCard badge, never by hiding the buttons.

## Capabilities

### New Capabilities

- `approval-card-actions-always-visible`: ensure the permission approval card's primary action affordances (Allow, Deny, plus Plan approval and AskUserQuestion options when applicable) are always visible regardless of the session's current `permission_mode` value.

### Modified Capabilities

None. The existing `user-experience` spec has no Requirement for the banner (it was added before spec-driven development covered this area). The new capability above is additive.

## Impact

- **Sources/CodeIsland/NotchPanelView.swift** — delete ~26 lines of banner UI; delete `isAutoApproveActive` computed property; delete view-side `toggleAutoApprove()` helper if no other call site exists.
- **Sources/CodeIsland/L10n.swift** — `click_to_disable` localization key becomes unused; safe to keep (cost is two ~20-byte strings) but can be removed in a follow-up if desired.
- **Sources/CodeIsland/AppState.swift** — no change. `autoApproveSessionId`, `autoApproveModeSnapshot`, `PendingAutoCleanup`, `flushPendingPermissionsForAutoApprove`, `toggleAutoApprove`, `deactivateAutoApprove`, `isAutoApproveActive(for:)` all retained.
- **CHANGELOG.md** — add Fix entry.
- **User experience**: the long-press ALWAYS button (4 月 feature) is now the only way to enter AUTO mode from the UI; the always-on-when-CLI-reports-auto behavior of the banner is replaced by the always-on SessionCard badge.
