# Design — Cursor / Subagent Cleanup and Configurable Idle Thresholds

## Context

CodeIsland's hook event reducer is shared across all supported CLIs (Claude Code, Codex, Cursor, Trae, CodeBuddy, etc.). The reducer's `case "Stop"` currently treats every `Stop` event the same: set `interrupted` based on `stop_reason`, set `status = .idle`, enqueue a completion card, and leave the session in the dictionary for the `sessionTimeout` (default 30 minutes) to eventually evict. This is fine for CLIs where `Stop` reliably means "natural end of a turn" (Claude Code, Codex). For Cursor, where `Stop` ALSO fires on user interrupt with a distinguishing `stop_reason` value, this is too slow.

Claude Code's behavior is the opposite: `Stop` only fires on natural completion. On user interrupt (ESC / Ctrl+C), no `Stop` arrives, and the CLI process stays alive waiting for the next prompt, so `handleProcessExit` (which relies on `DispatchSource` exit signals) never fires. The session is stuck in `.running` / `.processing` forever. The only reliable signal that the turn ended is the JSONL transcript file (`transcript_path`) ceasing to be written to.

Cursor additionally spawns parallel `cursor-agent` subprocesses when the user kicks off background work. Each subprocess has its own `session_id` from Cursor's API, so the existing subagent routing in `handleSubagentEvent` (which requires `agent_id`) does not see them. The bridge's `resolvedSessionPID` collapse-onto-one-card logic only activates when `session_id` is missing from the payload, which Cursor does not. The result is one notch slot per parallel agent.

The three existing cleanup thresholds (180s / 300s stuck-session reset, 10-minute idle for hook-only sessions) are hard-coded literals in `cleanupIdleSessions`. Users with longer or shorter workflows have no way to tune them.

## Goals / Non-Goals

**Goals**

- `Stop` events from `cursor` / `cursor-cli` with `stop_reason: "user"` / `"interrupted"` remove the session from `appState.sessions` immediately. All other sources and other `stop_reason` values keep the existing completion-card flow.
- Sessions with a `transcriptPath` whose file has not been modified in N seconds (and whose `lastActivity` is also stale) are flipped to `.idle` + `interrupted = true`. This is the Claude Code interrupt fallback.
- For sources in `{cursor, cursor-cli, trae, traecn, codebuddy, codybuddycn}`, events arriving within 60s of an existing active session for the same `(cwd, terminal_id)` are routed into the existing session as a synthesized subagent. Claude Code's `agent_id`-based subagent routing is untouched.
- Idle subagent entries (`SubagentState.status == .idle`) older than the configured threshold are removed from the parent's `subagents` dictionary on every cleanup pass.
- Three new Settings entries for the three thresholds, each with a `0 = Never` option.

**Non-Goals**

- Removing the existing `sessionTimeout` setting. The new settings are additive, narrower, and do not duplicate the role of `sessionTimeout` (which removes whole sessions) — the new ones flip state, mark interrupted, and clean subagent entries.
- Removing the hard-coded 180s/300s stuck-session thresholds in phase 2. They remain as a safety net for sessions without `transcriptPath` (rare for supported CLIs, but real for some).
- Subagent count thresholds or "hide N+1 subagent" rules.
- Changing the existing `interrupted` flag's UI role (`INT` badge in `NotchPanelView`).
- Adding new `AgentStatus` cases.
- Touching `SubagentState` itself (the threshold is a setting, not a struct field).

## Decisions

### Decision 1: Source whitelist for the `Stop` interrupt-removal path

- **What**: The `isCursorInterrupt` boolean is computed as `(source == "cursor" || source == "cursor-cli") && (stopReason == "user" || stopReason == "interrupted")`.
- **Why**: Defense in depth. Claude Code's `Stop` payload does not include `stop_reason` at all (per its [hooks reference](https://code.claude.com/docs/en/hooks-guide)), so `stopReason` is always `""` and the condition naturally fails. Adding the source check makes the intent explicit and protects against future CLIs that adopt the same `stop_reason` vocabulary.
- **Where**: [Sources/CodeIslandCore/SessionSnapshot.swift:657-696](Sources/CodeIslandCore/SessionSnapshot.swift) `case "Stop"`.

