# Smart Default for Auto-Approve Mode (revised)

## Why

Two code paths in CodeIsland pick which Claude Code `setMode` to send when AUTO mode is activated, and they currently use inconsistent defaults:

1. **Plan card "auto-accept" OptionRow** (`NotchPanelView.swift:1067`) — when the user picks the "accept the plan and start executing" OptionRow for an `ExitPlanMode` `PermissionRequest`, the response is hardcoded to `acceptEdits`:
   ```swift
   let mode = appState.suggestedModeForPendingPlan() ?? "acceptEdits"
   ```
   `acceptEdits` sends `setMode: acceptEdits` + a per-tool `addRules` whitelist. It silently no-ops on any tool not in the whitelist (MCP servers, custom tools, newer tool names). The user thinks they enabled AUTO but the agent is still gated on every unknown tool. Claude Code's own documentation recommends `auto` for "set-and-forget" approval because the native classifier handles every tool call without CodeIsland needing to know which tools exist.

2. **Orange AUTO_APPROVE PixelButton** (`NotchPanelView.swift:1135`) — calls `appState.toggleAutoApprove(sessionId:)`, which eventually calls `AppState.autoApproveInitialResponse()` (`AppState.swift:1575`). That method picks the mode from `SettingsManager.shared.autoApproveMode` (a global setting). If the user picked `addRules` (acceptEdits) globally, the orange button silently no-ops on unknown tools — same problem as the Plan card, just with a different activation path.

The user wants the two surfaces to have **different, intentional defaults**:

- **Plan card "auto-accept" OptionRow**: a **user-selectable global default** in Settings, between `auto` and `acceptEdits`. Default to `auto` (Claude Code's recommendation). The user who wants the old whitelist behavior can pick `acceptEdits`.
- **Orange AUTO_APPROVE PixelButton** (and the long-press ALWAYS gesture that ends up at the same `autoApproveInitialResponse`): **always** `auto` or `bypassPermissions`, never `acceptEdits`. Per-session memory: if the session has previously used `bypassPermissions`, use bypass; else use `auto` (overriding `.addRules` if the user picked that in Settings). The user's global `autoApproveMode` setting is only consulted when the session has no observed history — preserves the user's explicit `auto` / `bypass` / `addRules` choice for new sessions.

## What Changes

- **New setting** in `SettingsView.swift`: a Picker labeled "Plan Auto-Accept Mode" that lets the user choose between `auto` and `acceptEdits`. Default: `auto`. Stored in `UserDefaults` under a new key (e.g., `planAutoAcceptMode`).
- **Plan auto-accept mode selection** in `NotchPanelView.swift:1067`: replace the `?? "acceptEdits"` fallback with a chain: `permission_suggestions` (if present) → **the new Plan Auto-Accept setting** (`auto` or `acceptEdits`) → `"acceptEdits"` (safety net).
- **AUTO_APPROVE button response** in `AppState.swift:autoApproveInitialResponse()`: read the session's `observedPermissionMode` (new field on `SessionSnapshot`). If `bypassPermissions`, return bypass; if `auto`, return auto; else fall back to the user's global `autoApproveMode` setting. **Never** returns `acceptEdits` for the orange button — that mode is the user's whitelist choice and should not silently activate for a user who never picked it.
- **Session state**: add a new field `observedPermissionMode: String?` to `SessionSnapshot` in `CodeIslandCore`. Populated by the reducer from `event.rawJSON["permission_mode"]` on every hook event. Uses a "most permissive" merge rule (`bypassPermissions` > `auto` > `acceptEdits`; never downgrade).
- **No changes to**: the existing `SettingsKey.autoApproveMode` Picker (still controls the orange button's fallback for new sessions, and is still respected as the user's explicit global choice); `AppState.toggleAutoApprove` state machine; `autoApproveModeSnapshot` cleanup; the SessionCard ⏵⵵ indicator.

## Capabilities

### New Capabilities

- `session-permission-mode-history`: a `SessionSnapshot.observedPermissionMode` (or similar) field that records the most permissive `permission_mode` ever observed for the session. Used by the orange AUTO_APPROVE button's smart-default logic to restore `bypassPermissions` for users who previously opted into it.

### Modified Capabilities

- `user-experience`: the "Plan auto-accept uses smart default mode" scenario is replaced with a **setting-driven** scenario (the user picks the default in Settings). Add a new Requirement for the **Plan Auto-Accept setting** in Settings. Keep the "AUTO_APPROVE button uses smart default mode" scenario, but make it explicit that the orange button only ever returns `auto` or `bypassPermissions`.

## Impact

- `Sources/CodeIsland/Settings.swift`: add a new `SettingsKey.planAutoAcceptMode` and `SettingsDefaults.planAutoAcceptMode` (default `auto`). Add a typed accessor on `SettingsManager` that returns `AutoApproveMode` (limited to `.auto` and `.addRules`).
- `Sources/CodeIsland/SettingsView.swift`: add a new Picker section in the existing Settings → Behavior area (or near the existing `auto_approve_mode` Picker) for the new setting.
- `Sources/CodeIslandCore/SessionSnapshot.swift`: add `observedPermissionMode: String?` field. Add `mergeObservedPermissionMode(_:)` mutating method with the rank-based escalate-only rule.
- `Sources/CodeIsland/AppState.swift`:
  - Reducer: when `event.rawJSON["permission_mode"]` is in `{auto, acceptEdits, bypassPermissions}`, call `mergeObservedPermissionMode` after writing `permissionMode`.
  - Add `smartModeForPendingPlan()` helper that consults the new setting.
  - Change `autoApproveInitialResponse()` signature to take an optional `sessionId`, and use the observed mode (or global fallback) to choose `.bypassPermissions` / `.auto` / global (skipping `.addRules`).
- `Sources/CodeIsland/NotchPanelView.swift:1067`: replace `appState.suggestedModeForPendingPlan() ?? "acceptEdits"` with `appState.smartModeForPendingPlan() ?? "acceptEdits"`.
- `Sources/CodeIsland/L10n.swift`: add new localization keys for the new Picker (English + Chinese; other locales inherit English as fallback if not added).
- `Tests/CodeIslandCoreTests/SessionSnapshotTests.swift` (or new file): add tests for `mergeObservedPermissionMode`.
- `CHANGELOG.md`: add `[Unreleased]` entry.

## Out of scope

- Removing the `addRules` (acceptEdits) path — it is still used by:
  - The new Plan Auto-Accept setting (when the user picks `acceptEdits`).
  - The existing `SettingsKey.autoApproveMode` global setting (for backward compatibility with users who picked it).
- Changing `AutoApproveMode` enum (no new modes).
- Changing the `autoApproveModeSnapshot` cleanup logic on AUTO deactivation.
- Changing the SessionCard ⏵⵵ indicator (still driven by `session.permissionMode` from the current event).
