import XCTest
@testable import CodeIslandCore

@MainActor
final class InteractionVisibilityTests: XCTestCase {
    private let session = SessionRef(provider: "claude", providerSessionID: "s1", generation: 7)
    private let measuredAt = Date(timeIntervalSince1970: 1_000)

    func testObservationCarriesGenerationRevisionEvidenceTimestampAndMaxAge() throws {
        let observation = VisibilityObservation(
            session: session,
            state: .visible,
            evidence: .terminalTab,
            revision: 42,
            measuredAt: measuredAt,
            maxAge: .seconds(3)
        )

        XCTAssertEqual(observation.session.generation, 7)
        XCTAssertEqual(observation.revision, 42)
        XCTAssertEqual(observation.evidence, .terminalTab)
        XCTAssertEqual(observation.measuredAt, measuredAt)
        XCTAssertEqual(observation.maxAge.timeInterval, 3, accuracy: 0.000_001)

        let encoded = try JSONEncoder().encode(observation)
        let decoded = try JSONDecoder().decode(VisibilityObservation.self, from: encoded)
        XCTAssertEqual(decoded, observation)
    }

    func testAdaptivePolicyShowsOnlyFreshVisibleSessionsAsBadgeOnly() {
        let policy = PresentationPolicy.adaptiveCLI(visibilityMaxAge: .seconds(5))
        let now = measuredAt.addingTimeInterval(4)

        XCTAssertEqual(policy.automaticPresentation(for: observation(.visible, evidence: .terminalTab, maxAge: .seconds(10)), now: now), .badgeOnly)
        XCTAssertEqual(policy.automaticPresentation(for: observation(.notVisible, evidence: .terminalTab), now: now), .prominent)
        XCTAssertEqual(policy.automaticPresentation(for: observation(.unknown, evidence: .unavailable), now: now), .prominent)
        XCTAssertEqual(policy.automaticPresentation(for: nil, now: now), .prominent)
    }

    func testObservationMaxAgeAndPolicyMaximumAgeExpireVisibility() {
        let policy = PresentationPolicy.adaptiveCLI(visibilityMaxAge: .seconds(5))
        let visible = observation(.visible, evidence: .terminalFrontmost, maxAge: .seconds(3))

        XCTAssertFalse(visible.isExpired(at: measuredAt.addingTimeInterval(3), policyMaximumAge: policy.visibilityMaxAge))
        XCTAssertTrue(visible.isExpired(at: measuredAt.addingTimeInterval(3.1), policyMaximumAge: policy.visibilityMaxAge))

        let policyExpiresFirst = observation(.visible, evidence: .terminalFrontmost, maxAge: .seconds(30))
        XCTAssertEqual(policy.automaticPresentation(for: policyExpiresFirst, now: measuredAt.addingTimeInterval(5.1)), .prominent)
        XCTAssertEqual(policyExpiresFirst.state(at: measuredAt.addingTimeInterval(-0.1)), .unknown)
    }

    func testLegacyCheckpointRemainsProminentAndAdaptiveSwitchIsExplicit() {
        let visible = observation(.visible, evidence: .nativeAppFrontmost, maxAge: .seconds(30))
        let now = measuredAt.addingTimeInterval(1)

        XCTAssertEqual(PresentationPolicy().mode, .legacyProminent)
        XCTAssertEqual(PresentationPolicy.legacyCheckpoint.mode, .legacyProminent)
        XCTAssertEqual(PresentationPolicy.legacyCheckpoint.automaticPresentation(for: visible, now: now), .prominent)
        XCTAssertEqual(PresentationPolicy.adaptiveCLI().mode, .adaptiveCLIFirst)
        XCTAssertEqual(PresentationPolicy.adaptiveCLI().automaticPresentation(for: visible, now: now), .badgeOnly)
    }

    func testAdaptiveCenterUsesExplicitRevealForVisibleRequest() {
        let clock = TestClock(measuredAt)
        let sessionObservation = SessionObservation(
            session: session,
            cliVisibility: .visible,
            revision: 1,
            observedAt: measuredAt
        )
        let store = InteractionCenterStore(dependencies: InteractionCenterDependencies(
            clock: clock,
            idFactory: DeterministicIDFactory(),
            presentationPolicy: .adaptiveCLI(visibilityMaxAge: .seconds(5))
        ))
        _ = store.send(.sessionObserved(sessionObservation))

        let request = RequestID(session: session, upstreamID: "permission-1", kind: .permission)
        _ = store.send(.requestArrived(RequestArrival(
            id: request,
            session: session,
            kind: .permission,
            behavior: .blocking(ResolutionCapabilities()),
            content: .permission(PermissionContent(summary: "Run")),
            channel: .response(TransportToken(session: session, rawValue: UUID()))
        )))
        XCTAssertNil(store.snapshot.local.presentation.prominentRequest)

        _ = store.send(.user(.reveal(request)))
        XCTAssertEqual(store.snapshot.local.presentation.prominentRequest, request)
    }

    func testAdaptiveCenterRevealsWhenVisibleObservationExpires() {
        let clock = TestClock(measuredAt)
        let store = InteractionCenterStore(dependencies: InteractionCenterDependencies(
            clock: clock,
            idFactory: DeterministicIDFactory(),
            presentationPolicy: .adaptiveCLI(visibilityMaxAge: .seconds(30))
        ))
        _ = store.send(.sessionObserved(SessionObservation(session: session, revision: 1, observedAt: measuredAt)))
        _ = store.send(.visibilityChanged(VisibilityObservation(
            session: session,
            state: .visible,
            evidence: .terminalTab,
            revision: 2,
            measuredAt: measuredAt,
            maxAge: .seconds(2)
        )))

        let request = RequestID(session: session, upstreamID: "permission-2", kind: .permission)
        _ = store.send(.requestArrived(RequestArrival(
            id: request,
            session: session,
            kind: .permission,
            behavior: .blocking(ResolutionCapabilities()),
            content: .permission(PermissionContent(summary: "Run")),
            channel: .response(TransportToken(session: session, rawValue: UUID()))
        )))
        XCTAssertNil(store.snapshot.local.presentation.prominentRequest)

        clock.advance(by: .seconds(3))
        // Any subsequent input rebuilds the read model from the same clock; an
        // expired observation must no longer suppress a pending request.
        _ = store.send(.expireBufferedRequests(clock.now))
        XCTAssertEqual(store.snapshot.local.presentation.prominentRequest, request)
    }

    private func observation(
        _ state: CLIVisibility,
        evidence: VisibilityEvidence,
        maxAge: Duration = .seconds(5)
    ) -> VisibilityObservation {
        VisibilityObservation(
            session: session,
            state: state,
            evidence: evidence,
            revision: 1,
            measuredAt: measuredAt,
            maxAge: maxAge
        )
    }
}
