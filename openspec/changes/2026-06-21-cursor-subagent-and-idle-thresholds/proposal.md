# Cursor / Subagent Cleanup and Configurable Idle Thresholds

## Why

Three pain points observed by users with current CodeIsland behavior:

1. **Cursor interrupt leaks a session for up to 30 minutes.** When the user hits ESC or Ctrl+C in Cursor, the CLI fires a `stop` event with `stop_reason: "user"` or `"interrupted"`. The reducer ([Sources/CodeIslandCore/SessionSnapshot.swift:657-696](Sources/CodeIslandCore/SessionSnapshot.swift)) only flips `interrupted = true` and enqueues a completion card; it does not remove the session from `appState.sessions`. Removal otherwise relies on the user-configured `sessionTimeout` (default **30 minutes** per [Sources/CodeIsland/Settings.swift:115](Sources/CodeIsland/Settings.swift)) or the 10-minute hard-coded fallback for sessions without a process monitor. The user sees an idle "interrupted" card sitting in the notch for half an hour.

2. **Claude Code double-ESC / single-ESC leaves the session stuck in "thinking".** Per Claude Code's own hook documentation, the `Stop` event **does not fire on user interrupt** — only on natural completion. [anthropics/claude-code#32712](https://github.com/anthropics/claude-code/issues/32712) documents that `SessionEnd` is also broken for Ctrl+C interrupt as of v2.1.72. The Claude Code CLI process stays alive waiting for the next prompt, so `handleProcessExit` never fires either. The session is stuck in `.running` / `.processing` forever. Transcript staleness (the JSONL file the CLI writes to) is the only reliable signal that generation has stopped.

3. **Cursor spawns parallel subagent `cursor-agent` processes that each occupy a notch slot.** Cursor's hook payload does not include `agent_id` (only Claude Code does), so the existing subagent routing in `handleSubagentEvent` cannot see them. The bridge's `resolvedSessionPID` collapse only works when the payload omits `session_id`, which Cursor does not. Multiple parallel `cursor-agent` subprocesses for the same workspace each get their own session card.

The current cleanup thresholds (180s/300s for stuck sessions, 10-minute idle for hook-only sessions) are hard-coded and cannot be adjusted to match individual workflow tolerances. Three new user-visible settings make the behavior tunable.

## What Changes

- **Cursor interrupt immediate removal.** When the reducer processes a `Stop` event whose source is `cursor` or `cursor-cli` and `stop_reason` is `"user"` or `"interrupted"`, the session is removed from `appState.sessions` via the existing `.removeSession` side effect. All other sources and other `stop_reason` values preserve the existing `.enqueueCompletion` flow (no behavior change for Claude Code / Codex / Gemini / Trae / others).

- **Transcript-staleness interrupt detection.** `cleanupIdleSessions` in [Sources/CodeIsland/AppState.swift:185](Sources/CodeIsland/AppState.swift) gains a new phase 7 that detects "the session looks active but the transcript file has not been written to in N seconds". When both the transcript `mtime` and the session `lastActivity` are older than the threshold, the session is flipped to `.idle` with `interrupted = true` (without removal, so the existing idle-timeout path handles eventual cleanup). This is the Claude Code double-ESC / single-ESC fallback.

- **Subagent merge by cwd for IDE-family CLIs (post-hoc reconciliation).** A new `applyCursorSubagentMerge()` method runs after `reduceEvent` returns (same pattern as `applyCodexSubsessionModeToKnownSessions` for Codex). It groups existing sessions by `(source, cwd, terminal_id)`, designates the oldest (by `startTime`) as the parent, moves all others into the parent's `subagents` dictionary as `SubagentState` entries, and removes the child sessions via `removeSession`. Sources in the whitelist `{cursor, cursor-cli, trae, traecn, codebuddy, codybuddycn}` are affected; Claude Code's own `agent_id`-based subagent routing is unchanged.

- **Subagent fast cleanup.** `cleanupIdleSessions` gains a new phase 6 that removes `SubagentState` entries whose `lastActivity` is older than the configured subagent-cleanup threshold (default 30s). This keeps the `+N Sub` badge accurate without waiting for the long global session timeout.

- **Three new settings.** `transcriptStaleNoToolSeconds` (default 60s), `transcriptStaleWithToolSeconds` (default 90s), `subagentCleanupSeconds` (default 30s). Each is a `Picker` in the existing `sessions` section of Settings, with a `0 = Never` option that disables the corresponding behavior.

## Capabilities

### Modified Capabilities

- `core-architecture`: add scenarios for the new `Stop` interrupt-removal path, transcript-staleness detection, subagent-by-cwd merge, and subagent fast cleanup. These extend the existing "session lifecycle" and "cleanup" requirements.
- `user-experience`: add scenarios for the three new Settings entries (label, description, options, persistence, and 0=disabled semantics).

## Impact

- `Sources/CodeIslandCore/SessionSnapshot.swift`: `case "Stop"` branches on `source` and `stopReason` to decide between `.removeSession` and `.enqueueCompletion`.
- `Sources/CodeIsland/AppState.swift`:
  - New `applyCursorSubagentMerge()` post-hoc reconciliation (same pattern as `applyCodexSubsessionModeToKnownSessions`), called from `handleEvent` after `reduceEvent` returns and from `integrateDiscoveredSessions`. Removes child sessions and moves them into parent's `subagents` dict.
  - `cleanupIdleSessions` adds phase 6 (subagent fast cleanup) and phase 7 (transcript staleness), both reading thresholds from `SettingsManager`.
- `Sources/CodeIsland/Settings.swift`: three new `SettingsKey` constants, three `SettingsDefaults`, three `SettingsManager` computed properties, registered in the `defaults.register` dict.
- `Sources/CodeIsland/SettingsView.swift`: three new `@AppStorage` bindings and three new `Picker` sections in the existing `sessions` block.
- `Sources/CodeIsland/L10n.swift`: six new localization keys (label + description) for each of the three settings, in en / zh / ja / ko / tr.
- `Sources/CodeIsland/DiagnosticsExporter.swift`: three new entries in the exported `settings` dict.
- New test files (see `tasks.md`).
- `CHANGELOG.md`: `[Unreleased]` entry.

## Out of scope

- Changing the existing `sessionTimeout` semantics (still minutes, still applies to all idle sessions).
- Removing the legacy hard-coded 180s/300s stuck-session thresholds (they remain as a safety net for sessions without `transcriptPath`).
- Touching Claude Code's `agent_id`-based subagent routing (intentionally untouched — not in the whitelist).
- Changing the existing `interrupted` flag semantics (still only used to display the `INT` badge in `NotchPanelView`).
- Subagent count thresholds (e.g. "if more than 5 subagents, also hide some") — the user did not request this.
- New `AgentStatus` cases. The existing `.idle` state is reused for the "interrupted" case.
