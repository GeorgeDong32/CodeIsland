import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class SessionNavigatorTests: XCTestCase {
    func testProductionValidationUsesHistoricalThreeRetryDelays() {
        XCTAssertEqual(
            SessionNavigationSettings.production.validationDelays,
            [120_000_000, 320_000_000, 640_000_000]
        )
    }

    func testNavigatorPreservesTargetIDAndValidationRetrySchedule() async {
        let activator = RecordingActivator()
        let visibility = ScriptedVisibility(results: [false, true])
        let feedback = RecordingNavigationFeedback()
        let navigator = SessionNavigator(
            activator: activator,
            visibility: visibility,
            feedback: feedback,
            settings: SessionNavigationSettings(validationDelays: [0, 0, 0])
        )
        var session = SessionSnapshot()
        session.cwd = "/tmp/project"

        let result = await navigator.navigate(
            target: SessionNavigationTarget(session: session, sessionId: "session-a"),
            collapsePolicy: .afterSuccess
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(activator.calls, ["session-a"])
        XCTAssertEqual(visibility.sessions, ["/tmp/project", "/tmp/project"])
        XCTAssertEqual(feedback.failureCount, 0)
    }

    func testNavigatorReportsFailureAfterAllThreeChecksAndOnlyOnce() async {
        let activator = RecordingActivator()
        let visibility = ScriptedVisibility(results: [false, false, false])
        let feedback = RecordingNavigationFeedback()
        let navigator = SessionNavigator(
            activator: activator,
            visibility: visibility,
            feedback: feedback,
            settings: SessionNavigationSettings(validationDelays: [0, 0, 0])
        )
        let session = SessionSnapshot()

        let result = await navigator.navigate(
            target: SessionNavigationTarget(session: session, sessionId: "session-b"),
            collapsePolicy: .afterSuccess
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(activator.calls, ["session-b"])
        XCTAssertEqual(visibility.checkCount, 3)
        XCTAssertEqual(feedback.failureCount, 1)
    }

    func testRemoteSessionIsUnavailableWithoutCallingLocalPorts() async {
        let activator = RecordingActivator()
        let visibility = ScriptedVisibility(results: [true])
        let feedback = RecordingNavigationFeedback()
        let navigator = SessionNavigator(
            activator: activator,
            visibility: visibility,
            feedback: feedback,
            settings: SessionNavigationSettings(validationDelays: [0])
        )
        var session = SessionSnapshot()
        session.remoteHostId = "remote-host"

        let result = await navigator.navigate(
            target: SessionNavigationTarget(session: session, sessionId: "remote"),
            collapsePolicy: .afterSuccess
        )

        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(activator.calls.isEmpty)
        XCTAssertEqual(visibility.checkCount, 0)
        XCTAssertEqual(feedback.failureCount, 0)
    }

    func testValidationCanBeDisabledWithoutAVisibilityProbe() async {
        let activator = RecordingActivator()
        let visibility = ScriptedVisibility(results: [false])
        let feedback = RecordingNavigationFeedback()
        let navigator = SessionNavigator(
            activator: activator,
            visibility: visibility,
            feedback: feedback,
            settings: SessionNavigationSettings(validationDelays: [0, 0, 0])
        )

        let result = await navigator.navigate(
            target: SessionNavigationTarget(session: SessionSnapshot(), sessionId: "no-collapse"),
            collapsePolicy: .never
        )

        XCTAssertEqual(result, .activated)
        XCTAssertEqual(activator.calls, ["no-collapse"])
        XCTAssertEqual(visibility.checkCount, 0)
        XCTAssertEqual(feedback.failureCount, 0)
    }

    func testBeginCanBeCancelledBeforeValidationCompletes() async {
        let activator = RecordingActivator()
        let visibility = ScriptedVisibility(results: [false, false, false])
        let feedback = RecordingNavigationFeedback()
        let navigator = SessionNavigator(
            activator: activator,
            visibility: visibility,
            feedback: feedback,
            settings: SessionNavigationSettings(validationDelays: [50_000_000_000])
        )
        var results: [SessionNavigationResult] = []
        let operationID = navigator.begin(
            target: SessionNavigationTarget(session: SessionSnapshot(), sessionId: "cancelled"),
            collapsePolicy: .afterSuccess,
            onResult: { results.append($0) }
        )

        await Task.yield()
        navigator.cancel(operationID: operationID)
        await Task.yield()

        XCTAssertEqual(activator.calls, ["cancelled"])
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(feedback.failureCount, 0)
    }
}

private final class RecordingActivator: TerminalActivationPort {
    var calls: [String] = []

    func activate(session: SessionSnapshot, sessionId: String?) {
        if let sessionId { calls.append(sessionId) }
    }
}

private final class ScriptedVisibility: TerminalVisibilityPort {
    var results: [Bool]
    var index = 0
    var sessions: [String] = []

    init(results: [Bool]) {
        self.results = results
    }

    var checkCount: Int { index }

    func isVisible(session: SessionSnapshot) async -> Bool {
        sessions.append(session.cwd ?? "")
        defer { index += 1 }
        return results.indices.contains(index) ? results[index] : false
    }
}

@MainActor
private final class RecordingNavigationFeedback: NavigationFeedbackPort {
    var failureCount = 0

    func navigationFailed(for target: SessionNavigationTarget) {
        failureCount += 1
    }
}
