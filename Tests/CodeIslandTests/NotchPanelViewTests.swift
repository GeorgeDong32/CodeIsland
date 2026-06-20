import XCTest
@testable import CodeIsland

final class NotchPanelViewTests: XCTestCase {
    func testShouldTriggerJumpFailureFeedbackWhenAllAttemptsFail() {
        XCTAssertTrue(shouldTriggerJumpFailureFeedback([false, false, false]))
    }

    func testShouldNotTriggerJumpFailureFeedbackWhenAnyAttemptSucceeds() {
        XCTAssertFalse(shouldTriggerJumpFailureFeedback([false, true, false]))
    }

    func testJumpFailureShakeSequenceUsesFastAlternatingOffsets() {
        XCTAssertEqual(JumpAnimationHelper.shakeSequence, [8, -8, 6, -6, 3, -3, 0])
    }

    func testEvaluateJumpValidationReturnsSuccessWhenCheckSucceeds() async {
        var callCount = 0
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { false },
            sleep: { _ in },
            checkSucceeded: {
                callCount += 1
                return callCount == 2
            }
        )

        XCTAssertEqual(outcome, .success)
    }

    func testEvaluateJumpValidationReturnsFailedWhenAllChecksFail() async {
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { false },
            sleep: { _ in },
            checkSucceeded: { false }
        )

        XCTAssertEqual(outcome, .failed)
    }

    func testEvaluateJumpValidationReturnsCancelledBeforeCheckRuns() async {
        var checksRan = 0
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { true },
            sleep: { _ in },
            checkSucceeded: {
                checksRan += 1
                return false
            }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(checksRan, 0)
    }

    func testClickJumpCollapseTimelineShowsClickRingWhenCursorReachesClickPoint() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.26)

        XCTAssertGreaterThan(timeline.expand, 0.95)
        XCTAssertTrue(timeline.showClickRing)
        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineMovesCursorToClickPointFaster() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.08)

        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineMovesCursorFullyOffscreenBeforeExpandStarts() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.80)

        XCTAssertEqual(timeline.cursorX, 34, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 28, accuracy: 0.001)
        XCTAssertLessThanOrEqual(timeline.expand, 0.001)
    }

    func testClickJumpCollapseTimelineStartsExpandAfterCursorIsAlreadyOffscreen() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.85)

        XCTAssertGreaterThan(timeline.expand, 0.3)
        XCTAssertEqual(timeline.cursorX, 34, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 28, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineUsesMouseLeaveLikeCollapseSpeed() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.38)

        XCTAssertGreaterThan(timeline.expand, 0.5)
        XCTAssertLessThan(timeline.expand, 0.7)
    }

    func testClickJumpCollapseTimelineUsesMouseLeaveLikeExpandSpeed() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.93)

        XCTAssertGreaterThanOrEqual(timeline.expand, 0.999)
    }

    func testClickJumpCollapseTimelineHoldsCollapsedStateForMiddleWindow() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.60)

        XCTAssertLessThanOrEqual(timeline.expand, 0.001)
        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineLoopSeamIsSmooth() {
        let start = clickJumpCollapsePreviewTimeline(progress: 0)
        let end = clickJumpCollapsePreviewTimeline(progress: 1)

        XCTAssertEqual(start.expand, end.expand, accuracy: 0.001)
        XCTAssertEqual(start.cursorX, end.cursorX, accuracy: 0.001)
        XCTAssertEqual(start.cursorY, end.cursorY, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineLowersClickPoint() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.26)
        XCTAssertEqual(timeline.clickPointY, 16.0, accuracy: 0.1)
    }

    // MARK: - AUTO APPROVE banner removal (change: remove-auto-approve-banner)
    //
    // The red "⏵⏵ AUTO APPROVE  点击禁用" banner used to be rendered inside the
    // approval card when isAutoApproveActive was true. It replaced Allow/Deny buttons
    // and frequently blocked normal per-tool approval. Removal verification:
    // (a) the hardcoded literal "AUTO APPROVE" no longer appears in the view source;
    // (b) the orange AUTO_APPROVE PixelButton (the manual entry point) is preserved.
    // These are source-level guards because no SwiftUI render test infrastructure exists
    // in the project (the existing tests are pure helper-function tests).

    private static let notchPanelSource: String = {
        // The file is part of the same SPM target; the test loads the source from the
        // path computed relative to the test bundle. Falls back to "" if unavailable.
        let bundlePath = Bundle(for: NotchPanelViewTests.self).bundlePath
        let candidates = [
            bundlePath + "/Sources/CodeIsland/NotchPanelView.swift",
            // Derived from the project's root when running tests via `swift test`
            bundlePath + "/../../../../Sources/CodeIsland/NotchPanelView.swift",
        ]
        for path in candidates {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                return contents
            }
        }
        return ""
    }()

    func testApprovalCardDoesNotRenderAutoApproveBannerInBypassMode() {
        // Fast-fail: the source-literal guards below would vacuously pass against
        // an empty source string (e.g. if the SPM bundle layout changes and the
        // path candidates stop resolving). Pin the resolution up-front so any
        // such regression fails loudly here instead of silently in the guards.
        XCTAssertFalse(
            Self.notchPanelSource.isEmpty,
            "Could not locate NotchPanelView.swift from the test bundle — the path candidates in `notchPanelSource` may need updating."
        )
        // Guard against regression: the red banner literal must not be reintroduced
        // anywhere in NotchPanelView.swift. The orange AUTO_APPROVE PixelButton uses
        // the L10n key "auto_approve" (lowercase, separate literal), which is allowed.
        XCTAssertFalse(
            Self.notchPanelSource.contains("\"AUTO APPROVE\""),
            "NotchPanelView.swift must not contain the hardcoded \"AUTO APPROVE\" banner literal"
        )
    }

    func testApprovalCardDoesNotRenderAutoApproveBannerInAutoMode() {
        XCTAssertFalse(
            Self.notchPanelSource.isEmpty,
            "Could not locate NotchPanelView.swift from the test bundle"
        )
        // Same guard; both bypassPermissions and auto triggered the deleted banner,
        // and both must remain banner-free. The literal is the same in both modes,
        // so a second test ensures both coverage paths are recorded in the suite.
        XCTAssertFalse(
            Self.notchPanelSource.contains("⏵⏵ AUTO APPROVE"),
            "NotchPanelView.swift must not contain the \"⏵⏵ AUTO APPROVE\" status-bar text"
        )
    }

    func testOrangeAutoApproveButtonIsPreservedAsEntryPoint() {
        XCTAssertFalse(
            Self.notchPanelSource.isEmpty,
            "Could not locate NotchPanelView.swift from the test bundle"
        )
        // The orange AUTO_APPROVE PixelButton (the manual entry point into AUTO mode
        // when isAutoApproveActive == false) must remain. Users without CLI-driven
        // auto mode still need a way to enter AUTO from the UI.
        XCTAssertTrue(
            Self.notchPanelSource.contains("L10n.shared[\"auto_approve\"]"),
            "NotchPanelView.swift must still expose the orange AUTO_APPROVE PixelButton as a manual entry point"
        )
    }

    func testSessionCardTapToDeactivateAutoApproveIsPreserved() {
        XCTAssertFalse(
            Self.notchPanelSource.isEmpty,
            "Could not locate NotchPanelView.swift from the test bundle"
        )
        // SessionCard top ⏵⵵ indicator's tap-to-deactivate must remain so users have
        // a discoverable way to exit AUTO after the banner is gone.
        XCTAssertTrue(
            Self.notchPanelSource.contains("appState.toggleAutoApprove(sessionId: sessionId)"),
            "NotchPanelView.swift must keep at least one call site of appState.toggleAutoApprove for SessionCard deactivation"
        )
    }

}
