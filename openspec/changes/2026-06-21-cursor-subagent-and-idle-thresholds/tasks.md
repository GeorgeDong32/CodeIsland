# Tasks — Cursor / Subagent Cleanup and Configurable Idle Thresholds

## 1. Confirm Baseline

- [ ] 1.1 Run `swift test` baseline and capture the green test count before any code change.
- [ ] 1.2 Re-read [Sources/CodeIslandCore/SessionSnapshot.swift:657-696](Sources/CodeIslandCore/SessionSnapshot.swift) to confirm the current `Stop` handler behavior.
- [ ] 1.3 Re-read [Sources/CodeIsland/AppState.swift:185-336](Sources/CodeIsland/AppState.swift) (`cleanupIdleSessions` phases 1-5) to confirm insertion points for phase 6 and 7.
- [ ] 1.4 Re-read [Sources/CodeIsland/AppState.swift:955-1030](Sources/CodeIsland/AppState.swift) (`handleEvent` entry) to confirm the preprocessor insertion point.
- [ ] 1.5 Re-read [Sources/CodeIsland/SettingsView.swift:492-525](Sources/CodeIsland/SettingsView.swift) (`sessions` section) to confirm the Picker insertion point.
- [ ] 1.6 Re-read [Sources/CodeIsland/L10n.swift:99-119](Sources/CodeIsland/L10n.swift) (English `sessions` block) to use as a template for the 6 new keys.

## 2. Add Cursor Interrupt Immediate Removal

- [ ] 2.1 In [Sources/CodeIslandCore/SessionSnapshot.swift:657](Sources/CodeIslandCore/SessionSnapshot.swift) `case "Stop"`, compute `isCursorInterrupt` from `source` and `stopReason`.
- [ ] 2.2 Branch the side-effect: if `isCursorInterrupt` then `effects.append(.removeSession(sessionId: sessionId))` else the existing `effects.append(.enqueueCompletion(sessionId: sessionId))`.
- [ ] 2.3 Keep all other `Stop` body logic (capture `lastAssistantMessage`, capture `lastUserPrompt`, set `interrupted = isCursorInterrupt`, set `status = .idle`, clear `currentTool` / `toolDescription`) before the branch.
- [ ] 2.4 Run `swift build` to confirm the change compiles.

## 3. Add Transcript Staleness Detection (Phase 7)

- [ ] 3.1 In [Sources/CodeIsland/AppState.swift](Sources/CodeIsland/AppState.swift) `cleanupIdleSessions`, append a new phase 7 block at the end (before `refreshDerivedState`).
- [ ] 3.2 Phase 7 reads `transcriptStaleNoToolSeconds` and `transcriptStaleWithToolSeconds` from `SettingsManager.shared`; skip the phase if both are `0`.
- [ ] 3.3 For each session where `transcriptPath != nil` and `status in {.running, .processing}` and `!isRemote`:
  - Read `transcriptPath` file's `.modificationDate` via `FileManager.default.attributesOfItem(atPath:)`. Treat missing file or read error as `Date.distantPast`.
  - If `mtime` older than threshold AND `lastActivity` older than threshold → flip to `.idle` + `interrupted = true`, clear `currentTool` / `toolDescription`.
- [ ] 3.4 Threshold: `.running` (with tool) uses `transcriptStaleWithToolSeconds`; `.processing` (no tool) uses `transcriptStaleNoToolSeconds`. Both compared in seconds.
- [ ] 3.5 Run `swift build` to confirm the change compiles.

## 4. Add Subagent-by-cwd Merge (Post-hoc Reconciliation)

