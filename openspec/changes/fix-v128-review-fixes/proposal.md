## Why

A targeted code review of the v1.2.7 → v1.2.8 diff (10 commits focused on Cursor subagent merge, transcript-staleness detection, and configurable idle thresholds) identified 7 issues scored ≥ 50: a real correctness bug in the subagent channel key (A), a stale `CHANGELOG` claim (C), a silent permission-denying side effect during merge (G), a `JSONLTailer` offset double-counting edge case (F), a stale doc reference (B), a duplicated/cross-CLI deny JSON literal (D), and a stage-5/7 cleanup race that re-opens the create-merge loop (H). Two of these (A, G) directly affect end-user behavior on Cursor / Trae / CodeBuddy sessions; the rest are correctness, documentation, and hardening fixes. Shipping them as a single change keeps the regression surface small and reviewable, while preventing the high-score issues from leaking into v1.2.9.

## What Changes

- **Fix subagent channel key mismatch (A)**: `handleEvent` redirect path in `AppState.swift` rewrites `agentId` to `"auto-cwd-\(childId)"`, but `applyCursorSubagentMerge` stores the subagent under the raw `childId`. Align the two by removing the `auto-cwd-` prefix on the redirect path so the rewritten event lands on the existing subagent entry instead of creating a duplicate.
- **Drain pending permission/question queues explicitly before `removeSession` in merge (G)**: In `applyCursorSubagentMerge`, before calling `removeSession(childId)`, explicitly drain the child's permission and question queues, resuming each continuation with `denyResponseData(for: event)` so users are not silently dropped from in-flight approvals.
- **Update `CHANGELOG.md` (C)**: Remove the "and terminal context" / "和终端上下文" clause from v1.2.8 entries in both English and Chinese sections, since `319d677` removed the terminal-ID match requirement.
- **Fix `JSONLTailer` offset accounting (F)**: Reviewed and dismissed — the reviewer traced the reachable truncation paths and confirmed the original formula `watch.offset += combined.count - scan.trailingFragment.count` is correct. The prefix-overflow branch trims `combined` to `maxPendingFragmentBytes`, so the post-`scanLines` trailing fragment is bounded by the same cap and the truncation branch is only reachable in the no-prefix-overflow case where line 229's pre-truncation advance and line 233's pre-truncation subtraction are exactly complementary. Updated the code comment to document this invariant explicitly. No behavior change.
- **Fix stale doc reference in `Models.swift` (B)**: Update the doc comment on `HookEvent.withRewritten(sessionId:agentId:)` to reference `AppState.applyCursorSubagentMerge()` instead of the non-existent `mergeIntoParentSessionIfMatches`.
- **Route `enforceQuestionQueueCaps` deny responses through `denyResponseData(for:)` (D)**: Replace the inline `Data(#"..."#)` literal with a call to the existing Codex-aware helper, so Codex session question caps use the same `decision` shape that `denyPermission` uses, and the existing `enforcePermissionQueueCaps` symmetry is preserved.
- **Stage-5/7 race hardening (H)**: Make `performSubagentFastCleanup` (stage 5) skip entries whose session ID is present in `mergedSessionIds`, so the parent-side subagent entry is not removed while a redirect is still active. This closes the loop re-introduced when `b84693b` was later relaxed by `319d677`.

No new public API is introduced and no user-facing behavior change is intended for A, F, B, C, D, or H. G is the only behavior-visible fix: previously-merged child sessions that had a pending permission will now produce an explicit deny with the existing `decision.message` field instead of being silently dropped.

## Capabilities

### New Capabilities

None. All changes are bug fixes to existing capabilities.

### Modified Capabilities

- `core-architecture`: Tightens the contract for the subagent channel storage key, the merge-time queue-drain behavior, the subagent fast-cleanup guard, the `JSONLTailer` offset accounting, and the question-queue deny payload. Five new ADDED REQUIREMENTS capture these contracts, plus a MODIFIED requirement on the JSONL tailer fragment cap that explicitly requires the offset advance to reflect post-truncation bytes. The CHANGELOG correction is a doc-only fix and is NOT reflected in any spec, since `CHANGELOG.md` is a release-notes artifact, not a spec.

## Impact

- **Code**:
  - `Sources/CodeIsland/AppState.swift` — `handleEvent` redirect (A), `applyCursorSubagentMerge` (G, H).
  - `Sources/CodeIslandCore/Models.swift` — `withRewritten` doc comment (B).
  - `Sources/CodeIslandCore/JSONLTailer.swift` — offset accounting (F).
  - `Sources/CodeIslandCore/SessionCleanup.swift` — `performSubagentFastCleanup` skip-merged-children guard (H).
  - `CHANGELOG.md` — v1.2.8 entry wording (C).
  - `Sources/CodeIsland/AppState.swift` — `enforceQuestionQueueCaps` deny payload (D).
- **APIs**: No public API changes. `HookEvent.withRewritten` signature and behavior are unchanged; only its doc comment is corrected (B).
- **Dependencies**: None. No new packages, no Swift version bump.
- **Tests**: Add regression tests for A (`testHandleEventRedirectUpdatesExistingSubagentKey`), G (`testMergeDrainsPendingPermissionQueue`), F (`testJSONLTailerOffsetAccountingWithTrailingTruncation`), H (`testFastCleanupSkipsMergedSubagents`).
- **Migration**: None. Existing user sessions and stored state are unaffected.
