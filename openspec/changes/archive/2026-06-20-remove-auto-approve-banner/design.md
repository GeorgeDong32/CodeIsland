# Design — Remove AUTO APPROVE Banner

## Context

The permission approval card (rendered by `NotchPanelView.swift` inside the notch panel) is the UI surface that shows pending `PermissionRequest` events. It has three states based on `tool`:

- `Bash` / `Edit` / generic tools → `Allow` + `Always` + `Deny` buttons
- `AskUserQuestion` → question + options
- `ExitPlanMode` → Plan-mode approval options

The 4 月 `configurable-auto-approve` change added a fourth state: when `AppState.isAutoApproveActive(for: sessionId)` was true, the entire button row was replaced with a red "⏵⏵ AUTO APPROVE  点击禁用" status bar. The user could tap the bar to deactivate AUTO and bring back the buttons.

5 月 `auto-badge-sync` added the SessionCard top ⏵⏵ indicator driven directly by `session.permissionMode` (with per-mode color/icon). The indicator and the banner now convey the same information, but the indicator is non-blocking. The banner's only remaining purpose is to **block per-tool approval**, which contradicts the principle that users should always be able to override the auto behavior tool-by-tool.

The banner trigger is at `AppState.swift:1010-1029`: every hook event with `permission_mode ∈ {auto, acceptEdits, bypassPermissions}` sets `autoApproveSessionId = sessionId`. Because every event carries `permission_mode`, this fires on every Bash/Edit/Read event, making the banner the dominant UI surface for any user with an `auto` or `bypassPermissions` session.

## Goals / Non-Goals

**Goals**

- Always show the Allow / Deny / Plan / AskUser options in the approval card, regardless of `permissionMode` or `autoApproveSessionId`.
- Keep AUTO-mode behavior intact at the state machine level: `autoApproveSessionId` continues to be set by CLI sync, and `HookServer` continues to emit `setMode: bypassPermissions` on the next `PermissionRequest`.
- Keep the SessionCard top ⏵⏵ indicator working as the only visible AUTO-state hint.
- Minimal change footprint — no behavior change to the auto-approve state machine, just remove the UI that hijacks the button row.

**Non-Goals**

- Removing or refactoring the `autoApproveSessionId` / `autoApproveModeSnapshot` / `PendingAutoCleanup` state machine.
- Changing the long-press ALWAYS 2-second gesture in `SettingsView` or wherever it lives (it stays as the manual entry point to AUTO mode).
- Changing `SettingsKey.autoApproveMode` / per-tool auto-approve toggles.
- Changing the SessionCard top indicator (it remains `permissionMode`-driven, independent of this banner).
- Removing the `click_to_disable` localization key (small string; safe to keep; can clean up later).

## Decisions

### Decision 1: Delete the banner SwiftUI block, keep all backing state

- **What**: Remove `NotchPanelView.swift` lines 1036-1061 (the `if isAutoApproveActive { ... }` block), the `isAutoApproveActive` computed property at lines 972-975, and the view-side `toggleAutoApprove()` at lines 1179-1186.
- **Why**: The banner is the only consumer of `isAutoApproveActive` in the view. `AppState.isAutoApproveActive(for:)` is still needed by `HookServer` for the `setMode` response path (indirectly, via `flushPendingPermissionsForAutoApprove`).
- **Alternatives considered**:
  - *Move the banner to a non-blocking footer* (small "AUTO" pill above buttons): rejected — the SessionCard top ⏵⏵ indicator already does this; adding a second indicator is redundant.
  - *Only hide the banner when there are pending questions or plan approvals*: rejected — that re-creates the "AUTO sometimes blocks, sometimes doesn't" confusion.

### Decision 2: Keep `AppState.autoApproveSessionId` and the sync logic intact

