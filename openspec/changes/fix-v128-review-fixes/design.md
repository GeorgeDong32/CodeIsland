## Context

v1.2.8 was released with the Cursor subagent merge feature (grouped by `(source, cwd)`), `mergedSessionIds` redirect cache, configurable idle thresholds, and a transcript-staleness interrupt fallback. A targeted code review of the v1.2.7 → v1.2.8 diff surfaced 7 issues scored ≥ 50 (see `proposal.md` for the full list and scoring). This change addresses them as a single, focused fix batch.

The 7 issues cluster into three categories:

1. **Correctness** — A (key mismatch), G (silent permission deny), F (offset double-count), H (stage-5/7 race)
2. **Documentation** — B (stale symbol reference), C (CHANGELOG terminal-context claim)
3. **Hygiene** — D (Codex-aware deny payload reuse)

The merge path is touched by 3 of the 7 issues (A, G, H), so the bulk of the design work is in `AppState.swift`'s `applyCursorSubagentMerge` and `handleEvent`. The other two are isolated one-liner or near-one-liner fixes.

Per Constitution Principle I, no module boundary changes are needed: all fixes live in `CodeIslandCore` (B, F, H partial) or `CodeIsland` (A, C, D, G, H partial). Per Principle II, no business logic moves between modules. Per Principle XII, no concurrency primitives change.

## Goals / Non-Goals

**Goals:**

- Eliminate the subagent-channel key mismatch so `+N Sub` badge counts match the underlying `subagents.count` after the first redirected event.
- Surface pending permission/question denials in the merge path via the existing `decision.message` channel, preserving the user-visible deny reason.
- Stop the stage-5 subagent fast-cleanup from re-opening the create-merge loop in the presence of active redirect entries.
- Keep the `JSONLTailer` MEM-006 memory cap behavior correct when both prefix overflow and trailing truncation occur in the same read.
- Keep docs (in-code and `CHANGELOG`) honest about the actual merge condition.
- Use the existing `denyResponseData(for:)` helper consistently in `enforceQuestionQueueCaps` so the Codex-specific branch applies.

**Non-Goals:**

- Re-architecting the subagent merge feature (e.g., switching back to event-rewrite is explicitly rejected by `c07086a`).
- Changing the public `HookEvent.withRewritten` API.
- Changing settings keys, default values, or adding new user-visible toggles.
- Touching unrelated v1.2.7 features (memory caps MEM-001..MEM-007 except the new ones).

## Decisions

### D1 — Subagent channel key alignment (Issue A)

**Decision**: In `AppState.handleEvent` (line 1025), change the `mergedSessionIds` redirect to rewrite `agentId` as `sessionId` (the raw child ID) instead of `"auto-cwd-\(sessionId)"`. No other line changes.

**Why**: `applyCursorSubagentMerge` stores `sessions[parentId]?.subagents[childId]` using the raw child ID. The reducer's `handleSubagentEvent` / `ensureSubagent` look up subagents by the `agentId` field of the incoming event. The current prefix creates a parallel key (`auto-cwd-<childId>`) that never receives the merge's metadata and breaks the stage-7 eviction check (`parent.subagents[key] == nil`).

**Alternatives considered**:
- *Rename the merge-side key to `auto-cwd-<childId>`*. Rejected — the auto-cwd- prefix is leftover from the abandoned `acb4548` event-rewrite preprocessor (per commit message of `c07086a`); keeping the raw child ID is simpler and matches the v1.2.7 `applyCodexSubsessionModeToKnownSessions` precedent at lines 3032/3040 which also stores by raw child ID.
- *Drop the `mergedSessionIds` redirect entirely*. Rejected — the cache exists precisely to prevent the create-merge loop that `b84693b` was written to fix.

### D2 — Explicit queue drain in merge (Issue G)

**Decision**: In `applyCursorSubagentMerge`, before `removeSession(childId)`, call `drainPermissions(forSession: childId, reason: "subagentMerge")` and `drainQuestions(forSession: childId, reason: "subagentMerge")` so the child's continuations are resumed with the existing `denyResponseData(for: pending.event)` payload, identical to the path used by `denyPermission` / `denyPermissionWithFeedback`.

**Why**: `removeSession` resumes continuations with whatever `denyResponseData` returns for that event. But because we don't know whether the child was waiting on a permission or a question without inspecting the queue, we use the existing `drain*` helpers, which already do the right thing per event. This is a 4-line change inside the merge loop and reuses existing helpers.

**Alternatives considered**:
- *Refuse to merge if the child has pending permissions*. Rejected — that turns merge into a flaky, racey condition (permission might arrive milliseconds after the merge snapshot) and would break the feature for the common case.
- *Preserve the child's permission requests by re-queuing them on the parent*. Considered, but rejected because the parent's UI already shows its own permissions; cross-session permission re-queuing would be a new feature, not a bug fix.

### D3 — `JSONLTailer` offset accounting (Issue F)

**Decision**: Reviewed and dismissed. The original formula `watch.offset += off_t(combined.count - scan.trailingFragment.count)` is correct. Code comment is updated to document the invariant explicitly.

**Why**: The prefix-overflow branch (line 214-221) trims `combined` to `maxPendingFragmentBytes` (M), so the post-`scanLines` trailing fragment is bounded by M. The trailing-truncation branch (line 228-230) is therefore only reachable in the no-prefix-overflow case (M < combined.count <= M+maxDeltaBytes), where the two offset advances are exactly complementary: line 229 advances by the discarded tail bytes, and the trailing-line advance accounts for the consumed complete lines. Using the pre-truncation `scan.trailingFragment.count` on the final line is required so the discarded bytes are counted exactly once.

