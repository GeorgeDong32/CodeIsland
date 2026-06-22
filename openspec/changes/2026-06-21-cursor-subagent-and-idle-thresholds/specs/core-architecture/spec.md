# Spec — Core Architecture Delta

## MODIFIED Requirements

### Requirement: Session Lifecycle Cleanup Phases

The `AppState.cleanupIdleSessions()` function SHALL execute a series of well-ordered cleanup phases on a 3-second timer. Each phase SHALL have a single, narrow responsibility and SHALL be implemented to short-circuit gracefully when its trigger condition is absent. This requirement is EXTENDED by the new phases added for transcript-staleness interrupt detection (phase 7) and subagent fast cleanup (phase 6).

#### Scenario: Subagent entries older than the configured threshold are removed (PHASE 6)

- **GIVEN** a session `parent` with a `subagents` dictionary containing `SubagentState` entries
- **AND** the configured `subagentCleanupSeconds` from `SettingsManager` is greater than `0`
- **WHEN** one or more subagent entries have `status == .idle` AND `lastActivity` is older than `subagentCleanupSeconds` ago
- **THEN** on the next `cleanupIdleSessions()` invocation those entries SHALL be removed from `parent.subagents`
- **AND** the `+N Sub` badge count rendered in the UI SHALL decrement accordingly

#### Scenario: Subagent fast cleanup is disabled by the `0` setting

- **GIVEN** a session `parent` with stale `.idle` subagent entries
- **AND** `SettingsManager.subagentCleanupSeconds == 0`
- **WHEN** `cleanupIdleSessions()` runs
- **THEN** the subagent fast cleanup phase SHALL be a no-op
- **AND** no entries SHALL be removed regardless of staleness

#### Scenario: Running subagents are never removed by the fast cleanup phase

- **GIVEN** a subagent entry with `status == .running` and an old `lastActivity`
- **WHEN** `cleanupIdleSessions()` runs
- **THEN** the entry SHALL NOT be removed by the subagent fast cleanup phase
- **AND** a separate phase (the existing process-monitor liveness sweep) is responsible for handling genuinely-hung running subagents

#### Scenario: Active sessions with a stale transcript are flipped to idle and marked interrupted (PHASE 7)

- **GIVEN** a session with `transcriptPath` set, `status` in `{running, processing}`, and `isRemote == false`
- **AND** the configured `transcriptStaleNoToolSeconds` (for `.processing`) or `transcriptStaleWithToolSeconds` (for `.running`) from `SettingsManager` is greater than `0`
- **WHEN** the transcript file at `transcriptPath` has a `.modificationDate` older than the applicable threshold
- **AND** the session's `lastActivity` is also older than the applicable threshold
- **THEN** on the next `cleanupIdleSessions()` invocation the session's `status` SHALL be set to `.idle`
- **AND** `interrupted` SHALL be set to `true`
- **AND** `currentTool` and `toolDescription` SHALL be cleared

#### Scenario: Transcript staleness requires BOTH mtime and lastActivity to be stale

- **GIVEN** a session with `transcriptPath` set and `status == .running`
- **AND** the transcript `mtime` is older than the configured threshold
- **AND** the session's `lastActivity` is WITHIN the configured threshold (e.g. a hook event updated it 10s ago)
- **WHEN** `cleanupIdleSessions()` runs
- **THEN** the session SHALL NOT be flipped to idle
- **AND** the long-running tool call (which updated `lastActivity` via its own hook event) SHALL be preserved as in-progress

#### Scenario: Transcript staleness is disabled when both thresholds are 0

- **GIVEN** a session with `transcriptPath` set and a stale `mtime`
- **AND** both `transcriptStaleNoToolSeconds == 0` AND `transcriptStaleWithToolSeconds == 0`
- **WHEN** `cleanupIdleSessions()` runs
- **THEN** the transcript staleness phase SHALL be a no-op
- **AND** the session SHALL remain in its current status

#### Scenario: Missing transcript file is treated as infinitely stale

- **GIVEN** a session with `transcriptPath` set to a path that does not exist on disk
- **WHEN** the transcript staleness phase reads `.modificationDate`
- **THEN** the read error SHALL be caught and the file SHALL be treated as having `.modificationDate == .distantPast`
- **AND** the phase SHALL proceed with the staleness check (which will trip if other conditions are met)

### Requirement: Reducer Source-Aware Behavior for Stop Events

The `SessionSnapshot.reduceEvent` function SHALL treat `Stop` events differently based on the event's source, because different CLIs use different vocabularies and trigger conditions for `Stop`. This requirement extends the existing `Stop` handling with a Cursor-specific branch that bypasses the completion card and removes the session immediately.

#### Scenario: Cursor `Stop` with interrupt `stop_reason` removes the session

- **GIVEN** a session whose `source` is `cursor` or `cursor-cli`
- **WHEN** a `Stop` event arrives with `rawJSON["stop_reason"]` equal to `"user"` or `"interrupted"`
- **THEN** the reducer SHALL append `.removeSession(sessionId:)` to the returned effects
- **AND** SHALL NOT append `.enqueueCompletion(sessionId:)`
- **AND** SHALL set `interrupted = true`, `status = .idle`, and clear `currentTool` / `toolDescription` (matching the existing Stop pre-removal cleanup)
- **AND** the last assistant message (if any) SHALL be captured into `lastAssistantMessage` and `recentMessages` before the session is removed (so the user can still see it briefly in the completion card before the surface collapses)

#### Scenario: Cursor `Stop` with non-interrupt `stop_reason` enqueues completion

