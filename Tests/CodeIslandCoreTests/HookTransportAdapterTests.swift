import Foundation
import XCTest
@testable import CodeIslandCore

@MainActor
final class HookTransportAdapterTests: XCTestCase {
    private let session = SessionRef(provider: "claude", providerSessionID: "hook-session", generation: 1)

    func testNormalizerPreservesEventAliasesAndUsesStableToolIdentity() throws {
        let normalizer = HookRequestNormalizer(configuration: HookAdmissionConfiguration(
            autoApproveTools: ["InternalTool"],
            autoApprovedSources: ["antigravity"]
        ), idFactory: DeterministicIDFactory())
        let event = try makeEvent([
            "hook_event_name": "permission_request",
            "session_id": "s1",
            "_source": "google-antigravity",
            "tool_name": "Bash",
            "tool_use_id": "tool-1",
            "tool_input": ["command": "echo hi"]
        ])

        let normalized = normalizer.normalize(event, responseHandle: ProviderResponseHandle(UUID()))
        XCTAssertEqual(normalized.event.branch, .regularPermission)
        XCTAssertEqual(normalized.event.provider, ProviderID("google-antigravity"))
        XCTAssertEqual(normalized.event.sessionKey.providerSessionID, "s1")
        XCTAssertEqual(normalized.responseHandle?.rawValue, normalized.responseHandle?.rawValue)
        guard case let .stable(key) = normalized.correlation else {
            return XCTFail("tool ID must create a stable correlation")
        }
        XCTAssertEqual(key.upstreamID, "tool-1")
        XCTAssertEqual(key.kind, .permission)
    }