**Alternatives considered**:
- *Change the final line to use the post-truncation `trailing.count`*. Rejected — this double-counts the discarded tail bytes (which line 229 already advanced for), producing an offset overshoot that makes the next read skip valid file bytes.
- *Drop the trailing-overflow branch entirely*. Rejected — MEM-006 requires a hard bound on the in-memory fragment, and the `attachedTranscriptPaths` re-attach fallback only fires on the `appended.count > maxDeltaBytes` branch.

### D4 — Stage-5 skip for redirected children (Issue H)

**Decision**: In `SessionCleanup.performSubagentFastCleanup`, accept a `mergedSessionIds: [String: String]` parameter (defaulted empty for backward compatibility) and skip removal of any subagent whose `agentId` is a key in that map. `AppState.cleanupIdleSessions` (the only caller) passes its `mergedSessionIds` directly.

**Why**: The race exists because the eviction check at line 380 trusts `parent.subagents[key] != nil` to mean "this merge is still active". When stage 5 removes the subagent entry, that invariant is broken from the other side. Letting the caller tell stage 5 "these keys are still actively merged" preserves the invariant without changing the eviction logic.

**Alternatives considered**:
- *Have stage 5 compute its own list of merged children from the parent sessions*. Rejected — `performSubagentFastCleanup` is in `CodeIslandCore` and must not depend on `AppState`-level state.
- *Move the eviction check before stage 5*. Rejected — eviction still needs to be a separate stage because `removeSession` (which fires later) can also orphan entries; reordering alone doesn't fix the race.

### D5 — Doc and CHANGELOG updates (Issues B, C)

**Decision**: Pure text updates. B: replace the symbol name in the doc comment for `HookEvent.withRewritten`. C: remove the "and terminal context" / "和终端上下文" phrase from the v1.2.8 English and Chinese sections.

**Why**: Both are factual corrections; no design alternatives.

### D6 — `enforceQuestionQueueCaps` deny payload (Issue D)

**Decision**: Replace the inline `Data(#"..."#)` literal with a call to `Self.denyResponseData(for: pending.event, message: pending.denyMessage)` (or the equivalent internal API), matching the pattern in `enforcePermissionQueueCaps`.

**Why**: `denyResponseData(for:)` already implements the Codex-aware branch (omits `suppressOutput` for Codex). Reusing it eliminates the bug, removes the duplicated literal, and brings `enforceQuestionQueueCaps` into symmetry with `enforcePermissionQueueCaps`.

**Alternatives considered**:
- *Keep the literal, add a Codex branch inline*. Rejected — `denyResponseData(for:)` is the single source of truth; the inline copy was a pre-existing bug that the v1.2.7 review did not surface.

## Risks / Trade-offs

- **Risk**: D1 changes the `agentId` field on rewritten events, which may surface in third-party test fixtures or snapshots. → **Mitigation**: The rewritten event is internal; the only consumer is `reduceEvent` → `handleSubagentEvent` → `ensureSubagent`, which keys on `agentId`. No external API or persisted shape is affected. The existing test `testHandleEventRedirectsSubsequentEventsForMergedChildren` (added by `319d677`) constructs its own events and does not depend on the prefix.

- **Risk**: D2 (explicit drain) increases the chance a user sees a "permission denied" message that originated from a merge rather than their own denial click. → **Mitigation**: This is the correct behavior — without the drain, the user sees nothing and a tool call hangs or fails silently. The drained response carries the same `decision.message` field that the existing `denyPermission` path uses.

- **Risk**: D4 (stage-5 skip) keeps entries that the user might consider "stale" in the badge count for slightly longer when `subagentCleanupSeconds > 0`. → **Mitigation**: Once the parent is removed by other stages, the stage-7 eviction naturally clears the cache entry, and the next event for that child re-creates a fresh standalone session (the original v1.2.8 behavior). The skip only delays cleanup while a redirect is genuinely active.

- **Risk (D3, dismissed)**: The reviewer's audit of the `JSONLTailer` offset accounting concluded the original formula was correct; the proposed change to use the post-truncation `trailing.count` would have double-counted the discarded tail bytes. No code change is made to the offset logic; only a comment is added to document the invariant. → **Mitigation**: A code comment now explains why `scan.trailingFragment.count` (not the post-truncation `trailing.count`) is used. A future regression test for the offset is added to the task list as a follow-up.

- **Trade-off**: D1 keeps the raw child ID as the agent key, which could collide with a real Cursor `agent_id` value. → **Mitigation**: Cursor's documented `agent_id` field is only set on SubagentStart/SubagentStop events; in the merge path we are routing a parent-style event back into the parent's subagent channel, where the agent IDs are CodeIsland-internal (the `childId` we generated). The risk is theoretical and consistent with the v1.2.7 Codex-subsession pattern.

## Migration Plan

- No data migration: `mergedSessionIds`, `subagents`, and `watch.offset` are all in-memory.
- No version bump required: this is a v1.2.8 → v1.2.8 patch. `CHANGELOG.md` is amended in place to correct the terminal-context claim.
- Rollback: revert the commits. No persistent state to clean up; the next event for any tracked child will be re-routed normally.
- Deploy: merge `fix/v128-review-fixes` to `main`, then `chore(release): bump version to 1.2.9`. (No new user-facing feature, so a patch bump is appropriate; if the user prefers, the fix can ship as v1.2.8.1.)

## Open Questions

- None blocking. The team should confirm the release version (v1.2.9 vs v1.2.8.1) before `chore(release)`.
