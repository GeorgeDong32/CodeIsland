import Foundation
import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class InteractionProductionWiringTests: XCTestCase {
    func testAppStateAcceptsOneRuntimeAndRoutesHookWithoutLegacyQueueWrites() {
        let ids = DeterministicIDFactory()
        let authority = InMemorySessionGenerationAuthority()
        let buffer = InMemoryRequestIngressBuffer(idFactory: ids)
        let registry = HookTransportRegistry()
        let hook = HookInteractionAdapter(
            generationAuthority: authority,
            ingressBuffer: buffer,
            transportRegistry: registry,
            idFactory: ids
        )
        let codex = CodexTransportAdapter(idFactory: ids)
        let sessionAdapter = SessionObservationAdapter(generationAuthority: authority)
        let auto = AppStateAutoApproveController(adapter: UnavailableAutoCommandAdapter())
        let firstStore = InteractionCenterStore(dependencies: InteractionCenterDependencies(
            idFactory: ids,
            generationAuthority: authority,
            ingressBuffer: buffer,
            presentationPolicy: .adaptiveCLI()
        ))
        let firstCoordinator = InteractionCoordinator(
            store: firstStore,
            executor: RecordingInteractionEffectExecutor()
        )
        let state = AppState()
        state.installInteractionRuntime(
            coordinator: firstCoordinator,
            hookAdapter: hook,
            codexAdapter: codex,
            sessionAdapter: sessionAdapter,
            autoController: auto
        )

        // A second construction attempt cannot replace the process-wide owner.
        let second = InteractionCoordinator(
            store: InteractionCenterStore(),
            executor: RecordingInteractionEffectExecutor()
        )
        state.installInteractionRuntime(
            coordinator: second,
            hookAdapter: hook,
            codexAdapter: codex,
            sessionAdapter: sessionAdapter,
            autoController: auto
        )
        XCTAssertTrue(state.interactionCoordinator === firstCoordinator)

        var snapshot = SessionSnapshot(startTime: Date())
        snapshot.source = "claude"
        snapshot.providerSessionId = "s1"
        state.sessions["s1"] = snapshot
        state.publishInteractionObservation(for: "s1")

        let payload = #"""
        {
          "_source":"claude", "session_id":"s1", "hook_event_name":"PermissionRequest",
          "tool_name":"Bash", "tool_use_id":"tool-1", "tool_input":{"command":"pwd"}
        }
        """#
        let event = HookEvent(from: Data(payload.utf8))!
        state.prepareInteractionHookSession(event, question: false)
        let responder = InMemoryOnceResponder<HookWireResponse>()
        let handle = ProviderResponseHandle(ids.makeOccurrenceID())
        guard let result = state.receiveInteractionHook(event, responseHandle: handle, responder: responder) else {
            return XCTFail("production hook adapter was not installed")
        }
        guard case let .request(arrival) = result else {
            return XCTFail("expected typed request admission, got \(result)")
        }
        state.submitInteraction(.requestArrived(arrival))

        XCTAssertEqual(state.permissionQueue.count, 0)
        XCTAssertEqual(state.questionQueue.count, 0)
        XCTAssertEqual(firstCoordinator.snapshot.local.requests.count, 1)
        XCTAssertEqual(firstCoordinator.snapshot.local.requests.values.first?.session.key.provider, ProviderID("claude"))
    }

    func testPersistedPermissionModeIsDecodeOnly() throws {
        let json = #"{"sessionId":"s","source":"claude","startTime":"2026-04-09T10:00:00Z","lastActivity":"2026-04-09T10:01:00Z","observedPermissionMode":"bypassPermissions"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedSession.self, from: Data(json.utf8))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(decoded)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("observedPermissionMode"))
    }
}