    func testAskUserQuestionCannotBeHiddenByAlwaysProceedOrToolAllowList() throws {
        let normalizer = HookRequestNormalizer(configuration: HookAdmissionConfiguration(
            autoApproveTools: ["AskUserQuestion"],
            autoApprovedSources: ["claude"]
        ))
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "_source": "claude",
            "tool_name": "AskUserQuestion",
            "tool_use_id": "q1",
            "tool_input": ["question": "Continue?", "options": ["Yes", "No"]]
        ])

        let normalized = normalizer.normalize(event)
        XCTAssertEqual(normalized.event.branch, .askUserQuestion)
        guard case let .question(content)? = normalized.event.content else {
            return XCTFail("AskUserQuestion must produce typed question content")
        }
        XCTAssertEqual(content.answerSchema.keysInProviderOrder, ["answer"])
    }

    func testNoIDArrivalUsesAnOccurrenceInsteadOfContentFingerprint() throws {
        let factory = DeterministicIDFactory()
        let normalizer = HookRequestNormalizer(idFactory: factory)
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_input": ["command": "echo same"]
        ])

        let first = normalizer.normalize(event)
        let second = normalizer.normalize(event)
        guard case let .occurrence(one) = first.correlation,
              case let .occurrence(two) = second.correlation else {
            return XCTFail("missing IDs must use occurrence identity")
        }
        XCTAssertNotEqual(one, two)
    }

    func testRequestBeforeObservationBindsOneTokenInArrivalOrder() throws {
        let ids = DeterministicIDFactory()
        let authority = InMemorySessionGenerationAuthority()
        let buffer = InMemoryRequestIngressBuffer(idFactory: ids)
        let registry = HookTransportRegistry(clock: TestClock())
        let adapter = HookInteractionAdapter(
            generationAuthority: authority,
            ingressBuffer: buffer,
            transportRegistry: registry,
            idFactory: ids
        )
        let responder = InMemoryOnceResponder<HookWireResponse>()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_use_id": "tool-1",
            "tool_input": ["command": "echo hi"]
        ])
        let handle = ProviderResponseHandle(UUID())
        let result = adapter.receive(event, responseHandle: handle, responder: responder)
        guard case .buffered = result else {
            return XCTFail("request without an observed generation must be buffered")
        }

        let binding = try XCTUnwrap(adapter.apply(SessionIdentityFact(
            key: SessionKey(provider: "claude", providerSessionID: "s1"),
            lifecycle: .opened,
            evidence: .initialOpen,
            sequence: 1
        )))
        XCTAssertEqual(binding.arrivals.count, 1)
        guard case let .stable(stableKey)? = binding.arrivals.first?.id.correlation else {
            return XCTFail("buffered stable identity must survive generation binding")
        }
        XCTAssertEqual(stableKey.upstreamID, "tool-1")
        guard case let .response(token)? = binding.arrivals.first?.channel else {
            return XCTFail("binding must create one opaque response token")
        }
        XCTAssertTrue(registry.isRegistered(token))
        XCTAssertTrue(responder.responses.isEmpty)
    }

    func testCurrentObservationRegistersOpaqueTokenAndExecutorSendsTypedAck() throws {
        let ids = DeterministicIDFactory()
        let authority = InMemorySessionGenerationAuthority()
        _ = authority.apply(SessionIdentityFact(key: session.key, lifecycle: .opened, evidence: .initialOpen, sequence: 1))
        let registry = HookTransportRegistry(clock: TestClock())
        let adapter = HookInteractionAdapter(generationAuthority: authority, transportRegistry: registry, idFactory: ids)
        let sink = RecordingHookSink()
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": session.key.providerSessionID,
            "tool_name": "Bash",
            "tool_use_id": "tool-1",
            "tool_input": ["command": "echo hi"]
        ])
        let handle = ProviderResponseHandle(UUID())
        let result = adapter.receive(event, responseHandle: handle, responder: HookOnceResponder(sink: sink))
        guard case let .request(arrival) = result,
              case let .response(token) = arrival.channel else {
            return XCTFail("expected a blocking request with an opaque token")
        }
        XCTAssertEqual(token.session, session)
        XCTAssertTrue(registry.isRegistered(token))

        let effectID = EffectID(ids.makeOccurrenceID())
        let executor = HookTransportAdapter(registry: registry)
        let effect = InteractionEffect.deliverResolution(ResolutionEffect(
            effectID: effectID,
            requestID: arrival.id,
            token: token,
            command: .allowOnce
        ))
        var acks: [InteractionAdapterEvent] = []
        executor.execute([effect], report: { acks.append($0) })
        XCTAssertEqual(sink.responses, [.resolution(.allowOnce)])
        XCTAssertEqual(acks, [.resolutionSucceeded(effectID, request: arrival.id, token: token)])
        XCTAssertFalse(registry.isRegistered(token))
    }

    func testDisplayOnlyNotificationHasNoResolutionChannel() throws {
        let authority = InMemorySessionGenerationAuthority()
        _ = authority.apply(SessionIdentityFact(key: session.key, lifecycle: .opened, evidence: .initialOpen, sequence: 1))
        let adapter = HookInteractionAdapter(generationAuthority: authority)
        let responder = InMemoryOnceResponder<HookWireResponse>()
        let event = try makeEvent([
            "hook_event_name": "Notification",
            "session_id": session.key.providerSessionID,
            "question": "Continue?",
            "options": ["Yes", "No"]
        ])
        guard case let .request(arrival) = adapter.receive(event, responder: responder) else {
            return XCTFail("expected display-only question request")
        }
        XCTAssertEqual(arrival.behavior, .displayOnly)
        XCTAssertEqual(arrival.channel, .none)
        XCTAssertEqual(responder.responses, [.neutral(.notificationAck)])
    }

    func testProviderWithoutSafeNeutralResponseIsQuarantined() throws {
        let authority = InMemorySessionGenerationAuthority()
        _ = authority.apply(SessionIdentityFact(key: session.key, lifecycle: .opened, evidence: .initialOpen, sequence: 1))
        let adapter = HookInteractionAdapter(
            generationAuthority: authority,
            configuration: HookAdmissionConfiguration(safeNeutralResponse: nil)
        )
        let event = try makeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": session.key.providerSessionID,
            "tool_name": "Bash"
        ])
        let result = adapter.receive(event, responseHandle: ProviderResponseHandle(UUID()), responder: InMemoryOnceResponder<HookWireResponse>())
        XCTAssertEqual(result, .quarantine(.noSafeNeutralResponse))
    }

    func testCoordinatorExecutesReturnedEffectsThroughOneExecutorAndFeedsTypedAck() {
        let store = InteractionCenterStore()
        let executor = RecordingExecutor()
        let coordinator = InteractionCoordinator(store: store, executor: executor)
        let observation = SessionObservation(session: session, revision: 1)
        _ = coordinator.send(.sessionObserved(observation))
        let request = RequestID(session: session, upstreamID: "p", kind: .permission)
        let token = TransportToken(session: session, rawValue: UUID())
        _ = coordinator.send(.requestArrived(RequestArrival(
            id: request,
            session: session,
            kind: .permission,
            behavior: .blocking(ResolutionCapabilities()),
            content: .permission(PermissionContent(toolName: "Bash")),
            channel: .response(token)
        )))

        let effects = coordinator.send(.user(.resolve(request, .allowOnce)))
        guard case let .deliverResolution(resolution) = effects.first else {
            return XCTFail("expected returned resolution effect")
        }
        XCTAssertEqual(executor.batches.count, 1)
        XCTAssertEqual(executor.batches[0], effects)
        XCTAssertEqual(executor.acks, [.resolutionSucceeded(resolution.effectID, request: request, token: token)])
    }

    private func makeEvent(_ object: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(HookEvent(from: data))
    }

}

