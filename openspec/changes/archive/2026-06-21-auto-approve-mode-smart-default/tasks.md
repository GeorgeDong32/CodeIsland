# Tasks — Smart Default for Auto-Approve Mode (revised)

## 1. Confirm Baseline

- [x] 1.1 Verify `swift test` baseline is green (all 284 tests passing) before any code change.
- [x] 1.2 Read `AppState.swift:1575-1616` (`autoApproveInitialResponse`) and `NotchPanelView.swift:1066-1069` (Plan auto-accept hardcoded `acceptEdits` fallback) to confirm starting point.
- [x] 1.3 Read `Sources/CodeIsland/SettingsView.swift:430-445` (the existing `auto_approve_mode` Picker) to find the right place to insert the new "Plan Auto-Accept Mode" Picker.
- [x] 1.4 Read `Sources/CodeIsland/L10n.swift:120-135` and `L10n.swift:399-410` (English + Chinese `auto_approve_mode` keys) to use as a template for the new localization keys.

## 2. Add `observedPermissionMode` to SessionSnapshot

- [x] 2.1 Add `public var observedPermissionMode: String?` to `Sources/CodeIslandCore/SessionSnapshot.swift` (Optional, defaults to nil, in the section alongside `permissionMode: String?` around line 51).
- [x] 2.2 Add `public mutating func mergeObservedPermissionMode(_ mode: String)` on `SessionSnapshot` with the rank-based escalate-only logic:
  - `bypassPermissions` (3) > `auto` (2) > `acceptEdits` (1) > unknown/empty (0)
  - only writes if new rank > existing rank
- [x] 2.3 In `applyEvent` (line 711 and 806 of `SessionSnapshot.swift`), after `sessions[sessionId]?.permissionMode = mode`, add `sessions[sessionId]?.mergeObservedPermissionMode(mode)`.
- [x] 2.4 Verify `SessionPersistence.swift` already round-trips all `SessionSnapshot` fields (Codable). No changes needed since `observedPermissionMode` is Optional and defaults to nil.

## 3. Add Core Tests for `mergeObservedPermissionMode`

- [x] 3.1 In `Tests/CodeIslandCoreTests/SessionSnapshotTests.swift` (or create the file if absent), add tests:
  - `testObservedPermissionModeStoresFirstValue`
  - `testObservedPermissionModeEscalatesAutoToBypass`
  - `testObservedPermissionModeDoesNotDowngradeBypassToAuto`
  - `testObservedPermissionModeIgnoresUnrecognizedValue`
  - `testObservedPermissionModeRoundTripsThroughCodable`
  - `testObservedPermissionModeDefaultsToNilForLegacyData`
- [x] 3.2 Run `swift test` for the new tests in isolation, expect 6 new tests passing on top of the 284 baseline.

## 4. Add Plan Auto-Accept Mode Setting

- [x] 4.1 In `Sources/CodeIsland/Settings.swift`, add a new enum near `AutoApproveMode` (line 34):
  ```swift
  enum PlanAutoAcceptMode: String, CaseIterable, Identifiable {
      case auto = "auto"
      case acceptEdits = "acceptEdits"
      var id: String { rawValue }
  }
  ```
- [x] 4.2 In `Sources/CodeIsland/Settings.swift`, add:
  - `SettingsKey.planAutoAcceptMode = "planAutoAcceptMode"`
  - `SettingsDefaults.planAutoAcceptMode = PlanAutoAcceptMode.auto.rawValue`
  - Add `planAutoAcceptMode` to the `register` dictionary around line 223.
  - Add a typed accessor on `SettingsManager` near the existing `autoApproveMode` accessor (line 361): `var planAutoAcceptMode: PlanAutoAcceptMode` (get/set via UserDefaults).
- [x] 4.3 In `Sources/CodeIsland/SettingsView.swift`, add a new Picker section near the existing `auto_approve_mode` Picker (around line 434):
  - `@AppStorage(SettingsKey.planAutoAcceptMode) private var planAutoAcceptMode: String = SettingsDefaults.planAutoAcceptMode`
  - A new `Section` with header "Plan Auto-Accept Mode" and description text, a Picker bound to `$planAutoAcceptMode` iterating `PlanAutoAcceptMode.allCases` and using localized labels.
- [x] 4.4 In `Sources/CodeIsland/L10n.swift`, add new localization keys (English + Chinese at minimum):
  - `plan_auto_accept_mode` (label)
  - `plan_auto_accept_mode_desc` (description)
  - `plan_auto_accept_mode_auto` (option label)
  - `plan_auto_accept_mode_acceptEdits` (option label)
  - Turkish / Japanese / Korean fallback: skip these locales for now (English is the fallback per Constitution Principle VII).
- [x] 4.5 Run `swift test` to confirm no regression.

## 5. Wire Setting into Plan Auto-Accept

