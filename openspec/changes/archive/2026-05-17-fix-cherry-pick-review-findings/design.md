## Context

Cherry-pick commit `c41e7f8` resolved conflicts between 13 upstream commits and the fork's main branch. Two critical code paths were lost during merge:

1. **Bridge session_id synthesis** (`main.swift`): The block that generates `"<source>-ppid-<resolvedSessionPID>"` when `session_id` is absent was deleted. The ancestry resolution code remains but its output is unused — the bridge falls through to `guard let sessionId ... else { exit(0) }`, silently dropping events from providers like Cursor, Trae, and Codex that don't always emit stable session IDs.

2. **Notification question drain** (`AppState.swift:1775-1784`): `drainQuestions` removes all queued questions for a session but only calls `continuation.resume(...)` inside the `item.isFromPermission` branch. Non-permission notification questions are dequeued without response, causing the hook's checked continuation to hang forever.

Both are pure regression bugs — the upstream code existed before cherry-pick and was lost during conflict resolution.

## Goals / Non-Goals

**Goals:**
- Restore bridge session_id fallback synthesis so providers without stable session IDs continue to work
- Restore notification question drain to always resume continuations
- Add regression tests to prevent future cherry-pick breakage

**Non-Goals:**
- Refactoring the bridge or AppState architecture
- Adding new features or changing behavior beyond what was lost
- Modifying the session_id synthesis algorithm itself

## Decisions

### Decision 1: Restore the exact upstream session_id fallback block

**Rationale**: The upstream code in `8140885` (commit for #148) placed the fallback block after `_source`/`_ppid` derivation but before the `guard let sessionId` check. Restoring this exact position preserves the intended data flow: ancestry → source → fallback session_id → validate.

**Alternative considered**: Moving the fallback into `CodeIslandCore` for testability. Rejected because this would be a refactor beyond the scope of a bug fix, and the bridge binary is constrained to Foundation/Darwin only (Principle III).

### Decision 2: Restore the else branch in drainQuestions

**Rationale**: The `else` branch simply calls `Self.notificationResponse()` and resumes the continuation. This is the minimal fix — notification questions should always get a response when drained, matching the upstream behavior in `9913131`.

**Alternative considered**: Merging notification and permission drain into one path. Rejected as unnecessary complexity for a regression fix.

### Decision 3: Add tests at the AppState layer, not bridge layer

**Rationale**: The bridge is a standalone binary with no test infrastructure. Testing the session_id synthesis at the bridge level would require end-to-end socket tests. Instead, we test the AppState behavior (notification drain, permission drain) which already has a mature test harness.

## Risks / Trade-offs

- **[Risk]** Bridge session_id fallback may not match upstream exactly after re-insertion → **Mitigation**: Compare against `git show 8140885:Sources/CodeIslandBridge/main.swift` to ensure exact placement
- **[Risk]** drainQuestions fix could affect permission question drain paths → **Mitigation**: Existing `AppStateToolUseCacheTests` and `AppStateQuestionFlowTests` cover permission drain; add specific notification drain test

## Migration Plan

No migration needed — this is a pure bug fix restoring lost behavior. No schema changes, no user-facing settings changes.

Rollback: `git revert <commit>` if any regression is detected.
