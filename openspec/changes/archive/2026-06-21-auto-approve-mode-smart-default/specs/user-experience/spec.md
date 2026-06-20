# Spec — User Experience Delta

## MODIFIED Requirements

### Requirement: Approval Card Primary Actions Are Always Visible

The permission approval card rendered by the notch panel MUST always display the per-event primary action affordances (Allow / Deny for generic tools, Plan approval options for `ExitPlanMode`, and question options for `AskUserQuestion`), regardless of the session's current `permissionMode` value or any internal auto-approve state.

#### Scenario: Banner does not replace buttons when permissionMode is auto

- **WHEN** a `PermissionRequest` event arrives for a session whose `permissionMode` is `auto`
- **THEN** the approval card MUST render the standard Allow / Deny / Always buttons
- **AND** MUST NOT render a status bar that hides or replaces those buttons

#### Scenario: Banner does not replace buttons when permissionMode is bypassPermissions

- **WHEN** a `PermissionRequest` event arrives for a session whose `permissionMode` is `bypassPermissions`
- **THEN** the approval card MUST render the standard Allow / Deny / Always buttons
- **AND** the SessionCard top ⏵⵵ indicator MUST continue to convey the bypass state in the session header (not inside the card)

#### Scenario: Plan approval options are unaffected

- **WHEN** an `ExitPlanMode` `PermissionRequest` event arrives for any session
- **THEN** the approval card MUST render the Plan approval options
- **AND** the AUTO state of the session MUST NOT suppress or replace those options

#### Scenario: Plan auto-accept uses the user's Plan Auto-Accept Mode setting

- **WHEN** the user picks the "auto-accept" OptionRow for an `ExitPlanMode` `PermissionRequest`
- **THEN** the response sent to Claude Code MUST use a `setMode` value resolved in this priority order:
  1. The pending plan's `permission_suggestions` setMode value (if present).
  2. The user's `SettingsKey.planAutoAcceptMode` setting (either `"auto"` or `"acceptEdits"`).
  3. The string `"acceptEdits"` as the final safety net.
- **AND** the default value of `SettingsKey.planAutoAcceptMode` MUST be `"auto"` (Claude Code's recommended mode).
- **AND** the Plan card MUST NOT use `bypassPermissions` for the auto-accept response (bypass is a session-wide decision, not a per-tool one).

#### Scenario: AskUserQuestion options are unaffected

- **WHEN** an `AskUserQuestion` `PermissionRequest` event arrives for any session
- **THEN** the approval card MUST render the question and its options
- **AND** the AUTO state of the session MUST NOT suppress or replace the question UI

### Requirement: Plan Auto-Accept Mode Setting Exists in Settings

A new setting `SettingsKey.planAutoAcceptMode` SHALL exist in the Settings view, letting the user choose between `auto` and `acceptEdits` for the Plan card's auto-accept response. The setting MUST be persisted in `UserDefaults` and MUST default to `auto`.

#### Scenario: User sees the new Picker in Settings

- **WHEN** the user opens the Settings view
- **THEN** the user MUST see a Picker section labeled "Plan Auto-Accept Mode" with two options: "Auto" and "Accept Edits"
- **AND** the Picker MUST be initialized to the current value of `SettingsKey.planAutoAcceptMode`

#### Scenario: User changes the Picker value

- **WHEN** the user selects "Accept Edits" in the Plan Auto-Accept Mode Picker
- **THEN** `SettingsKey.planAutoAcceptMode` MUST be set to `"acceptEdits"`
- **AND** subsequent Plan auto-accept OptionRow actions MUST use `setMode: acceptEdits` (subject to `permission_suggestions` priority)

#### Scenario: Setting survives app restart

- **WHEN** the user changes `planAutoAcceptMode` to `acceptEdits` and quits the app
- **AND** the user relaunches the app
- **THEN** the Picker MUST still show "Accept Edits" (value persisted via `UserDefaults`)

### Requirement: Session Card Indicator Is the Only Visible AUTO-State Hint

The session-level auto-approve state SHALL be indicated to the user by the SessionCard top ⏵⵵ permission indicator (driven by `session.permissionMode`). The approval card itself MUST NOT contain an AUTO-approve status banner or any other UI element that visually replaces the per-event action affordances.

#### Scenario: No "AUTO APPROVE" literal in approval card

- **WHEN** the approval card body is rendered for any session in any permission mode
- **THEN** the rendered card body MUST NOT contain the literal substring `"AUTO APPROVE"`

#### Scenario: AUTO state is reachable via SessionCard indicator and ALWAYS long-press

- **WHEN** the user wants to deactivate AUTO mode for a session
- **THEN** the user MUST be able to do so either by tapping the SessionCard top ⏵⵵ indicator OR by long-pressing the ALWAYS button for 2 seconds (per `configurable-auto-approve` behavior preserved)
- **AND** the approval card MUST NOT be the only discoverable deactivation control

#### Scenario: AUTO_APPROVE button uses session history, never acceptEdits

- **WHEN** the user taps the orange AUTO_APPROVE PixelButton (or activates AUTO via the long-press ALWAYS gesture) for a session
- **THEN** the `setMode` value sent to Claude Code MUST be resolved in this priority order:
  1. `"bypassPermissions"` if the session's `observedPermissionMode` is `"bypassPermissions"`.
  2. `"auto"` if the session's `observedPermissionMode` is `"auto"`.
  3. The user's global `SettingsKey.autoApproveMode` setting (preserves the user's explicit choice, including `.addRules` / `.bypassPermissions` / `.auto`).
- **AND** the orange button MUST NEVER send `setMode: acceptEdits` for a session whose `observedPermissionMode` is `"auto"` or `"bypassPermissions"` (the smart default overrides the global `.addRules` choice).

#### Scenario: Smart default honors the user's global setting for new sessions

- **WHEN** the user taps the orange AUTO_APPROVE PixelButton for a session with no `observedPermissionMode` history
- **THEN** the `setMode` value sent to Claude Code MUST be the user's global `SettingsKey.autoApproveMode` setting (existing behavior, no change)
