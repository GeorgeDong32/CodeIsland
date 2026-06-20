# Spec — Approval Card Actions Always Visible

## ADDED Requirements

### Requirement: Approval Card Primary Actions Are Always Visible

The permission approval card rendered by the notch panel MUST always display the per-event primary action affordances (Allow / Deny for generic tools, Plan approval options for `ExitPlanMode`, and question options for `AskUserQuestion`), regardless of the session's current `permissionMode` value or any internal auto-approve state.

#### Scenario: Banner does not replace buttons when permissionMode is auto

- **WHEN** a `PermissionRequest` event arrives for a session whose `permissionMode` is `auto`
- **THEN** the approval card MUST render the standard Allow / Deny / Always buttons
- **AND** MUST NOT render a status bar that hides or replaces those buttons

#### Scenario: Banner does not replace buttons when permissionMode is bypassPermissions

- **WHEN** a `PermissionRequest` event arrives for a session whose `permissionMode` is `bypassPermissions`
- **THEN** the approval card MUST render the standard Allow / Deny / Always buttons
- **AND** the SessionCard top ⏵⏵ indicator MUST continue to convey the bypass state in the session header (not inside the card)

#### Scenario: Plan approval options are unaffected

- **WHEN** an `ExitPlanMode` `PermissionRequest` event arrives for any session
- **THEN** the approval card MUST render the Plan approval options
- **AND** the AUTO state of the session MUST NOT suppress or replace those options

#### Scenario: AskUserQuestion options are unaffected

- **WHEN** an `AskUserQuestion` `PermissionRequest` event arrives for any session
- **THEN** the approval card MUST render the question and its options
- **AND** the AUTO state of the session MUST NOT suppress or replace the question UI

### Requirement: Session Card Indicator Is the Only Visible AUTO-State Hint

The session-level auto-approve state SHALL be indicated to the user by the SessionCard top ⏵⵵ permission indicator (driven by `session.permissionMode`). The approval card itself MUST NOT contain an AUTO-approve status banner or any other UI element that visually replaces the per-event action affordances.

#### Scenario: No "AUTO APPROVE" literal in approval card

- **WHEN** the approval card body is rendered for any session in any permission mode
- **THEN** the rendered card body MUST NOT contain the literal substring `"AUTO APPROVE"`

#### Scenario: AUTO state is reachable via SessionCard indicator and ALWAYS long-press

- **WHEN** the user wants to deactivate AUTO mode for a session
- **THEN** the user MUST be able to do so either by tapping the SessionCard top ⏵⵵ indicator OR by long-pressing the ALWAYS button for 2 seconds (per `configurable-auto-approve` behavior preserved)
- **AND** the approval card MUST NOT be the only discoverable deactivation control
