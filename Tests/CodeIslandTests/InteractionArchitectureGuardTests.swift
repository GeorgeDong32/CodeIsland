import Foundation
import XCTest

/// Static architecture checks for the upstream/fork boundary.
///
/// These checks intentionally inspect source instead of reaching into runtime
/// implementation details. They make the seam budget executable while keeping
/// the production owner in one explicit installation point.
final class InteractionArchitectureGuardTests: XCTestCase {
    private enum Hotspot: String, CaseIterable {
        case appState = "Sources/CodeIsland/AppState.swift"
        case hookServer = "Sources/CodeIsland/HookServer.swift"
        case notchPanel = "Sources/CodeIsland/NotchPanelView.swift"
        case sessionSnapshot = "Sources/CodeIslandCore/SessionSnapshot.swift"
    }

    private var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // CodeIslandTests
        url.deleteLastPathComponent() // Tests
        url.deleteLastPathComponent() // repository root
        return url
    }

    private func source(_ hotspot: Hotspot) throws -> String {
        try String(contentsOf: root.appendingPathComponent(hotspot.rawValue), encoding: .utf8)
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func occurrences(of marker: String, in text: String) -> Int {
        text.components(separatedBy: marker).count - 1
    }

    func testUpstreamHotspotsStayWithinSingleForkSeamBudget() throws {
        // A zero count is the current, deliberate state: Phase 7's adaptive
        // policy is not wired into production consumers before Phase 6 cutover.
        // A future production integration must still be a single contiguous
        // seam and may not fan out policy logic across these files.
        let budgets: [Hotspot: Int] = [
            .appState: 1,
            .hookServer: 1,
            .notchPanel: 1,
            .sessionSnapshot: 0
        ]
        let seamMarkers = ["InteractionCenter", "PresentationPolicy", "VisibilityObservation"]

        for hotspot in Hotspot.allCases {
            let text = try source(hotspot)
            let count = seamMarkers.reduce(0) { $0 + occurrences(of: $1, in: text) }
            XCTAssertLessThanOrEqual(count, budgets[hotspot]!, "\(hotspot.rawValue) exceeded its fork seam budget")
        }
    }

    func testNotchPanelHasNoDirectTerminalActivationOrRawProjection() throws {
        let text = try source(.notchPanel)
        XCTAssertFalse(text.contains("TerminalActivator.activate"))
        XCTAssertFalse(text.contains("rawJSON"))
        XCTAssertFalse(text.contains("JSONSerialization"))
        XCTAssertFalse(text.contains("RedactedInteractionSnapshot"))
    }

    func testHookServerDoesNotOwnForkPresentationOrExternalProjection() throws {
        let text = try source(.hookServer)
        XCTAssertFalse(text.contains("PresentationPolicy"))
        XCTAssertFalse(text.contains("VisibilityObservation"))
        XCTAssertFalse(text.contains("RedactedInteractionSnapshot"))
        XCTAssertFalse(text.contains("InteractionSnapshot"))
    }

    func testSessionSnapshotContainsNoNewForkOnlyStateFields() throws {
        let text = try source(.sessionSnapshot)
        // These names represent Center-owned lifecycle/presentation state.  The
        // two legacy fields are intentionally still present during migration;
        // their removal belongs to the Phase 5/6 owner and is tracked as a
        // production-cutover dependency rather than silently changing here.
        let forbiddenForkFields = [
            "permissionQueue", "questionQueue", "dismissedPermission",
            "dismissedQuestion", "autoApproveSession", "requestedMode",
            "transportToken", "requestID", "visibilityObservation"
        ]
        for field in forbiddenForkFields {
            XCTAssertFalse(text.contains(field), "SessionSnapshot gained fork-only field \(field)")
        }
    }

    func testAdaptivePolicyIsNotEnabledBeforePhase6Cutover() throws {
        for hotspot in Hotspot.allCases {
            let text = try source(hotspot)
            XCTAssertFalse(text.contains("adaptiveCLI"), "adaptive policy leaked into \(hotspot.rawValue)")
            XCTAssertFalse(text.contains("adaptiveCLIFirst"), "adaptive mode leaked into \(hotspot.rawValue)")
        }
        let policySource = try source("Sources/CodeIslandCore/InteractionVisibility.swift")
        XCTAssertTrue(policySource.contains("adaptiveCLIFirst"))
        XCTAssertTrue(policySource.contains("legacyProminent"))
    }

    func testProductionOwnerExplicitlyEnablesAdaptivePolicy() throws {
        let appDelegate = try source("Sources/CodeIsland/AppDelegate.swift")
        XCTAssertEqual(occurrences(of: "presentationPolicy: .adaptiveCLI()", in: appDelegate), 1)
        XCTAssertTrue(appDelegate.contains("InteractionCoordinator(store: store, executor: executor)"))
    }
}