- [ ] 4.1 Delete the event-time merge code from `handleEvent`: remove the `mergeIntoParentSessionIfMatches(event:)` call and the `let event = mergedEvent ?? event` line ([AppState.swift:998-1010](Sources/CodeIsland/AppState.swift)).
- [ ] 4.2 Delete the `mergeIntoParentSessionIfMatches(event:)`, `terminalIdsMatch(event:session:)` methods and the `cwdCollapseSources` / `cwdCollapseWindow` static constants from `AppState`.
- [ ] 4.3 Add a new `sessionTerminalIdsMatch(session:parent:)` static method that compares two `SessionSnapshot` values (not event+session). Same 5-way any-match logic: `termBundleId`, `itermSessionId`, `ttyPath`, `tmuxPane`, `cmuxSurfaceId`.
- [ ] 4.4 Add a new `applyCursorSubagentMerge() -> Bool` method on `AppState`:
  - Group sessions by `"\(source)|\(cwd)"` where source is in the whitelist `["cursor", "cursor-cli", "trae", "traecn", "codebuddy", "codybuddycn"]` and cwd is non-empty.
  - Within each group with 2+ members, sort by `startTime`. Keep the first as parent.
  - For each child: check `child.startTime - parent.startTime <= 60s`, and `sessionTerminalIdsMatch` passes. If yes:
    - Create `SubagentState(agentId: childSessionId, agentType: child.currentTool ?? child.toolDescription ?? "Agent")` with child's status, currentTool, toolDescription, lastActivity.
    - Write into `sessions[parentId]?.subagents[childSessionId]`.
    - Update parent status to `.running` with `currentTool = "Agent"`.
    - Update parent's `lastActivity` if child's is newer.
    - Call `removeSession(childSessionId)`.
  - Return `didMutate`.
- [ ] 4.5 In `handleEvent`, after `let effects = reduceEvent(...)` and before `refreshDerivedState()`, add: `_ = applyCursorSubagentMerge()`.
- [ ] 4.6 In `integrateDiscoveredSessions`, after the existing `applyCodexSubsessionModeToKnownSessions()` call, add: `_ = applyCursorSubagentMerge()`.
- [ ] 4.7 Run `swift build` to confirm the change compiles.

## 5. Add Subagent Fast Cleanup (Phase 6)

- [ ] 5.1 In [Sources/CodeIsland/AppState.swift](Sources/CodeIsland/AppState.swift) `cleanupIdleSessions`, append a new phase 6 block before phase 7.
- [ ] 5.2 Phase 6 reads `subagentCleanupSeconds` from `SettingsManager.shared`; skip the phase if `0`.
- [ ] 5.3 For each session, walk `session.subagents`; collect entries where `subagent.status == .idle && -subagent.lastActivity.timeIntervalSinceNow > threshold`. Remove them and set a `didMutate` flag.
- [ ] 5.4 Run `swift build` to confirm the change compiles.

## 6. Add Three New Settings

- [ ] 6.1 In [Sources/CodeIsland/Settings.swift](Sources/CodeIsland/Settings.swift), add three `SettingsKey` constants:
  - `transcriptStaleNoToolSeconds = "transcriptStaleNoToolSeconds"`
  - `transcriptStaleWithToolSeconds = "transcriptStaleWithToolSeconds"`
  - `subagentCleanupSeconds = "subagentCleanupSeconds"`
- [ ] 6.2 Add three `SettingsDefaults`:
  - `transcriptStaleNoToolSeconds = 60`
  - `transcriptStaleWithToolSeconds = 90`
  - `subagentCleanupSeconds = 30`
- [ ] 6.3 Register the three keys in the `defaults.register` dict (around [Settings.swift:223](Sources/CodeIsland/Settings.swift)).
- [ ] 6.4 Add three computed properties on `SettingsManager`:
  - `var transcriptStaleNoToolSeconds: Int` (get via `defaults.integer(forKey:)`; set via `defaults.set(_:forKey:)`).
  - Same for the other two.
- [ ] 6.5 Run `swift build` to confirm the change compiles.

## 7. Add Settings UI

