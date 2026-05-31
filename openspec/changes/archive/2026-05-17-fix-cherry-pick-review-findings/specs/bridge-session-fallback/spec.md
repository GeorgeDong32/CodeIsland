## ADDED Requirements

### Requirement: Bridge synthesizes session_id when absent
When a hook event payload does not contain a `session_id` field, the bridge SHALL synthesize one using the format `"<source>-ppid-<resolvedSessionPID>"` based on the resolved source and process ancestry.

#### Scenario: Payload without session_id from known source
- **WHEN** the bridge receives a hook event without `session_id`
- **AND** the source has been inferred or supplied via `--source`
- **THEN** the bridge MUST synthesize `session_id` as `"<source>-ppid-<resolvedSessionPID>"`
- **AND** forward the enriched event to the Unix socket

#### Scenario: Payload without session_id and no source
- **WHEN** the bridge receives a hook event without `session_id`
- **AND** no source can be inferred (neither `--source` flag nor ancestry match)
- **THEN** the bridge MUST exit silently with code 0
- **AND** MUST NOT forward the event

#### Scenario: Sub-agent processes collapse to parent session
- **WHEN** the bridge resolves session_id via ancestry
- **AND** the invoking process is a sub-agent of a known CLI (e.g., Cursor spawning parallel agents)
- **THEN** the synthesized session_id MUST use the root CLI process PID, not the sub-agent PID
- **AND** multiple sub-agents from the same CLI MUST collapse onto a single session card
