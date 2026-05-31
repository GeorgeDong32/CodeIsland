## 1. Core Implementation

- [ ] 1.1 Add `dismissedQuestionSessionIds: Set<String>` property to AppState, following the existing `dismissedPermissionSessionIds` pattern
- [ ] 1.2 Rewrite `dismissQuestion()` to remove question from queue, record session ID in `dismissedQuestionSessionIds`, close surface, and call `showNextPending()` + `refreshDerivedState()` — without resuming the continuation
- [ ] 1.3 Update `dismissQuestion()` comment to reflect new semantics: "Dismiss question without sending response (just close UI, similar to dismissPermissionPrompt)"

## 2. Testing

- [ ] 2.1 Verify `swift test` passes with no regressions
- [ ] 2.2 Manual test: trigger AskUserQuestion card, click Dismiss, verify card closes and AI does not receive deny response
- [ ] 2.3 Manual test: trigger AskUserQuestion card, click Skip, verify deny response still sent as before
