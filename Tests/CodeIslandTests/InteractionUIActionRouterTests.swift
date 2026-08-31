import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class InteractionUIActionRouterTests: XCTestCase {
    private let session = SessionRef(provider: "claude", providerSessionID: "ui-session", generation: 1)

    private func makeRouter() -> (InteractionUIActionRouter, InteractionCenterStore, TransportToken, RequestID) {
        let store = InteractionCenterStore()
        let executor = RecordingInteractionEffectExecutor()
        let coordinator = InteractionCoordinator(store: store, executor: executor)
        let router = InteractionUIActionRouter(coordinator: coordinator)
        _ = router.send(.sessionObserved(SessionObservation(session: session, revision: 1)))
        let requestID = RequestID(session: session, upstreamID: "ui-request", kind: .permission)
        let token = TransportToken(session: session, rawValue: UUID())
        _ = router.send(.requestArrived(RequestArrival(
            id: requestID,
            session: session,
            kind: .permission,
            behavior: .blocking(ResolutionCapabilities()),
            content: .permission(PermissionContent(summary: "Run")),
            channel: .response(token)
        )))
        return (router, store, token, requestID)
    }

    func testShortcutRoutesTheProminentRequestThroughCenter() {
        let (router, _, _, requestID) = makeRouter()
        XCTAssertTrue(router.perform(.allowOnce))
        XCTAssertEqual(router.snapshot.local.requests[requestID]?.lifecycle, .resolving(router.snapshot.local.requests[requestID]!.lifecycle.effectID!))
    }

    func testStaleShortcutDoesNotFallThroughToAnotherRequest() {
        let (router, _, _, requestID) = makeRouter()
        _ = router.send(.user(.dismiss(requestID)))
        XCTAssertTrue(router.perform(.allowOnce))
        XCTAssertEqual(router.snapshot.local.requests[requestID]?.presentation, .dismissed)
        XCTAssertEqual(router.snapshot.local.requests[requestID]?.lifecycle, .pending)
    }
}

private extension RequestLifecycle {
    var effectID: EffectID? {
        if case let .resolving(effectID) = self { return effectID }
        if case let .awaitingExternalConfirmation(effectID) = self { return effectID }
        return nil
    }
}
