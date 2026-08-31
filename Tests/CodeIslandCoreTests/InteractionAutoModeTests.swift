import XCTest
@testable import CodeIslandCore

@MainActor
final class InteractionAutoModeTests: XCTestCase {
    private let first = SessionRef(provider: "claude", providerSessionID: "same", generation: 1)
    private let second = SessionRef(provider: "claude", providerSessionID: "other", generation: 1)

    private func observation(_ session: SessionRef, mode: ObservedPermissionMode = .unknown(nil), revision: UInt64 = 1) -> SessionObservation {
        let auto = AutoCapabilities(nativeAuto: true, acceptEditsRules: true, explicitBypass: true)
        return SessionObservation(
            session: session,
            permissionMode: mode,
            providerCapabilities: ProviderCapabilities(auto: auto),
            revision: revision
        )
    }

    func testAutoContextIsIsolatedByCompleteSessionRef() {
        let store = InteractionSessionContextStore()
        _ = store.observe(observation(first))
        _ = store.observe(observation(second))
        let effect = EffectID(UUID())
        let token = AutoControlToken(session: first, rawValue: UUID())

        guard case .success = store.beginAuto(session: first, intent: .enable, effectID: effect, token: token) else {
            return XCTFail("expected first session to compile Auto")
        }
        XCTAssertEqual(store.snapshot(for: first)?.requestedMode, .enable)
        XCTAssertNil(store.snapshot(for: second)?.requestedMode)

        _ = store.observe(observation(second, mode: .auto, revision: 2))
        XCTAssertEqual(store.snapshot(for: second)?.phase, .idle)
        XCTAssertEqual(store.snapshot(for: first)?.phase, .transitioning(effect))
    }

    func testDeliveryDoesNotPretendToConfirmUntilProviderObservation() {
        let store = InteractionSessionContextStore()
        _ = store.observe(observation(first))
        let effect = EffectID(UUID())
        let token = AutoControlToken(session: first, rawValue: UUID())
        _ = store.beginAuto(session: first, intent: .enable, effectID: effect, token: token)

        XCTAssertTrue(store.markDelivered(effect, session: first))
        XCTAssertEqual(store.snapshot(for: first)?.phase, .delivered(effect))
        XCTAssertNotEqual(store.snapshot(for: first)?.phase, .confirmed(.auto))
        XCTAssertTrue(store.markAwaitingConfirmation(effect, session: first))
        XCTAssertEqual(store.snapshot(for: first)?.phase, .awaitingConfirmation(effect))

        _ = store.observe(observation(first, mode: .auto, revision: 2))
        XCTAssertEqual(store.snapshot(for: first)?.phase, .confirmed(.auto))
        XCTAssertNil(store.snapshot(for: first)?.inFlightEffect)
    }

    func testDisconnectClearsRequestedAndObservedStateWithoutConfirming() {
        let store = InteractionSessionContextStore()
        _ = store.observe(observation(first, mode: .auto))
        let effect = EffectID(UUID())
        let token = AutoControlToken(session: first, rawValue: UUID())
        _ = store.beginAuto(session: first, intent: .off, effectID: effect, token: token)
        store.disconnect(session: first)

        let snapshot = try! XCTUnwrap(store.snapshot(for: first))
        XCTAssertEqual(snapshot.phase, .unknown)
        XCTAssertNil(snapshot.observedMode)
        XCTAssertNil(snapshot.requestedMode)
        XCTAssertNil(snapshot.inFlightEffect)
    }

    func testClosedGenerationDoesNotAcceptAutoAndReopenStartsEmpty() {
        let authority = InMemorySessionGenerationAuthority()
        let adapter = SessionObservationAdapter(generationAuthority: authority)
        var snapshot = SessionSnapshot()
        snapshot.source = "claude"
        snapshot.providerSessionId = "same"
        let caps = ProviderCapabilities(auto: AutoCapabilities(nativeAuto: true, independentControlChannel: true))

        let opened = adapter.map(snapshot: snapshot, sessionID: "local", sequence: 1, revision: 1, capabilities: caps)
        let ref = try! XCTUnwrap(opened?.session)
        let closed = adapter.map(snapshot: snapshot, sessionID: "local", sequence: 2, revision: 2,
                                 lifecycle: .closed, capabilities: caps)
        XCTAssertEqual(closed?.session, ref)
        XCTAssertNil(adapter.map(snapshot: snapshot, sessionID: "local", sequence: 3, revision: 3, capabilities: caps))

        let reopened = adapter.reopen(snapshot: snapshot, sessionID: "local", sequence: 4, revision: 4,
                                      capabilities: caps)
        XCTAssertEqual(reopened?.session.generation, ref.generation + 1)
    }

    func testCompilerPrefersNativeAndKeepsBypassExplicit() {
        let compiler = AutoCommandCompiler()
        let native = AutoCapabilities(
            nativeAuto: true,
            acceptEditsRules: true,
            explicitBypass: true,
            independentControlChannel: true
        )
        let token = AutoControlToken(session: first, rawValue: UUID())
        guard case let .success(nativeTransaction) = compiler.compile(.enable, capabilities: native, token: token) else {
            return XCTFail("native Auto should compile")
        }
        XCTAssertEqual(nativeTransaction.commands, [.setMode(.auto)])

        let rules = AutoCapabilities(acceptEditsRules: true, independentControlChannel: true)
        guard case let .success(ruleTransaction) = compiler.compile(.enable, capabilities: rules, token: token) else {
            return XCTFail("explicit rules fallback should compile")
        }
        XCTAssertEqual(ruleTransaction.commands.first, .setMode(.acceptEdits))
        XCTAssertEqual(ruleTransaction.commands.count, 2)
        XCTAssertEqual(compiler.compile(.enable, capabilities: AutoCapabilities(independentControlChannel: true), token: token), .failure(.unavailable))
        XCTAssertEqual(compiler.compile(.bypassExplicit, capabilities: native, token: token).map(\.commands), .success([.setMode(.bypassPermissions)]))
    }

    func testAutoAdapterKeepsControlTokenSeparateFromPermissionTransport() {
        let adapter = InMemoryAutoCommandAdapter()
        let token = AutoControlToken(session: first, rawValue: UUID())
        let transaction = AutoCommandTransaction(session: first, commands: [.setMode(.auto)], controlToken: token)
        var delivered: Result<AutoDelivery, AutoAdapterFailure>?
        adapter.submit(transaction) { delivered = $0 }
        XCTAssertEqual(adapter.submissions, [transaction])
        XCTAssertNil(delivered)

        let effect = EffectID(UUID())
        adapter.acknowledge(token: token, effectID: effect)
        XCTAssertEqual(delivered, .success(AutoDelivery(effectID: effect)))
        // The token is one-shot; a late/duplicate acknowledgement cannot invoke
        // the completion a second time.
        adapter.acknowledge(token: token, effectID: EffectID(UUID()))
        XCTAssertEqual(delivered, .success(AutoDelivery(effectID: effect)))
    }
}