### Decision 2: Transcript staleness uses BOTH mtime and `lastActivity`

- **What**: A session is flipped to `.idle` only when (a) the transcript file's `mtime` is older than the threshold AND (b) the session's `lastActivity` is also older than the threshold. Both conditions must hold.
- **Why**: The `lastActivity` check guards against the case where a long-running tool is between calls — the transcript may not be written for a few seconds while the tool runs, but a hook event updates `lastActivity`. Requiring both to be stale means a slow tool will not be misclassified as interrupted. This matches the existing phase 2 (stuck-session reset) approach in spirit.
- **Where**: [Sources/CodeIsland/AppState.swift:185](Sources/CodeIsland/AppState.swift) `cleanupIdleSessions` new phase 7.

### Decision 3: Subagent-by-cwd merge uses a 60-second window

- **What**: The preprocessor only merges a new event into an existing session if the existing session's `lastActivity` is within the last 60 seconds.
- **Why**: A user who opens two independent sessions in the same workspace 10 minutes apart should not have them collapsed. The 60s window is long enough to catch a "user prompt sent → next cursor-agent spawns immediately" sequence, but short enough to avoid false positives during normal multi-task workflows.
- **Where**: [Sources/CodeIsland/AppState.swift:955](Sources/CodeIsland/AppState.swift) `handleEvent` preprocessor, with the merge logic factored into a private helper `findParentSessionId(forSubagentCandidate:event:)`.

### Decision 4: Merge key is `(source, cwd, terminal_id)` with any-of terminal matching

- **What**: The merge key requires the same `source` and same `cwd`, and at least one matching terminal identifier: `termBundleId`, `itermSessionId`, `ttyPath`, `tmuxPane`, or `cmuxSurfaceId`.
- **Why**: A bare `(source, cwd)` match would conflate sessions running in two different IDE windows or terminal tabs in the same project. Terminal-id matching disambiguates "user in iTerm tab A is doing one thing, user in iTerm tab B is doing another". Any-of matching is forgiving — different terminals expose different env vars, and we do not want to require ALL of them to be present, just at least one.
- **Where**: Same `findParentSessionId` helper as Decision 3.

### Decision 5: Synthesized subagent `agentId` is `auto-cwd-<original_session_id>`

- **What**: When the preprocessor rewrites an event, the new `agentId` is `"auto-cwd-" + originalSessionId`. The `originalSessionId` is the new event's pre-rewrite `session_id`.
- **Why**: The string prefix `auto-cwd-` makes the synthesized subagent easy to identify in diagnostics and tests, distinguishing it from genuine `agent_id` payloads from Claude Code. Using the original session id as the suffix guarantees uniqueness across multiple parallel merges into the same parent.
- **Where**: [Sources/CodeIsland/AppState.swift:955](Sources/CodeIsland/AppState.swift) `handleEvent` preprocessor, at the point of rewrite.

### Decision 6: Subagent fast cleanup is threshold-driven, per-cleanup-pass

- **What**: Each `cleanupIdleSessions` invocation (3-second timer) walks `sessions[parentId].subagents` and removes entries where `subagent.status == .idle && -subagent.lastActivity.timeIntervalSinceNow > threshold`.
- **Why**: Per-pass evaluation (rather than per-event scheduling) keeps the logic simple and aligns with the rest of the cleanup phases. The 30-second default means subagent entries linger at most ~30s after going idle, well within the typical user attention span for "did this subagent finish?".
- **Where**: [Sources/CodeIsland/AppState.swift:185](Sources/CodeIsland/AppState.swift) `cleanupIdleSessions` new phase 6.

### Decision 7: Three new settings, unit in seconds, with `0 = Never`