- [ ] 7.1 In [Sources/CodeIsland/SettingsView.swift](Sources/CodeIsland/SettingsView.swift), add three `@AppStorage` private vars in the `BehaviorPage` struct (after the existing `sessionTimeout` one).
- [ ] 7.2 Insert three new `Picker` sections into the existing `Section(l10n["sessions"])` block, between the `sessionTimeout` Picker and the `rotationInterval` Picker.
- [ ] 7.3 Option sets:
  - `transcriptStaleNoToolSeconds`: 0 / 30 / 60 / 120 / 300
  - `transcriptStaleWithToolSeconds`: 0 / 60 / 90 / 120 / 300
  - `subagentCleanupSeconds`: 0 / 15 / 30 / 60 / 120
- [ ] 7.4 Run `swift build` to confirm the change compiles.

## 8. Add Localization Keys

- [ ] 8.1 In [Sources/CodeIsland/L10n.swift](Sources/CodeIsland/L10n.swift), add 6 new keys to the `en` dictionary:
  - `transcript_stale_no_tool`, `transcript_stale_no_tool_desc`
  - `transcript_stale_with_tool`, `transcript_stale_with_tool_desc`
  - `subagent_cleanup`, `subagent_cleanup_desc`
- [ ] 8.2 Add the same 6 keys to the `zh` dictionary with Chinese translations.
- [ ] 8.3 Add the same 6 keys to the `ja`, `ko`, `tr` dictionaries (English fallback acceptable if no native translation, but the keys MUST be present to avoid `L10nTests` failures).
- [ ] 8.4 Verify the existing `L10nTests` test still passes (it asserts all keys exist in en and zh).

## 9. Update Diagnostics Exporter

- [ ] 9.1 In [Sources/CodeIsland/DiagnosticsExporter.swift:115-128](Sources/CodeIsland/DiagnosticsExporter.swift), add three entries to the `settings` dict:
  - `transcriptStaleNoToolSeconds`
  - `transcriptStaleWithToolSeconds`
  - `subagentCleanupSeconds`

## 10. Add Tests

- [ ] 10.1 Create `Tests/CodeIslandCoreTests/StopInterruptTests.swift` with tests:
  - `testStopWithCursorInterruptRemovesSession` (source: cursor, stop_reason: user → effects contains .removeSession, NOT .enqueueCompletion)
  - `testStopWithCursorCliInterruptRemovesSession` (source: cursor-cli, stop_reason: interrupted)
  - `testStopWithCursorNaturalCompletionEnqueuesCompletion` (source: cursor, stop_reason: end_turn → effects contains .enqueueCompletion)
  - `testStopWithClaudeCodeEnqueuesCompletion` (source: claude, no stop_reason)
  - `testStopWithCodexEnqueuesCompletion` (source: codex)
  - `testStopWithGeminiEnqueuesCompletion` (source: gemini)
  - `testStopInterruptSetsInterruptedFlag` (assert `sessions[id].interrupted == true`)
- [ ] 10.2 Create `Tests/CodeIslandTests/TranscriptStalenessTests.swift` with tests:
  - `testTranscriptStaleProcessingFlipsToIdle` (mock file, set mtime 70s ago, lastActivity 70s ago, threshold 60 → idle + interrupted)
  - `testTranscriptRecentKeepsSessionActive` (mtime 5s ago, lastActivity 5s ago → no change)
  - `testLastActivityRecentKeepsSessionActive` (mtime 70s ago, lastActivity 5s ago → no change, the tool just ran)
  - `testTranscriptStaleThresholdZeroDisabled` (threshold 0 → no flip regardless of mtime)
  - `testTranscriptMissingFileTreatedAsInfinitelyStale` (mtime → .distantPast → flip)