@MainActor
final class InteractionTransportFinalizerTests: XCTestCase {
    func testDisconnectFinalizesOnlyTokenOnceWithProviderNeutralResponse() {
        let clock = TestClock()
        let sessionA = SessionRef(provider: "claude", providerSessionID: "a", generation: 1)
        let sessionB = SessionRef(provider: "claude", providerSessionID: "b", generation: 1)
        let tokenA = TransportToken(session: sessionA, rawValue: UUID())
        let tokenB = TransportToken(session: sessionB, rawValue: UUID())
        let registry = HookTransportRegistry(clock: clock)
        let responderA = InMemoryOnceResponder<HookWireResponse>()
        let responderB = InMemoryOnceResponder<HookWireResponse>()
        let requestA = RequestID(session: sessionA, upstreamID: "a", kind: .permission)
        let requestB = RequestID(session: sessionB, upstreamID: "b", kind: .permission)
        XCTAssertEqual(registry.register(token: tokenA, request: requestA, neutralResponse: .hookEmptyObject, responder: responderA), .registered)
        XCTAssertEqual(registry.register(token: tokenB, request: requestB, neutralResponse: .hookEmptyObject, responder: responderB), .registered)

        let first = registry.finalize(token: tokenA, reason: .peerDisconnected)
        XCTAssertEqual(first, .finalized(NeutralFinalizationReceipt(token: tokenA, response: .hookEmptyObject)))
        XCTAssertEqual(responderA.responses, [.neutral(.hookEmptyObject)])
        XCTAssertTrue(registry.isRegistered(tokenB), "token-scoped disconnect must not drain session B")
        let duplicate = registry.finalize(token: tokenA, reason: .timedOut)
        if case .finalized = duplicate { XCTFail("a token may be finalized only once") }
        XCTAssertEqual(responderA.responses.count, 1)
    }

    func testNoSafeNeutralResponseQuarantinesWithoutDenyOrResponse() {
        let session = SessionRef(provider: "claude", providerSessionID: "s", generation: 1)
        let token = TransportToken(session: session, rawValue: UUID())
        let responder = InMemoryOnceResponder<HookWireResponse>()
        let registry = HookTransportRegistry(clock: TestClock())
        XCTAssertEqual(registry.register(token: token, neutralResponse: nil, responder: responder), .registered)
        let result = registry.finalize(token: token, reason: .timedOut)
        XCTAssertEqual(result, .quarantined(.noSafeNeutralResponse(token)))
        XCTAssertTrue(responder.responses.isEmpty)
    }

    func testLateResolutionAfterFinalizationCannotSubmitAnotherResponse() {
        let session = SessionRef(provider: "claude", providerSessionID: "s", generation: 1)
        let token = TransportToken(session: session, rawValue: UUID())
        let responder = InMemoryOnceResponder<HookWireResponse>()
        let registry = HookTransportRegistry(clock: TestClock())
        XCTAssertEqual(registry.register(token: token, neutralResponse: .hookEmptyObject, responder: responder), .registered)
        _ = registry.finalize(token: token, reason: .peerDisconnected)
        XCTAssertEqual(registry.respond(token: token, command: .allowOnce), .duplicate)
        XCTAssertEqual(responder.responses, [.neutral(.hookEmptyObject)])
    }
}

private final class RecordingHookSink: HookWireResponseSink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var responses: [HookWireResponse] = []

    func send(_ response: HookWireResponse) -> Bool {
        lock.lock(); responses.append(response); lock.unlock()
        return true
    }
}

@MainActor
private final class RecordingExecutor: InteractionEffectExecutor {
    private(set) var batches: [[InteractionEffect]] = []
    private(set) var acks: [InteractionAdapterEvent] = []

    func execute(_ effects: [InteractionEffect], report: @escaping (InteractionAdapterEvent) -> Void) {
        batches.append(effects)
        for effect in effects {
            guard case let .deliverResolution(value) = effect else { continue }
            let ack = InteractionAdapterEvent.resolutionSucceeded(value.effectID, request: value.requestID, token: value.token)
            acks.append(ack)
            report(ack)
        }
    }
}
