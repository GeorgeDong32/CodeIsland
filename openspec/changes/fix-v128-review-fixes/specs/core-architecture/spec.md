## ADDED Requirements

### Requirement: Subagent Channel Key Consistency

The subagent channel key used by the merge path MUST match the `agentId` used in the `mergedSessionIds` redirect path; the system SHALL NOT introduce an alternative key for the same logical subagent.

#### Scenario: Merge write and redirect read use the same key

- **GIVEN** a parent session with `mergedSessionIds[childId] = parentId`
- **WHEN** the redirect path in `handleEvent` rewrites an incoming event for `childId`
- **THEN** the rewritten `agentId` MUST equal `childId` exactly
- **AND** `ensureSubagent` MUST update the existing `sessions[parentId]?.subagents[childId]` entry rather than create a new one with a derived key

#### Scenario: Cleanup eviction finds the same key

- **GIVEN** a parent session with `subagents[childId]`
- **WHEN** the merged-session-id cache eviction check runs
- **THEN** it MUST look up `parent.subagents[childId]`
- **AND** the entry created by the merge path MUST be the same one the eviction check inspects

### Requirement: Merge-Time Queue Drain

The subagent merge path MUST drain any pending permission and question queues of the merged child session before calling `removeSession`, so that in-flight continuations are resumed with the existing deny response payload rather than silently dropped.

#### Scenario: Child with pending permission is drained on merge

- **GIVEN** a child session that has at least one entry in the permission queue
- **WHEN** `applyCursorSubagentMerge` absorbs the child into its parent
- **THEN** the system MUST call `drainPermissions(forSession: childId, reason: "subagentMerge")` before `removeSession`
- **AND** each pending continuation MUST be resumed with `denyResponseData(for: pending.event, message: …)` so the CLI receives a structured deny

#### Scenario: Child with pending question is drained on merge

- **GIVEN** a child session that has at least one entry in the question queue
- **WHEN** `applyCursorSubagentMerge` absorbs the child into its parent
- **THEN** the system MUST call `drainQuestions(forSession: childId, reason: "subagentMerge")` before `removeSession`
- **AND** each pending continuation MUST be resumed with the existing question deny payload

### Requirement: Subagent Fast-Cleanup Respects Active Redirects

`SessionCleanup.performSubagentFastCleanup` MUST NOT remove a subagent entry whose session ID appears as a key in the supplied `mergedSessionIds` map, because such an entry is still being routed-to and is required for the redirect path to land on the correct storage key.

#### Scenario: Cleanup skips merged children

- **GIVEN** a parent session with `subagents[childId]` and `mergedSessionIds[childId] = parentId`
- **WHEN** `performSubagentFastCleanup` runs with the same `mergedSessionIds` map
- **THEN** the entry `subagents[childId]` MUST be preserved
- **AND** subsequent events for `childId` MUST continue to be redirected to the parent until the cache entry is evicted by a later stage

#### Scenario: Non-merged subagents are still cleaned up

- **GIVEN** a parent session with `subagents[unrelatedId]` where `unrelatedId` is not present in `mergedSessionIds`
- **WHEN** `performSubagentFastCleanup` runs past the configured threshold
- **THEN** the entry `subagents[unrelatedId]` MUST be removed (preserving existing fast-cleanup behavior)

### Requirement: JSONL Tailer Offset Invariant

`JSONLTailer` MUST advance `watch.offset` so the next `readFromOffset` call resumes from the byte immediately after the bytes either consumed as complete lines OR skipped by the trailing-fragment cap. The two offset advances (one for the discarded tail, one for the consumed lines) MUST be complementary so that the discarded tail bytes are counted exactly once.

#### Scenario: Trailing-only truncation advances offset by total minus cap

- **GIVEN** a watch where the prefix-overflow branch did NOT run (so `combined.count <= maxPendingFragmentBytes + maxDeltaBytes`) AND `scan.trailingFragment.count > maxPendingFragmentBytes`
- **WHEN** the tailer computes the next offset
- **THEN** the offset MUST equal the previous offset plus `combined.count - maxPendingFragmentBytes`
- **AND** the discarded tail bytes MUST be counted exactly once across both offset advances

#### Scenario: No-trailing-truncation case is unchanged

- **GIVEN** a watch with `pendingFragment.count <= maxPendingFragmentBytes` after `scanLines`
- **WHEN** the tailer advances the offset
- **THEN** the offset MUST equal the previous offset plus `combined.count - scan.trailingFragment.count`
- **AND** the resulting `pendingFragment` MUST equal `scan.trailingFragment`

### Requirement: Question-Queue Caps Use Codex-Aware Deny

`AppState.enforceQuestionQueueCaps` MUST produce deny payloads by calling the shared `denyResponseData(for:message:)` helper so the Codex-specific branch (omitting `suppressOutput`) is honored; the system SHALL NOT inline a `Data(#"…"#)` literal that bypasses that helper.

#### Scenario: Codex question cap uses Codex branch

- **GIVEN** a question whose source is `codex` and which has just exceeded the per-session question cap
- **WHEN** `enforceQuestionQueueCaps` denies the queue
- **THEN** the deny payload MUST be the result of `denyResponseData(for: event, message: …)` for the pending event
- **AND** the payload MUST NOT include `suppressOutput: true`

#### Scenario: Non-Codex question cap uses default branch

- **GIVEN** a question whose source is not `codex` and which has just exceeded the per-session question cap
- **WHEN** `enforceQuestionQueueCaps` denies the queue
- **THEN** the deny payload MUST be the result of `denyResponseData(for: event, message: …)` for the pending event
- **AND** the payload MAY include `suppressOutput: true`

## MODIFIED Requirements

### Requirement: Bounded History Buffers

Per-session history collections (tool history, chat messages) and transcript-tail pending fragments SHALL be capped to a maximum count or size enforced at insertion time to prevent unbounded memory growth. Memory caps MUST hold even when the writer keeps appending without a newline.

#### Scenario: Tool history truncates at cap

- **GIVEN** a session with `ToolHistoryEntry` history at the configured `maxHistory` cap
- **WHEN** a new tool entry is appended via the reducer
- **THEN** the oldest entry MUST be evicted (FIFO ring-buffer semantics)
- **AND** the total count MUST equal `maxHistory`

#### Scenario: Chat history truncates at cap

- **GIVEN** a session with `ChatMessage` history at the configured cap
- **WHEN** a new message is appended
- **THEN** the oldest message MUST be evicted
- **AND** the count MUST not exceed the cap at any point

#### Scenario: JSONL pending fragment truncates at cap

- **GIVEN** a watch whose combined `pendingFragment + appended` exceeds `maxPendingFragmentBytes + maxDeltaBytes`
- **WHEN** the tailer rewinds the prefix
- **THEN** the in-memory fragment MUST be at most `maxPendingFragmentBytes`
- **AND** the on-disk `offset` MUST reflect every byte the tailer has either consumed as a complete line or retained as the (possibly truncated) trailing fragment
