# Tasks — Remove AUTO APPROVE Banner

## 1. Confirm Pre-Removal Invariants

- [x] 1.1 Run `grep -nE "isAutoApproveActive|toggleAutoApprove" Sources/CodeIsland/` and record all call sites in `design.md` open questions (already noted). Confirm SessionCard tap-to-deactivate is wired so the changelog can direct users there.
- [x] 1.2 Run `grep -nE "click_to_disable" Sources/CodeIsland/` to confirm the localization key has only the two expected references (NotchPanelView banner body and L10n bundle) before deletion.
- [x] 1.3 Verify `swift test` baseline is green (all 280 tests passing) before any code change.

## 2. Remove Banner UI in NotchPanelView

- [x] 2.1 Delete the `if isAutoApproveActive { ... }` SwiftUI block at `Sources/CodeIsland/NotchPanelView.swift` lines 1036-1061. Leave the `else if tool == "ExitPlanMode"` and subsequent branches intact.
- [x] 2.2 KEEP the `isAutoApproveActive` computed property at `Sources/CodeIsland/NotchPanelView.swift` lines 972-975 — it is still consumed by the view-side `toggleAutoApprove()` helper (line 1183: `let wasActive = isAutoApproveActive`).
- [x] 2.3 KEEP the view-side `toggleAutoApprove()` helper at `Sources/CodeIsland/NotchPanelView.swift` lines 1179-1186 — still wired to the orange AUTO_APPROVE button (line 1160, the manual entry point when `isAutoApproveActive == false`). Grep confirmed 3 view-side call sites: line 1037 (red bar, to be deleted), 1160 (orange button), 2162 (SessionCard ⏵⏵ indicator).

## 3. Confirm AppState Surface Is Untouched

- [x] 3.1 Verify `AppState.swift:1010-1029` (`permissionMode` sync) is unchanged: `autoApproveSessionId`, `autoApproveModeSnapshot` still set/cleared as before. (Grep 1.1 confirmed `autoApproveSessionId` and `autoApproveModeSnapshot` still in `AppState.swift`; no source edits were made to `AppState.swift`.)
- [x] 3.2 Verify `AppState.swift:1419-1448` (`flushPendingPermissionsForAutoApprove`) and `AppState.swift:1392-1417` (`toggleAutoApprove`) are unchanged. `HookServer.swift:376` still calls `appState.isAutoApproveActive(for: sessionId)` for the `setMode: bypassPermissions` path. (Grep confirmed all references intact; no source edits.)
- [x] 3.3 Verify `AppState.swift:1369-1374` (`isAutoApproveActive(for:)`) is unchanged — it is still needed by `HookServer.swift:376` and the orange AUTO_APPROVE button view path. (Confirmed by grep; no source edits.)

## 4. Add Regression Test

- [x] 4.1 Add a new test in `Tests/CodeIslandTests/NotchPanelViewTests.swift` (or a new `Tests/CodeIslandTests/ApprovalCardContentTests.swift` if the existing file is topic-mismatched) that renders the approval card body for a sample session with `permissionMode = "bypassPermissions"` and asserts the rendered body does NOT contain the literal substring `"AUTO APPROVE"`. Test name: `testApprovalCardDoesNotRenderAutoApproveBannerInBypassMode`. **Implemented as source-level literal guard** (`"AUTO APPROVE"` and `⏵⏵ AUTO APPROVE` substring scans in `NotchPanelView.swift`) because the project has no SwiftUI render test infrastructure. Plus two positive guards: orange button preserved (`L10n.shared["auto_approve"]` still present) and SessionCard tap-to-deactivate preserved (`appState.toggleAutoApprove(sessionId:)` still called).
- [x] 4.2 Add a complementary test for `permissionMode = "auto"` (test name: `testApprovalCardDoesNotRenderAutoApproveBannerInAutoMode`) to cover both code paths that previously triggered the banner. **Implemented as `testApprovalCardDoesNotRenderAutoApproveBannerInAutoMode`** with the `⏵⏵ AUTO APPROVE` substring check.
- [x] 4.3 Run `swift test` and confirm all tests pass (expect 282 with the two new tests). **Result: 284/284 passed, 0 failures** (280 + 4 new tests, since I added two additional positive guards for the orange button and SessionCard deactivation).

## 5. Update CHANGELOG and Version

- [x] 5.1 Add a `### Fix` entry to `CHANGELOG.md` describing the banner removal. Reference the SessionCard top ⏵⵵ indicator as the replacement UI hint. Include both English and Chinese sections.
- [x] 5.2 Confirm version: the change ships in the next released version. No version bump required for this commit unless paired with other release work.

## 6. Manual Verification

- [x] 6.1 Build: `./build.sh` exits 0, bundle verification passes.
- [ ] 6.2 Launch: `open .build/release/CodeIsland.app` starts the app.
- [ ] 6.3 Trigger a `Bash` `PermissionRequest` event with `permissionMode = auto`: approval card shows Allow / Deny / Always buttons, no red bar.
- [ ] 6.4 Trigger a `Bash` `PermissionRequest` event with `permissionMode = bypassPermissions`: same as 6.3, plus SessionCard ⏵⏵ red indicator is visible in the session header.
- [ ] 6.5 Trigger an `ExitPlanMode` `PermissionRequest`: Plan approval options visible, no red bar.
- [ ] 6.6 Tap the SessionCard top ⏵⵵ indicator and confirm AUTO deactivates (visual feedback — indicator color/icon changes; underlying `autoApproveSessionId` cleared).
