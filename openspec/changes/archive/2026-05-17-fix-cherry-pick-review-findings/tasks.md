## 1. Bridge Session ID Fallback Restoration

- [x] 1.1 Restore session_id synthesis block in `Sources/CodeIslandBridge/main.swift` before the `guard let sessionId` check, using `CLIProcessResolver.resolvedSessionPID(source:ancestry:)` to generate `"<source>-ppid-<pid>"` when `json["session_id"]` is nil and `effectiveSource` is known (Principle III, IV)
- [x] 1.2 Verify bridge compiles with `swift build` and the fallback path is syntactically correct
- [x] 1.3 Verify bridge silent-exit behavior when neither session_id nor source is available (Principle XI)

## 2. Notification Question Drain Fix

- [x] 2.1 Add `else` branch in `drainQuestions` (`Sources/CodeIsland/AppState.swift`) so non-permission questions resume their continuation with `Self.notificationResponse()` (Principle VI, XII)
- [x] 2.2 Add regression test: notification question drained on peer disconnect resumes continuation (Principle XIII)
- [x] 2.3 Add regression test: notification question drained on activity event resumes continuation (Principle XIII)
- [x] 2.4 Verify existing `AppStateQuestionFlowTests` and `AppStateToolUseCacheTests` still pass

## 3. Verification

- [x] 3.1 Run `swift test` — all 201+ tests must pass with 0 failures
- [x] 3.2 Run `swift build` — clean build with no warnings
- [x] 3.3 Commit with message: `fix(bridge): add argv inspection for node-based CLI session detection`
