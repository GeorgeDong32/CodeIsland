## 1. Subagent Channel Key Alignment (Issue A)

- [ ] 1.1 In `Sources/CodeIsland/AppState.swift` `handleEvent` (around line 1025), change `event.withRewritten(sessionId: parentId, agentId: "auto-cwd-\(sessionId)")` to `event.withRewritten(sessionId: parentId, agentId: sessionId)` so the rewritten event's `agentId` matches the key used by `applyCursorSubagentMerge` when storing the subagent.
- [ ] 1.2 Verify that the existing test `testHandleEventRedirectsSubsequentEventsForMergedChildren` (added in `319d677`) still passes with the new key; if it was asserting on the prefixed key, update its assertion to use the raw childId.
- [ ] 1.3 Add a regression test `testHandleEventRedirectUpdatesExistingSubagentKey` in `Tests/CodeIslandCoreTests/CursorSubagentCollapseTests.swift` that asserts the redirect event lands on the pre-existing `parent.subagents[childId]` entry rather than creating a parallel one.

## 2. Merge-Time Queue Drain (Issue G)

- [ ] 2.1 In `Sources/CodeIsland/AppState.swift` `applyCursorSubagentMerge` (around line 1267), call `drainPermissions(forSession: childId, reason: "subagentMerge")` and `drainQuestions(forSession: childId, reason: "subagentMerge")` before `removeSession(childId)` so pending continuations are resumed with the existing `denyResponseData(for:)` payload.
- [ ] 2.2 Add a regression test `testMergeDrainsPendingPermissionQueue` in `Tests/CodeIslandCoreTests/CursorSubagentCollapseTests.swift` that seeds a child session with a pending permission, runs `applyCursorSubagentMerge`, and asserts the permission continuation was resumed with a deny payload.
- [ ] 2.3 Add a regression test `testMergeDrainsPendingQuestionQueue` in the same file, mirroring 2.2 for the question queue.

## 3. Subagent Fast-Cleanup Respects Active Redirects (Issue H)

- [ ] 3.1 In `Sources/CodeIslandCore/SessionCleanup.swift`, add an optional `mergedSessionIds: [String: String] = [:]` parameter to `performSubagentFastCleanup`; skip any subagent whose `agentId` is a key in the supplied map.
- [ ] 3.2 In `Sources/CodeIsland/AppState.swift` `cleanupIdleSessions` (around line 351), pass `mergedSessionIds: mergedSessionIds` to the call.
- [ ] 3.3 Add a regression test `testFastCleanupSkipsMergedSubagents` in `Tests/CodeIslandCoreTests/SubagentFastCleanupTests.swift` that seeds a parent with a merged child and asserts the subagent entry survives past the threshold while a non-merged sibling is cleaned up.

## 4. JSONL Tailer Offset Invariant Documentation (Issue F)

- [ ] 4.1 ~~In `Sources/CodeIslandCore/JSONLTailer.swift` (around line 233), change `watch.offset += off_t(combined.count - scan.trailingFragment.count)` to use the post-truncation `trailing` length.~~ **Dismissed after review** — the original formula is correct. The prefix-overflow branch trims `combined` to `maxPendingFragmentBytes` (M), so the trailing-fragment truncation branch is only reachable in the no-prefix-overflow case, where the line-229 advance and the line-233 advance are exactly complementary. Changing line 233 to use the post-truncation `trailing.count` would double-count the discarded tail bytes.
- [ ] 4.1 (carry-over) In `Sources/CodeIslandCore/JSONLTailer.swift` (around line 223-230), add a code comment explaining the invariant: the prefix-overflow branch trims `combined` to M, so the truncation branch is only reachable without prefix overflow, and the two offset advances are exactly complementary. (Done in the apply phase.)
- [ ] 4.2 Add a regression test `testJSONLTailerOffsetAccountingWithTrailingTruncation` that drives a fragment larger than `maxPendingFragmentBytes` and asserts `watch.offset` advances by `combined.count - maxPendingFragmentBytes`. (Carry-over from initial design; the reachable path is the no-prefix-overflow + trailing-truncation case only.)

## 5. Question-Queue Caps Use Codex-Aware Deny (Issue D)

- [ ] 5.1 In `Sources/CodeIsland/AppState.swift` `enforceQuestionQueueCaps` (around lines 2227-2237), replace each inline `Data(#"..."#)` deny literal with a call to `Self.denyResponseData(for: pending.event, message: pending.denyMessage)` (or the equivalent internal API) so the Codex branch is honored.
- [ ] 5.2 Add a regression test `testEnforceQuestionQueueCapsUsesCodexAwareDeny` in the appropriate test file that seeds a Codex question, exceeds the cap, and asserts the deny payload does not contain `suppressOutput: true`.

## 6. Documentation Corrections (Issues B, C)

- [ ] 6.1 In `Sources/CodeIslandCore/Models.swift` (around line 222), update the doc comment for `HookEvent.withRewritten(sessionId:agentId:)` to reference `AppState.applyCursorSubagentMerge()` instead of the non-existent `mergeIntoParentSessionIfMatches`.
- [ ] 6.2 In `CHANGELOG.md`, remove the phrase "and terminal context" from the v1.2.8 English section (line 8) and "和终端上下文" from the v1.2.8 Chinese section (line 15).

## 7. Validation and Release

- [ ] 7.1 Run `bash build.sh` (per the project's documented release-build script) and confirm a clean build with no warnings introduced by the changes.
- [ ] 7.2 Run `swift test` and confirm the new regression tests in §1-§5 pass and no existing test regresses.
- [ ] 7.3 Commit the changes following the project's commit-message format (`fix(subagent): ...`, `fix(tailer): ...`, `docs(changelog): ...`) and the mandatory non-auto-commit workflow (request user approval before each commit).
- [ ] 7.4 Bump the version (`chore(release): bump version to 1.2.9` — confirm with user before tagging) and push the release.