- [x] 5.1 In `Sources/CodeIsland/AppState.swift`, add a new method:
  ```swift
  /// Resolve the setMode value to send when the user picks the Plan auto-accept OptionRow.
  /// Priority:
  /// 1. permission_suggestions (preserves Claude Code's explicit hint)
  /// 2. SettingsManager.shared.planAutoAcceptMode.rawValue ("auto" or "acceptEdits")
  /// 3. "acceptEdits" as the final safety net
  func smartModeForPendingPlan() -> String? {
      if let suggested = suggestedModeForPendingPlan() { return suggested }
      return SettingsManager.shared.planAutoAcceptMode.rawValue
  }
  ```
- [x] 5.2 In `Sources/CodeIsland/NotchPanelView.swift:1067`, replace `appState.suggestedModeForPendingPlan() ?? "acceptEdits"` with `appState.smartModeForPendingPlan() ?? "acceptEdits"`.
- [x] 5.3 Run `swift test` to confirm no regression.

## 6. Wire Smart Default into AUTO_APPROVE Button

- [x] 6.1 In `Sources/CodeIsland/AppState.swift`, change `static func autoApproveInitialResponse() -> Data` to `static func autoApproveInitialResponse(for sessionId: String? = nil) -> Data`. Inside, before reading `SettingsManager.shared.autoApproveMode`:
  ```swift
  // Smart default: bypassPermissions > auto, else honor the user's global setting.
  // acceptEdits (global .addRules) is only the fallback for new sessions with no observed history.
  let observed = sessionId.flatMap { appState?.sessions[$0]?.observedPermissionMode }
  let effectiveMode: AutoApproveMode = {
      switch observed {
      case "bypassPermissions": return .bypassPermissions
      case "auto": return .auto
      default: return SettingsManager.shared.autoApproveMode
      }
  }()
  ```
- [x] 6.2 Update the single call site `flushPendingPermissionsForAutoApprove` (line 1433) to pass `sessionId: sessionId`.
- [x] 6.3 Run `swift test` to confirm no regression.

## 7. Add Tests for Smart-Default Resolution

- [x] 7.1 Add a unit test for `smartModeForPendingPlan()`:
  - `testSmartModeReturnsPermissionSuggestionsWhenPresent` (suggestions win over setting)
  - `testSmartModeReturnsPlanSettingWhenNoSuggestions` (new-session case: returns the setting, e.g. `"auto"`)
  - `testSmartModeFallsBackToAcceptEditsWhenNoPermissionQueue` (safety net)
- [x] 7.2 Add a unit test for `autoApproveInitialResponse(for:)`:
  - `testInitialResponseUsesBypassWhenSessionObservedBypass`
  - `testInitialResponseUsesAutoWhenSessionObservedAuto` (overrides global .addRules)
  - `testInitialResponseFallsBackToGlobalSettingForNewSession` (no observed history)
  - `testInitialResponseFallsBackToGlobalAddRulesWhenObservedIsAcceptEdits` (the user picked .addRules in Settings — do not override)
- [x] 7.3 Run `swift test` and expect 7 new tests passing on top of the previous 290.

## 8. CHANGELOG and Documentation

- [x] 8.1 Add a `### Fix` entry to `CHANGELOG.md` under `[Unreleased]` describing:
  - New "Plan Auto-Accept Mode" setting in Settings, default `auto`.
  - Plan card's auto-accept OptionRow now uses the new setting.
  - Orange AUTO_APPROVE button always uses `auto` or `bypassPermissions` (per-session smart default).
  - English + Chinese sections.

## 9. Build and Manual Verification

- [x] 9.1 Build: `./build.sh` exits 0, bundle verification passes.
- [ ] 9.2 Launch: `open .build/release/CodeIsland.app` starts the app.
- [ ] 9.3 Verify: open Settings → "Plan Auto-Accept Mode" Picker is visible with "Auto" selected by default. Switch to "Accept Edits", verify persistence after app restart.
- [ ] 9.4 Verify: trigger a Plan `PermissionRequest` for a fresh session → response uses `setMode: auto` (matches the new setting default).
- [ ] 9.5 Verify: change the setting to "Accept Edits", trigger a Plan `PermissionRequest` → response uses `setMode: acceptEdits`.
- [ ] 9.6 Verify: in a session where the user previously enabled bypass, trigger a new Plan `PermissionRequest` → response uses `setMode: bypassPermissions` (Plan setting is bypassed only when `permission_suggestions` is present).
- [ ] 9.7 Verify: tap the orange AUTO_APPROVE button on a brand-new session → response uses the user's global `autoApproveMode` setting (no change from old behavior for new sessions).
- [ ] 9.8 Verify: after activating bypass in a session, deactivate via SessionCard ⏵⏵, then re-tap orange AUTO_APPROVE → response uses `bypassPermissions` (observed history persists across deactivation).
- [ ] 9.9 Verify: pick `.addRules` in the global `autoApproveMode` setting, activate AUTO via the orange button on a session that has previously used `auto` → response uses `setMode: auto` (smart default overrides global `.addRules`).