- **GIVEN** a session whose `source` is `cursor` or `cursor-cli`
- **WHEN** a `Stop` event arrives with `rawJSON["stop_reason"]` equal to `"end_turn"` or any value other than `"user"` / `"interrupted"`
- **THEN** the reducer SHALL append `.enqueueCompletion(sessionId:)` to the returned effects
- **AND** the session SHALL be preserved in `appState.sessions` (subject to the existing `sessionTimeout` eviction)

#### Scenario: Non-Cursor `Stop` events are unaffected

- **GIVEN** a session whose `source` is `claude`, `codex`, `gemini`, `trae`, `traecn`, `codebuddy`, `codybuddycn`, `qoder`, `qoder-cli`, `droid`, `opencode`, `antigravity`, `workbuddy`, `hermes`, `qwen`, `kimi`, or `cline`
- **WHEN** a `Stop` event arrives (regardless of `stop_reason` value)
- **THEN** the reducer SHALL append `.enqueueCompletion(sessionId:)` to the returned effects
- **AND** the session SHALL NOT be removed by this code path
- **AND** the existing behavior of capturing `lastAssistantMessage` and `lastUserPrompt` SHALL be preserved

#### Scenario: Claude Code `Stop` has no `stop_reason` field

- **GIVEN** a session whose `source` is `claude`
- **WHEN** a `Stop` event arrives (per [Claude Code's hooks reference](https://code.claude.com/docs/en/hooks-guide), the payload contains only `session_id`, `transcript_path`, `stop_hook_active`, `cwd`)
- **THEN** `rawJSON["stop_reason"]` is absent
- **AND** the reducer's `stopReason` local variable defaults to `""`
- **AND** the Cursor interrupt condition naturally evaluates to `false` (defense in depth with the source whitelist)

### Requirement: CWD-Based Subagent Merge for IDE-Family CLIs

`AppState` SHALL perform a post-hoc reconciliation (`applyCursorSubagentMerge()`) after each hook event is processed, grouping existing sessions by `(source, cwd, terminal_id)` and merging child sessions into the parent's `subagents` dictionary. This follows the same pattern as `applyCodexSubsessionModeToKnownSessions` for Codex. This requirement is NEW.

#### Scenario: Child sessions in same workspace are merged into the parent

- **GIVEN** two or more sessions in `appState.sessions` with `source == "cursor"`, the same `cwd`, and at least one matching terminal identifier (any of `termBundleId`, `itermSessionId`, `ttyPath`, `tmuxPane`, `cmuxSurfaceId`)
- **AND** the child's `startTime` is within 60 seconds of the parent's `startTime`
- **WHEN** `applyCursorSubagentMerge()` runs (after `reduceEvent` returns)
- **THEN** the child session SHALL be removed from `sessions` via `removeSession`
- **AND** a `SubagentState` entry SHALL be created in the parent's `subagents[childSessionId]` with the child's status, currentTool, toolDescription, and lastActivity
- **AND** the parent's status SHALL be updated to `.running` with `currentTool = "Agent"` if not in a waiting state

#### Scenario: Merge is skipped when the gap exceeds 60 seconds

- **GIVEN** a parent session created at `T0` and a child session created at `T0 + 120s` (same cwd/terminal/source)
- **WHEN** `applyCursorSubagentMerge()` runs
- **THEN** both sessions SHALL remain independent in `sessions`
- **AND** no `SubagentState` entries SHALL be created

#### Scenario: Merge is skipped when no terminal identifier matches

- **GIVEN** two sessions with the same `source` and `cwd` but different terminal identifiers (e.g. one in iTerm, one in Terminal.app)
- **WHEN** `applyCursorSubagentMerge()` runs
- **THEN** both sessions SHALL remain independent
- **AND** no merge SHALL occur

#### Scenario: Merge is skipped for non-whitelisted sources

- **GIVEN** two sessions with `source == "claude"` and the same cwd/terminal
- **WHEN** `applyCursorSubagentMerge()` runs
- **THEN** no merge SHALL occur (whitelist does not include `"claude"`)
- **AND** Claude Code's existing `agent_id`-based subagent routing SHALL handle the events as before

#### Scenario: Child session ID becomes the subagent key

- **GIVEN** a child session with `sessionId == "cursor-ppid-12345"`
- **WHEN** the child is merged into the parent
- **THEN** the parent's `subagents` dictionary SHALL contain the key `"cursor-ppid-12345"`
- **AND** the `SubagentState.agentId` SHALL be `"cursor-ppid-12345"` (the child's original session ID, no synthetic prefix needed)

### Requirement: Cleanup Phases are Additive and Non-Destructive

New cleanup phases MUST NOT remove or replace existing phase behavior. Phases 6 and 7 SHALL be no-ops when their respective thresholds are `0`. The existing hard-coded 180s/300s stuck-session thresholds in phase 2 SHALL be retained as a safety net for sessions without `transcriptPath`.

#### Scenario: Legacy behavior is preserved for sessions without transcriptPath

- **GIVEN** a session without `transcriptPath` set
- **WHEN** `cleanupIdleSessions()` runs
- **THEN** the transcript staleness phase (phase 7) SHALL be a no-op for that session (no `transcriptPath` to read)
- **AND** the existing stuck-session reset in phase 2 (180s/300s thresholds) remains the only path that can flip it to idle

#### Scenario: All phases are independently disable-able

- **GIVEN** a user wants to disable all three new behaviors
- **WHEN** they set `subagentCleanupSeconds == 0` AND `transcriptStaleNoToolSeconds == 0` AND `transcriptStaleWithToolSeconds == 0` in Settings
- **THEN** phases 6 and 7 SHALL be no-ops
- **AND** the existing phase 1-5 behavior SHALL be unchanged
- **AND** the only change from pre-feature behavior is the Cursor interrupt `.removeSession` path in `case "Stop"`, which is not gated by any of the new settings
