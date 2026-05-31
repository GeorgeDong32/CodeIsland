## Why

Cherry-pick conflict resolution (`c41e7f8`) introduced two regressions caught by Codex review:

1. **Bridge session_id synthesis removed** — the `session_id` fallback path that synthesizes `"<source>-ppid-<pid>"` for providers/plugins that don't emit a stable session_id was deleted during conflict resolution. Any non-Claude hook payload without `session_id` is now silently dropped at the bridge, making entire providers appear dead.

2. **Notification question drain leaks continuations** — `drainQuestions` only resumes continuations inside the `item.isFromPermission` branch. Plain notification questions get dequeued without resuming their continuation, causing the blocking hook request to hang indefinitely on peer disconnect or activity event drain.

Both issues are cherry-pick artifacts — the upstream logic was present but lost during merge conflict resolution. Fixing them restores intended behavior without introducing new architecture.

## What Changes

- Restore `session_id` fallback synthesis in `CodeIslandBridge/main.swift` before the `guard let sessionId` check, using `CLIProcessResolver.resolvedSessionPID(...)` when `_source` is known but `session_id` is absent.
- Restore the `else` branch in `drainQuestions` (`AppState.swift`) so non-permission questions resume with `Self.notificationResponse()`.
- Add regression tests for both scenarios.

## Capabilities

### New Capabilities

- `bridge-session-fallback`: Bridge session_id synthesis for providers that don't emit stable session IDs

### Modified Capabilities

- `hook-protocol`: Notification question drain must resume all continuations, not just permission-sourced ones

## Impact

- **Files**: `Sources/CodeIslandBridge/main.swift`, `Sources/CodeIsland/AppState.swift`, `Tests/CodeIslandTests/`
- **Risk**: Low — both are restoring previously-working code paths lost during cherry-pick
- **Regression surface**: Providers like Cursor, Trae, Codex that rely on synthesized session IDs; notification-style AskUserQuestion flows
