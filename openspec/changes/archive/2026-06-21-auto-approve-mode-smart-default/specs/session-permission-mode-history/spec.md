# Spec — Session Permission Mode History

## ADDED Requirements

### Requirement: Session Records Most Permissive Observed Permission Mode

Each `SessionSnapshot` MUST record the most permissive `permission_mode` value ever observed for that session, as a new field `observedPermissionMode: String?`. The merge rule when a new `permission_mode` arrives is **only escalate, never downgrade**, using the rank: `bypassPermissions` (3) > `auto` (2) > `acceptEdits` (1) > `default` / unset (0). A new value with a higher rank replaces the stored value; a new value with an equal or lower rank is ignored.

#### Scenario: First observation stores the mode

- **WHEN** a hook event arrives with `permission_mode = "auto"` for a session with no prior observation
- **THEN** the session's `observedPermissionMode` MUST be set to `"auto"`

#### Scenario: Higher rank overrides lower rank

- **WHEN** a hook event arrives with `permission_mode = "bypassPermissions"` for a session whose current `observedPermissionMode` is `"auto"`
- **THEN** the session's `observedPermissionMode` MUST be updated to `"bypassPermissions"`

#### Scenario: Lower rank is ignored

- **WHEN** a hook event arrives with `permission_mode = "acceptEdits"` for a session whose current `observedPermissionMode` is `"auto"`
- **THEN** the session's `observedPermissionMode` MUST remain `"auto"`

#### Scenario: Equal rank is ignored

- **WHEN** a hook event arrives with `permission_mode = "auto"` for a session whose current `observedPermissionMode` is `"auto"`
- **THEN** the session's `observedPermissionMode` MUST remain `"auto"` (no change, no event fired)

#### Scenario: Unrecognized mode is ignored

- **WHEN** a hook event arrives with `permission_mode = "plan"` (or any value outside the rank set) for a session
- **THEN** the session's `observedPermissionMode` MUST remain unchanged

#### Scenario: Field is Optional and round-trips through Codable

- **WHEN** a `SessionSnapshot` is encoded and then decoded with `observedPermissionMode` present
- **THEN** the decoded value MUST equal the encoded value
- **WHEN** a `SessionSnapshot` is encoded and decoded without the field (legacy on-disk data)
- **THEN** the decoded `observedPermissionMode` MUST be `nil`

### Requirement: Permission Mode History Persists Across App Restarts

The `observedPermissionMode` field MUST be persisted via the existing `SessionPersistence` round-trip (already in `Sources/CodeIsland/SessionPersistence.swift`) so that a session which used `bypassPermissions` in a prior app launch still has the field populated when re-activated.

#### Scenario: Persisted bypass survives restart

- **WHEN** a session was last seen with `observedPermissionMode = "bypassPermissions"` before app exit
- **AND** the app is relaunched
- **AND** the session is reactivated (e.g. via a new `PermissionRequest` for the same `sessionId`)
- **THEN** the rehydrated `SessionSnapshot` MUST have `observedPermissionMode = "bypassPermissions"`

#### Scenario: New session after restart has nil history

- **WHEN** the app is relaunched
- **AND** a brand-new `PermissionRequest` arrives for a `sessionId` that has no prior persisted state
- **THEN** the new `SessionSnapshot` MUST have `observedPermissionMode = nil`