- [ ] 10.3 Rewrite `Tests/CodeIslandCoreTests/CursorSubagentCollapseTests.swift` (post-hoc reconciliation):
  - `testPostHocMergeMovesChildIntoParentSubagents` (two cursor sessions same cwd+terminal, 30s apart → after `applyCursorSubagentMerge`, child removed from sessions, child's sessionId in parent.subagents)
  - `testPostHocMergeSkipsWhenGapExceeds60s` (child.startTime > 60s after parent → no merge, both remain)
  - `testPostHocMergeSkipsClaudeCode` (source: claude → not in whitelist, no merge)
  - `testPostHocMergeRequiresTerminalIdMatch` (same cwd but different terminal → no merge)
  - `testPostHocMergeKeepsChildStatusInSubagentState` (child was .running → merged subagent.status == .running)
- [ ] 10.4 Create `Tests/CodeIslandCoreTests/SubagentFastCleanupTests.swift` with tests:
  - `testSubagentIdleOver30sIsRemoved` (subagent.status = .idle, lastActivity = 60s ago, threshold 30 → removed)
  - `testSubagentIdleUnder30sIsKept` (lastActivity = 10s ago → kept)
  - `testSubagentRunningNotRemoved` (subagent.status = .running, lastActivity = 60s ago → kept)
  - `testSubagentCleanupThresholdZeroDisabled` (threshold 0 → no removal)
- [ ] 10.5 Create `Tests/CodeIslandTests/IdleThresholdSettingsTests.swift` with tests:
  - `testDefaultValues` (assert 60 / 90 / 30 are the defaults)
  - `testSettingPersists` (set → read back via `SettingsManager.shared`)
  - `testZeroDisablesPath` (assert `cleanupIdleSessions` phase 6 / 7 short-circuit when 0)
  - `testChangeTakesEffect` (set new value → run `cleanupIdleSessions` → behavior changes accordingly)

## 11. CHANGELOG and Documentation

- [ ] 11.1 Add a `### Added` entry to `CHANGELOG.md` under `[Unreleased]` describing:
  - Cursor ESC / Ctrl+C interrupt now removes the session immediately (was: linger up to 30 minutes).
  - Claude Code interrupt fallback via transcript staleness (configurable threshold).
  - Subagent merge by cwd for Cursor / Trae / CodeBuddy (reduces notch slot usage).
  - Three new Settings entries: "Subagent Cleanup", "Transcript Stale (no tool)", "Transcript Stale (with tool)".
- [ ] 11.2 Update README.md (English + Chinese) "How It Works" section if it mentions cleanup behavior.

## 12. Build and Manual Verification

- [ ] 12.1 Run `swift build` and confirm zero warnings.
- [ ] 12.2 Run `swift test` and confirm all new tests pass plus no regression in the baseline.
- [ ] 12.3 Open the app, navigate to Settings → Sessions, confirm three new Pickers visible with correct defaults.
- [ ] 12.4 In Cursor: open a session, hit ESC → confirm the card disappears within 1 second (was: 30 minutes).
- [ ] 12.5 In Claude Code: open a session, hit ESC during a long generation → confirm the card flips to "interrupted" within ~60 seconds.
- [ ] 12.6 Inject synthetic subagent events via socket (Python script): main-1 SessionStart + 3x sub UserPromptSubmit in same cwd/terminal → confirm only 1 card visible (parent), with `+3 Sub` badge. child sessions removed from `sessions` dict.
- [ ] 12.7 Change "Subagent Cleanup" to 15s in Settings → confirm idle subagent badges decrement faster.
- [ ] 12.8 Change "Transcript Stale (no tool)" to 0 → confirm the Claude Code interrupt fallback is disabled (sessions stay in "thinking" until Stop fires).
- [ ] 12.9 Open `~/.codeisland/sessions.json` and confirm the three new settings appear in the diagnostics export.
- [ ] 12.10 Confirm Claude Code sessions with the old `addRules` global setting still work (no behavior change).
- [ ] 12.11 Confirm Codex / Gemini sessions still fire `Stop` correctly (no behavior change).
- [ ] 12.12 Run `./build.sh` and confirm the release build succeeds.
