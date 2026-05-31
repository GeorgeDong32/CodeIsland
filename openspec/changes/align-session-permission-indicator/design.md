## Context

`SessionIdentityLine` in `NotchPanelView.swift` currently shows a `⏵⏵` indicator gated by `appState.isAutoApproveActive(for: sessionId)` with a fixed yellow color. The existing `session.permissionMode` field (populated from hook payloads via `SessionSnapshot.permissionMode`) is available but not used to drive the indicator's appearance.

## Goals / Non-Goals

**Goals:**
- Render the session card permission indicator based on `session.permissionMode` rather than `appState.isAutoApproveActive(for:)`
- Match Claude Code terminal visual conventions for each permission mode
- Keep the existing click-to-toggle behavior for fast-forward modes

**Non-Goals:**
- Changing AppState sync logic or hook protocol
- Adding a strongly-typed permission-mode enum
- Changing ApprovalBar, YOLO badge, or secondary permission-mode text
- Supporting permission modes beyond those reported by current Claude Code hooks

## Decisions

### 1. Local mapping helper in NotchPanelView

**Choice:** Add a small `PermissionIndicatorConfig` struct and mapping function near `SessionIdentityLine`, not in Core.

**Why:** The mapping is UI presentation logic only. Core already provides `session.permissionMode` as a raw string. Adding an enum in Core would be over-engineering for a single consumer.

**Alternative:** Use a `switch` inline. Rejected because the mapping includes icon, color, and click behavior — three properties that benefit from being co-located.

### 2. Indicator driven by `session.permissionMode`, not `isAutoApproveActive`

**Choice:** Replace `if appState.isAutoApproveActive(for: sessionId)` with `if let config = permissionIndicatorConfig(for: session.permissionMode)`.

**Why:** `permissionMode` is the authoritative source for what mode the CLI is in. `isAutoApproveActive` is already synced from `permissionMode` by AppState, so using `permissionMode` directly avoids an unnecessary indirection and naturally supports `plan` and `default` modes that are not auto-approve states.

### 3. Click behavior scoped to fast-forward modes

**Choice:** Only `auto`, `acceptEdits`, and `bypassPermissions` indicators call `appState.toggleAutoApprove(sessionId:)`.

**Why:** `plan` mode is not an auto-approve mode — clicking a pause icon should not enable auto approve. `default` has no indicator so there is nothing to click.

### 4. Single `Text` for indicator symbol

**Choice:** Use one `Text(config.symbol)` instead of two separate `Text("⏵")`.

**Why:** `plan` uses a single character `⏸`. Using a single `Text` simplifies the layout and makes the mapping consistent.

## Risks / Trade-offs

- **Missing `plan` in hook payloads:** If Claude Code does not report `plan` in `permission_mode`, the `⏸` indicator will not appear. This is acceptable — the UI only shows what the hook provides.
- **Secondary text redundancy:** The existing `permissionMode` secondary text and the new colored indicator both convey mode information. If the UI feels crowded during implementation, the secondary text can be removed.
- **Color contrast:** `#af87fe` (purple) on dark background needs visual verification. May need slight adjustment during implementation.

## Migration Plan

No migration needed. The indicator is a pure UI element. If issues arise, reverting to the previous AUTO-only indicator is a one-line condition change.

## Open Questions

None.