- **What**: `transcriptStaleNoToolSeconds` (default 60), `transcriptStaleWithToolSeconds` (default 90), `subagentCleanupSeconds` (default 30). All three stored as `Int` in `UserDefaults`. The Picker shows seconds as the unit, with the literal string `"Never"` for the 0 option, matching the existing `sessionTimeout` 0-doesn't-clean pattern.
- **Why**: Seconds give enough granularity for the 30s / 60s / 90s default values. A user who wants stricter cleanup picks 15s; a user on a slow Mac or with long-running tools picks 120s or 300s. The 0 option is the documented escape hatch for "do not perform this kind of cleanup at all".
- **Where**: [Sources/CodeIsland/Settings.swift](Sources/CodeIsland/Settings.swift) (3 keys + defaults + computed properties), [Sources/CodeIsland/SettingsView.swift:492-525](Sources/CodeIsland/SettingsView.swift) (3 new Pickers after the existing `sessionTimeout` Picker).

### Decision 8: New settings live in the existing `sessions` Settings section, not a new section

- **What**: The three new Pickers are inserted into the existing `Section(l10n["sessions"])` block in `SettingsView`, immediately after the existing `sessionTimeout` Picker and before the `rotationInterval` Picker.
- **Why**: The new settings are session-cleanup related, which is the exact topic of the `sessions` section. Adding a new top-level section ("Advanced" or "Cleanup") would fragment the related controls and force the user to look in two places. The existing `sessions` section already has 4 Pickers, adding 3 more (5 + 3 = 8 total) is still manageable.
- **Where**: [Sources/CodeIsland/SettingsView.swift:492](Sources/CodeIsland/SettingsView.swift) `Section(l10n["sessions"])`.

## Risks / Trade-offs

- **Risk**: Transcript staleness with a 60s threshold for `.processing` may misclassify Opus 4.6 extended thinking (which can legitimately take minutes between token writes).
  - **Mitigation**: The BOTH-condition requirement (transcript mtime AND `lastActivity` both stale) means a long thinking block that just wrote tokens 30s ago will not be misclassified — `lastActivity` is updated by every hook event, but if there are no hook events during thinking, the `mtime` is the deciding factor. Users with very long thinking can raise the threshold via Settings. The 60s default is conservative for typical use.
- **Risk**: A user who wants the OLD behavior (stuck session visible for 30+ minutes) loses it by default.
  - **Mitigation**: The `0 = Never` option on the new Picker restores the old behavior for that specific path. The existing `sessionTimeout` setting is unchanged and still applies to genuinely-idle sessions.
- **Risk**: The cwd-merge preprocessor is gated by a hard-coded 60s window. If a user actually wants to open two distinct sessions 30s apart in the same workspace, they collide into one card.
  - **Mitigation**: The window only applies when the SECOND session's session_id is different from any existing session AND they share terminal_id. A user can deliberately open the second session in a different terminal tab to bypass the merge. 60s is short enough that "30s apart" is an unusual case; 5+ minutes is the typical gap.
- **Risk**: Synthesized subagent `agentId` strings (`auto-cwd-<...>`) are persisted in `SessionSnapshot.subagents[agentId]`. If we later add a `Codable` round-trip for subagents and the prefix is changed, historical sessions would orphan their subagent entries.
  - **Mitigation**: The `SubagentState` map is not currently persisted to disk via `SessionPersistence` (only the top-level `SessionSnapshot` is). When it is added, the prefix will be versioned via the existing `SessionPersistence` migration mechanism. No code change needed now.
- **Risk**: Three new settings increase the cognitive load of the `sessions` Settings section.
  - **Mitigation**: Each Picker has a 1-line description (`_desc` key) explaining when to adjust. All three defaults are the conservative values from the original plan, so the user does not need to touch them unless they want to.

## Open Questions

None at submission time. If the user wants to change defaults, ranges, or the cwd-merge whitelist after seeing the implementation, those are small follow-up edits to the constants in `AppState.swift` and the Picker options in `SettingsView.swift`.
