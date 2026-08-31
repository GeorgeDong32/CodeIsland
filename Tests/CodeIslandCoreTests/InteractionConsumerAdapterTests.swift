import XCTest
@testable import CodeIslandCore

@MainActor
final class InteractionConsumerAdapterTests: XCTestCase {
    private let session = SessionRef(provider: "claude", providerSessionID: "session-1", generation: 3)

    private func request(
        id: RequestID,
        kind: InteractionRequestKind = .permission,
        title: String = "Run",
        actions: Set<ExternalActionKind> = [.allow, .deny]
    ) -> RedactedRequestSnapshot {
        RedactedRequestSnapshot(
            id: id,
            session: id.session,
            kind: kind,
            title: title,
            sensitivity: .public,
            pending: true,
            availableActionKinds: actions
        )
    }

    private func externalSnapshot(
        requests: [RequestID: RedactedRequestSnapshot],
        prominent: RequestID?
    ) -> RedactedInteractionSnapshot {
        RedactedInteractionSnapshot(
            requests: requests,
            presentation: RedactedPresentationSnapshot(
                surface: prominent.map(RedactedSurface.request) ?? .collapsed,
                prominentRequest: prominent
            )
        )
    }

    private func localSnapshot(
        requestID: RequestID?,
        request: InteractionRequestSnapshot?
    ) -> LocalInteractionSnapshot {
        LocalInteractionSnapshot(
            requests: request.map { [$0.id: $0] } ?? [:],
            presentation: PresentationSnapshot(
                surface: requestID.map(Surface.request) ?? .collapsed,
                prominentRequest: requestID
            )
        )
    }

    func testShortcutTargetsHighlightedRequestID() {
        let id = RequestID(session: session, upstreamID: "permission", kind: .permission)
        let local = localSnapshot(
            requestID: id,
            request: InteractionRequestSnapshot(
                id: id,
                session: session,
                kind: .permission,
                content: .permission(PermissionContent(summary: "Run")),
                lifecycle: .pending,
                presentation: .normal,
                availableActions: [.allowOnce, .allowAlways, .deny]
            )
        )

        guard case let .action(.user(.resolve(target, .allowOnce))) = InteractionShortcutAdapter().decision(.allowOnce, snapshot: local) else {
            return XCTFail("shortcut must produce a RequestID-scoped action")
        }
        XCTAssertEqual(target, id)
    }

    func testShortcutWithoutProminentRequestIsNoOp() {
        let decision = InteractionShortcutAdapter().decision(.allowOnce, snapshot: localSnapshot(requestID: nil, request: nil))
        XCTAssertEqual(decision, .ignored(.noProminentRequest))
    }

    func testShortcutNeverAllowsAlwaysForUnavailableRequest() {
        let id = RequestID(session: session, upstreamID: "permission", kind: .permission)
        let local = localSnapshot(
            requestID: id,
            request: InteractionRequestSnapshot(
                id: id, session: session, kind: .permission,
                content: .permission(PermissionContent(summary: "Run")),
                lifecycle: .pending, presentation: .normal,
                availableActions: [.allowOnce, .deny]
            )
        )
        XCTAssertEqual(
            InteractionShortcutAdapter().decision(.allowAlways, snapshot: local),
            .ignored(.unavailableAction)
        )
    }

    func testAppleNewCommandRequiresMatchingRequestAndGeneration() {
        let id = RequestID(session: session, upstreamID: "permission", kind: .permission)
        let snapshot = externalSnapshot(requests: [id: request(id: id)], prominent: id)
        let adapter = AppleCompanionCompatibilityAdapter()
        let matching = AppleCompanionCommandPayload(
            protocolMajor: 1,
            type: .approveCurrentPermission,
            sessionId: "session-1",
            sessionGeneration: 3,
            requestID: id,
            observedSequence: 8
        )
        guard case let .action(.user(.resolve(target, .allowOnce))) = adapter.decision(matching, snapshot: snapshot, latestSequence: 8) else {
            return XCTFail("matching companion action should be accepted")
        }
        XCTAssertEqual(target, id)

        let stale = AppleCompanionCommandPayload(
            protocolMajor: 1,
            type: .approveCurrentPermission,
            sessionId: "session-1",
            sessionGeneration: 2,
            requestID: id,
            observedSequence: 8
        )
        XCTAssertEqual(adapter.decision(stale, snapshot: snapshot, latestSequence: 8), .ignored(.staleRequest))
    }

    func testAppleStateCarriesAdditiveIdentityAndVersionFields() throws {
        let id = RequestID(session: session, upstreamID: "permission", kind: .permission)
        let payload = AppleCompanionStatePayload(
            protocolMajor: 1,
            protocolMinor: 2,
            sequence: 12,
            sessionId: "session-1",
            source: "claude",
            status: .waitingApproval,
            toolName: nil,
            workspaceName: "Project",
            messages: [],
            pendingAction: .approval,
            pendingRequestID: id,
            pendingRequestKind: .permission,
            sessionGeneration: 3,
            lastAcceptedSequence: 11
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AppleCompanionStatePayload.self, from: data)
        XCTAssertEqual(decoded.protocolMajor, 1)
        XCTAssertEqual(decoded.protocolMinor, 2)
        XCTAssertEqual(decoded.pendingRequestID, id)
        XCTAssertEqual(decoded.sessionGeneration, 3)
        XCTAssertEqual(decoded.lastAcceptedSequence, 11)
    }

