## ADDED Requirements

### Requirement: Post-boundary upstream hook fixes are cherry-picked without regressing local bridge behavior

The system SHALL import selected upstream hook and approval fixes that landed after local commit `c41e7f8` while preserving local post-boundary bridge/session fixes.

#### Scenario: AskUserQuestion payload remains available in PermissionRequest flow
- **WHEN** a `PermissionRequest` is generated for an `AskUserQuestion` tool interaction
- **THEN** the payload needed to render or answer the original question MUST remain available through the permission flow
- **AND** the implementation MUST follow the documented Claude Code `AskUserQuestion` and `PermissionRequest` input/output semantics from the official hooks documentation

#### Scenario: Hook response completion does not hang
- **WHEN** a flat hook event or IDE-originated hook event requires a response completion path
- **THEN** the bridge and app MUST complete the response according to the event type
- **AND** non-permission notification questions MUST still resume their continuation instead of hanging indefinitely

#### Scenario: Remote opencode identity is preserved
- **WHEN** an opencode session originates from a remote host or remote-forwarded hook path
- **THEN** the stored session identity MUST preserve the remote host identity
- **AND** it MUST NOT collapse into a local-only source or session identifier

#### Scenario: Codex hook and remote approval fixes preserve local auto behavior
- **WHEN** Codex `PermissionRequest` or related approval events are processed
- **THEN** the synced behavior MUST respect the official Codex hooks schema for `tool_name`, `tool_input`, and `decision.behavior`
- **AND** it MUST NOT remove local support for session-scoped or persisted permission updates already present in main

### Requirement: Protected local resolver fixes survive cherry-pick conflict resolution

Cherry-picking upstream hook changes SHALL NOT regress the local resolver and bridge fixes committed after `c41e7f8`.

#### Scenario: Session ID fallback remains active
- **WHEN** an AI CLI provider does not provide a stable `session_id`
- **THEN** the bridge MUST still synthesize or preserve a stable fallback session identity for supported providers
- **AND** this behavior MUST remain compatible with local Cursor, Trae, Codex, Gemini, and Qoder session grouping fixes

#### Scenario: Node-based CLI detection still uses argv inspection
- **WHEN** a supported CLI is launched through a `node` executable rather than a direct CLI binary
- **THEN** process resolution MUST inspect argv data to identify npm-installed Codex, Gemini, and Qoder CLI invocations
- **AND** upstream hook sync changes MUST NOT remove this argv-based detection path
