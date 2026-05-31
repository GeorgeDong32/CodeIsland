# Design: Auto Approve All - Permission Bypass Toggle

**Date**: 2026-04-19
**Feature**: Auto Approve All permission bypass toggle for CodeIsland

## Problem

When users need to step away from their computer, they want AI coding agents (Claude Code, etc.) to continue working autonomously without requiring manual approval for every permission request. Currently, each permission request shows an approval card that requires user interaction.

## Solution

Add an "Auto Approve All" toggle triggered by long-pressing the ALWAYS button on the permission approval card. When activated, all subsequent PermissionRequest events are silently auto-approved using Claude Code's `setMode: bypassPermissions` hook response.

## Trigger & UX

### Trigger mechanism
- **Long press** the ALWAYS button for **2 seconds** to toggle auto-approve on/off
- ALWAYS button shows a small ⚡ icon to hint at the feature
- **Hover tooltip** on ALWAYS: "Long press 2s to enable auto approve"

### Visual states

**Normal (off)**:
- ALWAYS button: blue background, text "ALWAYS ⚡" (dim ⚡)
- Approval cards appear normally

**Auto Approve (on)**:
- ALWAYS area: changes to red "AUTO ⚡" with red glow border
- No more approval cards popup — PermissionRequests are silently approved
- SessionCard displays red ⚡ badge next to session name + "AUTO" tag

### Status visibility
- **SessionCard**: Red ⚡ icon after session name + "AUTO" tag with red border background
- **Approval card area**: Shows "AUTO APPROVE enabled" status bar instead of approval buttons
- **Sound feedback**: Play activation/deactivation sound on toggle

### Session lifecycle
- Auto-approve resets to **off** when session ends
- User can also toggle off via long press, or Claude Code's Shift+Tab

## Technical Design

### Implementation path: `setMode: bypassPermissions`

When auto-approve is activated, send this response to the next PermissionRequest:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedPermissions": [{
        "type": "setMode",
        "mode": "bypassPermissions",
        "destination": "session"
      }]
    }
  }
}
```

This switches Claude Code to bypassPermissions mode. After this, Claude Code stops sending PermissionRequest events entirely — it handles permissions internally.

**Prerequisite**: Session must support bypassPermissions (started with `--allow-dangerously-skip-permissions`). If not supported, the `setMode` is a no-op per Claude Code docs. Actual behavior to be validated through testing.

### Fallback path (if setMode is no-op)
If `setMode` doesn't work (session not started with enabling flag):
- Auto-approve all incoming PermissionRequests at HookServer level
- Respond with `behavior: "allow"` + `updatedPermissions` addRules per tool
- This is functionally equivalent but doesn't show Claude Code's native "bypass permissions on" status

### Components to modify

**AppState** (`Sources/CodeIsland/AppState.swift`):
- Add `@Published var autoApproveSessionId: String?` — tracks which session has auto-approve on
- Add `func toggleAutoApprove(sessionId: String)`
- Add `func isAutoApproveActive(for sessionId: String) -> Bool`
- Reset `autoApproveSessionId` to nil on session end

**HookServer** (`Sources/CodeIsland/HookServer.swift`):
- In `routePermission`, check `appState.autoApproveSessionId`
- If active for the requesting session, respond with `setMode: bypassPermissions` instead of queueing the permission

**ApprovalBar** (`Sources/CodeIsland/NotchPanelView.swift`):
- ALWAYS button: add `.onLongPressGesture(minimumDuration: 2)` to trigger toggle
- Add `@State private var isLongPressing = false` for visual feedback during press
- When auto-approve is active, show "AUTO APPROVE enabled" status bar instead of buttons
- Pass `isAutoApproveActive` and `onToggleAutoApprove` as parameters or read from appState

**PixelButton** (`Sources/CodeIsland/NotchPanelView.swift`):
- Support long press gesture parameter (optional callback)
- Support active state styling (different bg/border/color)

**SessionCard** (`Sources/CodeIsland/NotchPanelView.swift`):
- If session has auto-approve active, show red ⚡ badge after session name
- Show "AUTO" tag with red background

### State flow

```
User long-presses ALWAYS (2s)
  → ApprovalBar calls onToggleAutoApprove()
  → AppState sets autoApproveSessionId = currentSessionId
  → Sound feedback (activation)
  → UI updates: ALWAYS → AUTO ⚡, SessionCard shows ⚡

Next PermissionRequest arrives (HookServer)
  → Checks autoApproveSessionId == event.sessionId
  → Responds with setMode: bypassPermissions
  → Does NOT queue permission (no UI shown)

Claude Code receives setMode
  → Switches to bypassPermissions
  → Stops sending PermissionRequest events
  → Agent continues autonomously

User long-presses AUTO ⚡ to disable
  → OR session ends
  → AppState clears autoApproveSessionId
  → Sound feedback (deactivation)
  → UI reverts to normal
```

### Files to modify

| File | Changes |
|------|---------|
| `Sources/CodeIsland/AppState.swift` | autoApproveSessionId state + toggle + reset |
| `Sources/CodeIsland/HookServer.swift` | Auto-approve response in routePermission |
| `Sources/CodeIsland/NotchPanelView.swift` | ApprovalBar long press + status bar + SessionCard badge |

## Edge cases

- **No session context**: Toggle disabled (no ALWAYS button shown)
- **Remote session**: Toggle disabled (no terminal to control)
- **Multiple sessions**: Only one session can have auto-approve at a time. Activating on session B while session A is active will deactivate session A first.
- **Queue of permissions**: If multiple permissions are queued, activating auto-approve should clear the queue by auto-approving all pending
- **Session end**: Must reset autoApproveSessionId to prevent state leak
- **App restart**: Auto-approve state is session-scoped, not persisted

## Verification

1. Long press ALWAYS → button turns red "AUTO ⚡"
2. SessionCard shows red ⚡ badge
3. No more approval cards appear
4. Claude Code shows "bypass permissions on" status
5. Long press AUTO → reverts to normal
6. Shift+Tab in Claude Code also reverts
7. Session end resets state
8. Sound plays on toggle
