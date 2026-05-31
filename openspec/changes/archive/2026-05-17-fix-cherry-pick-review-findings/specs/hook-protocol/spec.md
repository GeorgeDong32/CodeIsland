## MODIFIED Requirements

### Requirement: Bridge validates session_id before forwarding

Hook events from AI tools SHALL be forwarded by a compiled Swift binary (`codeisland-bridge`), not by shell scripts performing string manipulation.

#### Scenario: Bridge validates session_id before forwarding

- **GIVEN** an inbound payload from a hook script
- **WHEN** the bridge inspects the JSON
- **THEN** if `session_id` is missing or empty, the bridge MUST first attempt to synthesize one from the resolved source and process ancestry using `CLIProcessResolver.resolvedSessionPID`
- **AND** if synthesis succeeds, the synthesized `session_id` MUST be forwarded
- **AND** if synthesis fails (no source identified), the bridge MUST exit silently with code 0
- **AND** the event MUST NOT be forwarded without a valid `session_id`

## ADDED Requirements

### Requirement: Drained notification questions receive response
When queued notification questions are drained (on peer disconnect or activity event), the system SHALL resume their continuations with the standard notification response.

#### Scenario: Notification question drained on peer disconnect
- **WHEN** a notification-style question is queued for a session
- **AND** the peer disconnects (bridge process dies)
- **THEN** the question's continuation MUST be resumed with `notificationResponse()`
- **AND** the question MUST be removed from the queue

#### Scenario: Notification question drained on activity event
- **WHEN** a notification-style question is queued for a session
- **AND** the session receives a follow-up activity event that triggers drain
- **THEN** the question's continuation MUST be resumed with `notificationResponse()`
- **AND** the question MUST be removed from the queue

#### Scenario: Permission question drain is unaffected
- **WHEN** a permission-sourced question is queued
- **AND** drain is triggered
- **THEN** the question's continuation MUST be resumed with a deny response
- **AND** this behavior MUST remain unchanged from the current implementation
