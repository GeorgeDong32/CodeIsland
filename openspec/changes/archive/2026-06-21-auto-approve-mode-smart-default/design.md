# Design — Smart Default for Auto-Approve Mode (revised)

## Context

Two activation paths in CodeIsland pick a Claude Code `setMode` value when AUTO mode is enabled:

1. **Plan auto-accept** — `NotchPanelView.swift:1067` reads `permission_suggestions` and falls back to `acceptEdits` if absent. `acceptEdits` sends `setMode: acceptEdits` + a per-tool `addRules` whitelist. This is the wrong default: any tool not in the whitelist (MCP servers, custom tools, newer tool names) silently no-ops; the user thinks they enabled AUTO but the agent is still gated. Claude Code's own documentation recommends `auto` for "set-and-forget" approval — the native classifier handles every tool call without CodeIsland needing to know which tools exist.
2. **AUTO_APPROVE button** — `AppState.swift:1575 autoApproveInitialResponse()` reads the global `SettingsKey.autoApproveMode` (`.auto` / `.addRules` / `.bypassPermissions`) and builds the response. If the user picked `addRules` (acceptEdits) globally, the orange button has the same silent-no-op problem as the Plan card.

The user wants the two surfaces to have **different, intentional defaults**:

- **Plan card "auto-accept" OptionRow**: a **user-selectable global default** in Settings, between `auto` and `acceptEdits`. Default: `auto` (Claude Code's recommendation). The user who wants the old whitelist behavior can pick `acceptEdits`.
- **Orange AUTO_APPROVE button** (and the long-press ALWAYS gesture that ends up at the same `autoApproveInitialResponse`): **always** `auto` or `bypassPermissions`, never `acceptEdits`. Per-session memory: if the session has previously used `bypassPermissions`, use bypass; else use `auto` (overriding `.addRules` if the user picked that in Settings). The user's global `autoApproveMode` setting is only consulted when the session has no observed history — preserves the user's explicit `auto` / `bypass` / `addRules` choice for new sessions.

This requires a per-session record of the most permissive `permission_mode` ever observed (for the orange button), and a new Settings Picker (for the Plan card).

## Goals / Non-Goals

**Goals**

- A new "Plan Auto-Accept Mode" Picker in Settings, with two options (`auto` / `acceptEdits`), default `auto`. Persisted in `UserDefaults`.
- The Plan card's auto-accept OptionRow uses the new Picker as its default (after `permission_suggestions`).
- The orange AUTO_APPROVE button always returns `auto` or `bypassPermissions`, never `acceptEdits`.
- Per-session `observedPermissionMode` memory for the orange button's smart default.
- The existing global `SettingsKey.autoApproveMode` Picker is unchanged and is still respected for new sessions with no observed history.

**Non-Goals**

- Removing the `addRules` (acceptEdits) path — still used by:
  - The new Plan Auto-Accept setting (when the user picks `acceptEdits`).
  - The existing `SettingsKey.autoApproveMode` global setting (for backward compatibility).
- Adding new modes to `AutoApproveMode`.
- Changing `autoApproveModeSnapshot` cleanup on AUTO deactivation.
- Changing the SessionCard ⏵⵵ indicator (still driven by `session.permissionMode` from the current event).
- Surfacing the new Picker in places other than Settings (e.g. tooltip on the Plan OptionRow). Out of scope unless the user requests it.

## Decisions

### Decision 1: New field on `SessionSnapshot.observedPermissionMode`

- **What**: Add `public var observedPermissionMode: String?` to `SessionSnapshot` in `CodeIslandCore/SessionSnapshot.swift`. Optional, defaults to `nil`. Backward-compatible (existing on-disk persisted sessions decode with `nil`).
- **Why**: A per-session "highest ever observed" field is the cleanest way to remember prior intent for the orange button. Optional avoids migration friction. Living on `SessionSnapshot` keeps it next to the rest of the session state and automatically benefits from the existing `Codable` round-trip in `SessionPersistence`.
- **Alternatives**:
  - *Reuse `permissionMode` field*: rejected — `permissionMode` is the **current** mode reported by the latest hook event, which is what the SessionCard ⏵⵵ indicator displays. Conflating it with the historical peak would break the indicator (it would show a stale bypass color after the user toggled to default).
  - *Persist a separate dictionary in `UserDefaults`*: rejected — adds a second source of truth for session state, and stale entries need cleanup on session removal.

### Decision 2: Merge rule in `applyEvent` / reducer

- **What**: When the reducer processes a `HookEvent` whose `rawJSON["permission_mode"]` is one of `auto` / `acceptEdits` / `bypassPermissions`, update `observedPermissionMode` using the rule `bypassPermissions` > `auto` > `acceptEdits` (only escalate, never downgrade).
- **Why**: Matches the user's stated intent for the orange button ("if the user ever used bypass, keep using bypass"). Avoids the perverse case where a session that briefly reported `acceptEdits` later in its lifetime forgets it had `bypassPermissions` earlier.
- **Where**: `Sources/CodeIslandCore/SessionSnapshot.swift` `applyEvent` function, in the same block that already updates `permissionMode` from `event.rawJSON["permission_mode"]` (around line 711 and 806).
- **Implementation**:
  ```swift
  if let mode = event.rawJSON["permission_mode"] as? String {
      sessions[sessionId]?.permissionMode = mode
      sessions[sessionId]?.mergeObservedPermissionMode(mode)
  }
  ```
  Where `mergeObservedPermissionMode(_:)` is a `SessionSnapshot` method that:
  ```swift
  public mutating func mergeObservedPermissionMode(_ mode: String) {
      let rank: [String: Int] = ["bypassPermissions": 3, "auto": 2, "acceptEdits": 1]
      let newRank = rank[mode] ?? 0
      let existingRank = rank[observedPermissionMode ?? ""] ?? 0
      if newRank > existingRank { observedPermissionMode = mode }
  }
  ```

### Decision 3: New Plan Auto-Accept Mode setting

- **What**: A new `SettingsKey.planAutoAcceptMode` persisted in `UserDefaults`. The typed accessor returns a `PlanAutoAcceptMode` enum with two cases: `auto` and `acceptEdits`. Default: `auto`. A new Picker in `SettingsView.swift` lets the user choose.
- **Why**: Decoupling from the existing `autoApproveMode` (which has three options including `bypassPermissions`, not relevant for the Plan card) makes the UI and the model clearer. The Plan card never needs `bypassPermissions` — bypass mode is a session-wide decision, not a per-tool decision. The Picker is small and obvious.
- **Where**:
  - `Sources/CodeIsland/Settings.swift`: new `enum PlanAutoAcceptMode: String, CaseIterable { case auto, acceptEdits }`, new `SettingsKey.planAutoAcceptMode`, new `SettingsDefaults.planAutoAcceptMode = PlanAutoAcceptMode.auto.rawValue`, new typed accessor on `SettingsManager`.
  - `Sources/CodeIsland/SettingsView.swift`: new Picker section, ideally placed near the existing `auto_approve_mode` Picker (line 434) for discoverability. New `@AppStorage` private var.
  - `Sources/CodeIsland/L10n.swift`: new localization keys (`plan_auto_accept_mode`, `plan_auto_accept_mode_desc`, `plan_auto_accept_mode_auto`, `plan_auto_accept_mode_acceptEdits`) for English + Chinese at minimum.
- **Enum reuse**: A new `PlanAutoAcceptMode` enum (2 cases) is added. Reusing `AutoApproveMode` would force the user to pick `bypassPermissions` in the Picker, which is meaningless for the Plan card. A separate enum is clearer.

### Decision 4: Plan auto-accept mode selection

- **What**: Replace `let mode = appState.suggestedModeForPendingPlan() ?? "acceptEdits"` (NotchPanelView:1067) with a new `AppState` helper that returns the smart default. The helper returns the first non-nil value in this priority order:
  1. The pending plan's `permission_suggestions` (preserves the explicit Claude Code hint).
  2. The user's `planAutoAcceptMode` setting (`auto` or `acceptEdits`).
  3. `"acceptEdits"` (final safety net if neither of the above is available).
- **Why**: Matches the user's stated intent. The smart default is a **fixed user choice** in Settings, not a per-session dynamic value. The Plan card never sends `bypassPermissions` — that mode is for whole-session AUTO, not for individual Plan accepts.
- **Where**:
  - New method `AppState.smartModeForPendingPlan() -> String?` in `AppState.swift`.
  - `NotchPanelView.swift:1067` updated to call the new helper.

### Decision 5: AUTO_APPROVE button response uses session history, never `addRules`

- **What**: `AppState.autoApproveInitialResponse()` (line 1575) currently reads only `SettingsManager.shared.autoApproveMode`. Update it to:
  1. Read the current session's `observedPermissionMode` (via `activeSessionId` or the queued `event.sessionId`).
  2. If `bypassPermissions`, return the bypass response.
  3. Else if `auto`, return the auto response.
  4. Else fall back to `SettingsManager.shared.autoApproveMode` (existing behavior — preserves the user's global `.addRules` / `.auto` / `.bypassPermissions` choice for new sessions with no observed history).
- **Why**: The orange button is a one-click "let this session run itself" gesture. The user has not picked acceptEdits/whitelist behavior on the orange button path — the global setting is a fallback for the **default AUTO state**, and the smart default overrides it when the session has a higher-history mode. The `addRules` global choice is honored only as the final fallback for new sessions.
- **Where**:
  - `AppState.swift:autoApproveInitialResponse()` needs access to a session id. The static method signature changes from `static func autoApproveInitialResponse() -> Data` to `static func autoApproveInitialResponse(for sessionId: String? = nil) -> Data`. Callers that have a session id pass it; the one global call site (`flushPendingPermissionsForAutoApprove`, line 1433) is updated to pass `sessionId`.
  - The 3 existing response cases (`.auto` / `.addRules` / `.bypassPermissions`) stay unchanged; only the **selection** of which case to use changes.

### Decision 6: Per-session override never silently overrides an explicit user choice

- **What**: The smart default for the orange button is per-session, not a new global mode. The user's global `autoApproveMode` setting is still respected when there is no session history. The smart default **only** kicks in when the session itself has a `bypass` or `auto` history.
- **Why**: A user who picked `.addRules` (acceptEdits) in Settings should not have it silently downgraded to `auto` on the first activation. The smart default overrides the global setting only when the session has its own history. This is the "honor the user's explicit choice" rule.
- **Concrete rule**: `effectiveMode = if observed == "bypassPermissions" → bypassPermissions; else if observed == "auto" → auto; else → globalSetting`. So `acceptEdits` is never selected by the smart default; it is only the global-setting fallback for new sessions.

## Risks / Trade-offs

- **Risk**: The new "Plan Auto-Accept Mode" Picker is a new UI surface and a new `UserDefaults` key. Existing users get the default `auto`, which is a behavior change for users who were happy with the old `acceptEdits` Plan default. → **Mitigation**: a CHANGELOG entry under `[Unreleased]` and a Settings tooltip explaining the choice. No data migration needed (new key with a default).
- **Risk**: For brand-new sessions (no observed history), the orange button uses the user's global `autoApproveMode`. If the user picked `.addRules` globally, they get `acceptEdits` on first activation — same as before. → **Mitigation**: this is intentional — the user explicitly picked `.addRules` globally, and we should honor that for new sessions.
- **Risk**: `observedPermissionMode` accumulates per session; old sessions keep stale values. → **Mitigation**: `SessionPersistence` already drops full sessions on app exit if their underlying CLI is gone, and `removeSession` in `AppState.swift:554-562` cleans up `autoApproveSessionId` for the session on removal. Add `observedPermissionMode` to the cleanup if necessary (it dies with the session anyway, since the field lives on `SessionSnapshot`).
- **Risk**: The two Picker UIs (`auto_approve_mode` and the new `plan_auto_accept_mode`) might confuse users — why are there two? → **Mitigation**: a CHANGELOG entry and a Settings section description explaining "Auto-Approve Mode" is for the AUTO button and "Plan Auto-Accept Mode" is for the Plan card's auto-accept.

## Migration Plan

- No data migration. New `planAutoAcceptMode` UserDefaults key with default `auto`. New `observedPermissionMode` SessionSnapshot field defaults to `nil` (Swift `Codable` default for missing Optional keys).
- No rollback risk. If the smart default or new setting is wrong, deleting the `observedPermissionMode` writes and the new `planAutoAcceptMode` key restores the old behavior.
- Feature flag: not needed. The new behavior is a pure improvement on the same surface; users who don't like it can change the global setting or the new Plan setting.

## Open Questions

- **Q1**: Should the new Plan Auto-Accept Mode Picker go in the same section as the existing `auto_approve_mode` Picker, or in a separate "Plan" section? Will resolve before implementation by reading SettingsView.swift around line 434.
- **Q2**: Should the orange AUTO_APPROVE button show a tooltip with the resolved mode (e.g., "Will use auto mode" / "Will use bypass mode (because you previously used it for this session)")? The user did not ask for this; out of scope unless the user requests it during implementation.
- **Q3**: For `permission_suggestions` containing an `acceptEdits` suggestion from Claude Code, should the smart default for the Plan card still use the new setting, or should the suggestion win? The current design says the suggestion wins (priority 1). If the user wants "always auto" even when Claude Code suggests `acceptEdits`, this would need to change. Will resolve before implementation by asking the user if ambiguous.