- **What**: `AppState.swift:1010-1029` continues to set `autoApproveSessionId` based on `permission_mode`. `flushPendingPermissionsForAutoApprove` (lines 1419-1448) continues to flush queued permissions. `deactivateAutoApprove` (lines 1380-1390), `toggleAutoApprove` (lines 1392-1417), `removeSession` cleanup (lines 554-562) all stay.
- **Why**: The state is required for the next `PermissionRequest` to be answered with `setMode: bypassPermissions` so the CLI stops sending events. Without it, AUTO mode would degrade to "no UI feedback but still per-tool approve" — silently inconsistent.
- **Why not also remove the sync**: We considered removing the sync too (since the only user-visible effect was the now-removed banner). Rejected: the state is still meaningful for `flushPendingPermissionsForAutoApprove`, and a future per-session "auto-approve in progress" indicator on the SessionCard can reuse the same state without re-introducing the banner.

### Decision 3: No new test fixtures, but add a regression test

- **What**: Add one test in `Tests/CodeIslandTests/NotchPanelViewTests.swift` (or a new `Tests/CodeIslandTests/ApprovalCardContentTests.swift` if the file doesn't fit) that verifies the approval card body does **not** contain the literal "AUTO APPROVE" string. This is a string-content snapshot or direct view-render assertion.
- **Why**: The banner was historically the only place this literal appeared. A regression test catches accidental re-introduction.
- **Why not full view snapshot test**: Existing `NotchPanelViewTests.swift` only tests click-jump animations. Adding a full snapshot would be brittle; a string-content check is sufficient for the regression.

### Decision 4: CHANGELOG entry under the next released version

- **What**: Add a `Fix` entry to `CHANGELOG.md` explaining the banner removal, why, and that AUTO mode is still controllable via the SessionCard top ⏵⏵ indicator and the long-press ALWAYS gesture.
- **Why**: Users upgrading will wonder where the red bar went. A changelog line + a sentence in the description is enough.
- **Version**: The next shipped version (currently main is at 1.2.6; next release likely 1.2.7). Will be added under whichever version this change ships in.

## Risks / Trade-offs

- **Risk**: Users who relied on tapping the red bar to disable AUTO lose a discoverable control. → **Mitigation**: The SessionCard top ⏵⏵ indicator (which has been the per-mode indicator since `auto-badge-sync`) is still tappable for the same effect; the changelog entry will mention this.
- **Risk**: Without the banner, users with `permission_mode = bypassPermissions` may not realize the next permission request will be auto-allowed. → **Mitigation**: Once `bypassPermissions` is set, Claude Code stops sending `PermissionRequest` events entirely, so the user sees no card at all — the absence of cards is the signal. The SessionCard ⏵⏵ red icon is also present.
- **Risk**: The `toggleAutoApprove()` view-side helper may be referenced by other view code (e.g. SessionCard). → **Mitigation**: Grep before removal. If no other call sites, delete. If other call sites exist, keep the helper (it just becomes unused by the approval card).
- **Risk**: The `click_to_disable` localization key becomes orphaned. → **Mitigation**: Acceptable. Removing it is a follow-up cleanup with no functional impact.

## Migration Plan

No data migration. No API change. The state machine in `AppState` is byte-identical; only the SwiftUI block is removed.

Rollback: revert the single commit that removes the banner.

## Open Questions

- **Q1**: Does `toggleAutoApprove()` (view-side, `NotchPanelView.swift:1179-1186`) have any other call sites besides the banner's `onTapGesture`? Will be confirmed via `grep -nE "\.toggleAutoApprove|toggleAutoApprove\(" Sources/CodeIsland/` before removal.
- **Q2**: Does the SessionCard top ⏵⏵ indicator already implement tap-to-disable-auto, so the user has a replacement control? If yes, this change is safe. If no, the changelog must direct users to the long-press ALWAYS gesture in Settings instead. Will be confirmed by reading `NotchPanelView.swift` SessionCard section + `SettingsView.swift` for the long-press handler.