    func testExternalProjectionsNeverSerializeSecretQuestionOrLocalRoute() throws {
        let id = RequestID(session: session, upstreamID: "secret", kind: .question)
        let external = externalSnapshot(
            requests: [id: RedactedRequestSnapshot(
                id: id,
                session: session,
                kind: .question,
                title: "Question (redacted)",
                sensitivity: .secret,
                pending: true,
                availableActionKinds: [.answer]
            )],
            prominent: id
        )
        let payload = AppleCompanionStatePayload(sequence: 1, snapshot: external)
        let data = try JSONEncoder().encode(payload)
        let wire = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(wire.contains("secret prompt"))
        XCTAssertFalse(wire.contains("cwd"))
        XCTAssertFalse(wire.contains("terminal"))
        XCTAssertTrue(wire.contains("Question (redacted)"))

        let buddy = ESP32RedactedProjection(snapshot: external)
        XCTAssertNil(buddy.workspaceLabel)
        XCTAssertEqual(buddy.status, .waitingQuestion)
    }

    func testAppleUnknownMajorAndStaleSequenceAreRejectedBeforeAction() {
        let id = RequestID(session: session, upstreamID: "permission", kind: .permission)
        let snapshot = externalSnapshot(requests: [id: request(id: id)], prominent: id)
        let adapter = AppleCompanionCompatibilityAdapter()
        let unknown = AppleCompanionCommandPayload(protocolMajor: 2, type: .approveCurrentPermission, requestID: id)
        XCTAssertEqual(adapter.decision(unknown, snapshot: snapshot, latestSequence: 1), .ignored(.unsupportedMajor))

        let stale = AppleCompanionCommandPayload(protocolMajor: 1, type: .approveCurrentPermission, requestID: id, observedSequence: 2)
        XCTAssertEqual(adapter.decision(stale, snapshot: snapshot, latestSequence: 3), .ignored(.staleSequence))
    }

    func testAppleLegacyCommandOnlyTargetsOneVisibleRequest() {
        let first = RequestID(session: session, upstreamID: "first", kind: .permission)
        let secondSession = SessionRef(provider: "codex", providerSessionID: "session-2", generation: 1)
        let second = RequestID(session: secondSession, upstreamID: "second", kind: .permission)
        let adapter = AppleCompanionCompatibilityAdapter()
        let command = AppleCompanionCommandPayload(type: .approveCurrentPermission)

        let ambiguous = externalSnapshot(
            requests: [first: request(id: first), second: request(id: second)],
            prominent: nil
        )
        XCTAssertEqual(adapter.decision(command, snapshot: ambiguous), .ignored(.legacyCommandRequiresUniqueVisibleTarget))

        let unique = externalSnapshot(requests: [first: request(id: first)], prominent: first)
        guard case let .action(.user(.resolve(target, .allowOnce))) = adapter.decision(command, snapshot: unique) else {
            return XCTFail("legacy command should target the one displayed request")
        }
        XCTAssertEqual(target, first)
        XCTAssertEqual(adapter.decision(command, snapshot: unique), .ignored(.duplicateCommand))
    }

    func testAppleLegacySkipDoesNotBecomeGenericResolution() {
        let id = RequestID(session: session, upstreamID: "question", kind: .question)
        let snapshot = externalSnapshot(
            requests: [id: request(id: id, kind: .question, actions: [.answer])],
            prominent: id
        )
        XCTAssertEqual(
            AppleCompanionCompatibilityAdapter().decision(.init(type: .skipCurrentQuestion), snapshot: snapshot),
            .ignored(.unavailableAction)
        )
    }

    func testESP32LegacyControlsAreNarrowAndRequestIDScoped() {
        let first = RequestID(session: session, upstreamID: "first", kind: .permission)
        let adapter = ESP32LegacyActionAdapter()
        let snapshot = externalSnapshot(requests: [first: request(id: first)], prominent: first)
        guard case let .action(.user(.resolve(target, .allowOnce))) = adapter.decision(.approveCurrentPermission, snapshot: snapshot) else {
            return XCTFail("Buddy approve must resolve the one displayed request")
        }
        XCTAssertEqual(target, first)

        let second = RequestID(session: session, upstreamID: "second", kind: .permission)
        let ambiguous = externalSnapshot(
            requests: [first: request(id: first), second: request(id: second)],
            prominent: nil
        )
        XCTAssertEqual(adapter.decision(.approveCurrentPermission, snapshot: ambiguous), .ignored(.ambiguousTarget))
        XCTAssertEqual(adapter.decision(.skipCurrentQuestion, snapshot: snapshot), .ignored(.unavailableAction))
    }
}
