import XCTest
@testable import CodeIslandCore

@MainActor
final class InteractionCenterPhase0Tests: XCTestCase {
    private let session = SessionRef(provider: "claude", providerSessionID: "s1", generation: 1)

    private func makeStore(policy: PresentationPolicy = PresentationPolicy()) -> InteractionCenterStore {
        InteractionCenterStore(dependencies: InteractionCenterDependencies(
            clock: TestClock(), idFactory: DeterministicIDFactory(), presentationPolicy: policy))
    }

    private func observe(_ store: InteractionCenterStore) {
        _ = store.send(.sessionObserved(SessionObservation(session: session, revision: 1)))
    }

    func testPermissionPlanAndQuestionShareTypedRequestSurface() {
        let store = makeStore(); observe(store)
        let permissionID = RequestID(session: session, upstreamID: "p", kind: .permission)
        let permissionToken = TransportToken(session: session, rawValue: UUID())
        _ = store.send(.requestArrived(RequestArrival(
            id: permissionID, session: session, kind: .permission,
            behavior: .blocking(ResolutionCapabilities()), content: .permission(PermissionContent(summary: "Run")),
            channel: .response(permissionToken))))
        XCTAssertEqual(store.snapshot.local.requests[permissionID]?.kind, .permission)

        let planID = RequestID(session: session, upstreamID: "plan", kind: .permission)
        _ = store.send(.requestArrived(RequestArrival(
            id: planID, session: session, kind: .permission,
            behavior: .blocking(ResolutionCapabilities(planModes: [.manual])),
            content: .permission(PermissionContent(variant: .plan(PlanContent(planText: SensitiveText("secret", sensitivity: .secret))))),
            channel: .response(TransportToken(session: session, rawValue: UUID())))))
        XCTAssertEqual(store.snapshot.local.requests[planID]?.kind, .permission)
        XCTAssertFalse(store.snapshot.local.requests[planID]?.availableActions.contains(where: {
            if case .allowPlan(.manual) = $0 { return true }; return false
        }) == false)

        let questionID = RequestID(session: session, upstreamID: "q", kind: .question)
        let questionContent = QuestionContent(
            items: [QuestionItem(key: "choice", prompt: SensitiveText("Pick", sensitivity: .secret))],
            answerSchema: AnswerSchema(keysInProviderOrder: ["choice"]))
        let questionArrival = RequestArrival(id: questionID, session: session, kind: .question,
            behavior: .displayOnly, content: .question(questionContent))
        _ = store.send(.requestArrived(questionArrival))
        XCTAssertEqual(store.snapshot.local.requests[questionID]?.availableActions, [])
        XCTAssertEqual(store.snapshot.local.requests[questionID]?.presentation, .normal)
        XCTAssertEqual(store.snapshot.local.sessions[session]?.pendingCount, 3)
    }

    func testDismissRevealAndOptimisticResolutionRequireSingleEffect() {
        let store = makeStore(); observe(store)
        let id = RequestID(session: session, upstreamID: "p", kind: .permission)
        let token = TransportToken(session: session, rawValue: UUID())
        _ = store.send(.requestArrived(RequestArrival(id: id, session: session, kind: .permission,
            behavior: .blocking(ResolutionCapabilities()), content: .permission(PermissionContent(summary: "Run")),
            channel: .response(token))))
        _ = store.send(.user(.dismiss(id)))
        XCTAssertEqual(store.snapshot.local.requests[id]?.presentation, .dismissed)
        XCTAssertNil(store.snapshot.local.presentation.prominentRequest)
        _ = store.send(.user(.reveal(id)))
        XCTAssertEqual(store.snapshot.local.presentation.prominentRequest, id)
        let effects = store.send(.user(.resolve(id, .allowOnce)))
        XCTAssertEqual(effects.count, 1)
        guard case let .deliverResolution(effect) = effects[0] else { return XCTFail("expected resolution effect") }
        XCTAssertEqual(store.snapshot.local.requests[id]?.lifecycle, .resolving(effect.effectID))
        XCTAssertEqual(store.send(.user(.resolve(id, .allowOnce))).count, 0)
        _ = store.send(.adapter(.resolutionSucceeded(effect.effectID, request: id, token: token)))
        XCTAssertNil(store.snapshot.local.requests[id])
    }

    func testGenerationAuthorityIsIdempotentAndReopensOnlyAfterClose() {
        let authority = InMemorySessionGenerationAuthority()
        let key = SessionKey(provider: "claude", providerSessionID: "s1")
        let first = authority.apply(SessionIdentityFact(key: key, lifecycle: .opened, evidence: .initialOpen, sequence: 1))
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(authority.apply(SessionIdentityFact(key: key, lifecycle: .observed, evidence: .providerObservation, sequence: 2)), first)
        XCTAssertEqual(authority.apply(SessionIdentityFact(key: key, lifecycle: .opened, evidence: .initialOpen, sequence: 3)), first)
        _ = authority.apply(SessionIdentityFact(key: key, lifecycle: .closed(.providerClosed), evidence: .providerClose, sequence: 4))
        XCTAssertFalse(authority.isCurrent(first))
        let reopened = authority.apply(SessionIdentityFact(key: key, lifecycle: .opened, evidence: .explicitReopen, sequence: 5))
        XCTAssertEqual(reopened.generation, 2)
        XCTAssertEqual(authority.apply(SessionIdentityFact(key: key, lifecycle: .opened, evidence: .explicitReopen, sequence: 5)), reopened)
    }

    func testAutoCompilerNeverSilentlyFallsBackToBypass() {
        let token = AutoControlToken(session: session, rawValue: UUID())
        let compiler = AutoCommandCompiler()
        XCTAssertEqual(compiler.compile(.enable, capabilities: AutoCapabilities(), token: token), .failure(.unavailable))
        XCTAssertEqual(compiler.compile(.bypassExplicit, capabilities: AutoCapabilities(independentControlChannel: true), token: token), .failure(.bypassNotPermitted))
        let result = compiler.compile(.enable, capabilities: AutoCapabilities(acceptEditsRules: true), token: token)
        guard case let .success(transaction) = result else { return XCTFail("expected rules fallback") }
        XCTAssertEqual(transaction.session, session)
        XCTAssertEqual(transaction.commands.count, 2)
        if case .setMode(.acceptEdits) = transaction.commands[0] {} else { XCTFail("expected accept-edits mode") }
    }

    func testIngressBindsInArrivalOrderAndExpiresWithoutGuessingGeneration() {
        let clock = TestClock(Date())
        let ids = DeterministicIDFactory()
        let buffer = InMemoryRequestIngressBuffer(policy: PendingIngressPolicy(maxRequestsPerSessionKey: 2, maxAge: .seconds(5)), idFactory: ids)
        let store = InteractionCenterStore(dependencies: InteractionCenterDependencies(
            clock: clock, idFactory: ids, ingressBuffer: buffer))
        observe(store)
        let key = session.key
        let first = UnboundRequest(key: key, bufferToken: ids.makeBufferToken(),
            correlation: .stable(StableRequestKey(upstreamID: "one", kind: .permission)),
            kind: .permission, behavior: .blocking(ResolutionCapabilities()),
            content: .permission(PermissionContent(summary: "one")),
            channel: .response(ProviderResponseHandle(ids.makeOccurrenceID())), receivedAt: clock.now)
        let second = UnboundRequest(key: key, bufferToken: ids.makeBufferToken(),
            correlation: .occurrence(ids.makeOccurrenceID()), kind: .question,
            behavior: .displayOnly,
            content: .question(QuestionContent(items: [], answerSchema: AnswerSchema(keysInProviderOrder: []))),
            receivedAt: clock.now)
        if case .buffered = buffer.accept(first) {} else { XCTFail("first request must buffer") }
        if case .buffered = buffer.accept(second) {} else { XCTFail("second request must buffer") }
        _ = store.send(.bindBufferedRequests(session))
        XCTAssertEqual(store.snapshot.local.requests.count, 2)
        XCTAssertEqual(store.snapshot.local.requests.values.sorted { $0.queuePosition < $1.queuePosition }.map { $0.kind },
                       [.permission, .question])
        XCTAssertTrue(store.snapshot.local.requests.keys.allSatisfy { $0.session.generation == 1 })

        let expired = UnboundRequest(key: key, bufferToken: ids.makeBufferToken(),
            correlation: .occurrence(ids.makeOccurrenceID()), kind: .question, behavior: .displayOnly,
            content: .question(QuestionContent(items: [], answerSchema: AnswerSchema(keysInProviderOrder: []))),
            receivedAt: clock.now)
        _ = buffer.accept(expired)
        clock.advance(by: .seconds(6))
        let expiryEffects = store.send(.expireBufferedRequests(clock.now))
        XCTAssertEqual(expiryEffects.count, 1)
        if case .diagnostic = expiryEffects[0] {} else { XCTFail("expiry must be reported as a diagnostic effect") }
    }

    func testCrossKindOrderingAndDeliveryUnknownWaitForExternalFact() {
        let store = makeStore(); observe(store)
        let p = RequestID(session: session, upstreamID: "p", kind: .permission)
        let q = RequestID(session: session, upstreamID: "q", kind: .question)
        let pToken = TransportToken(session: session, rawValue: UUID())
        let qToken = TransportToken(session: session, rawValue: UUID())
        _ = store.send(.requestArrived(RequestArrival(id: p, session: session, kind: .permission,
            behavior: .blocking(ResolutionCapabilities()), content: .permission(PermissionContent(summary: "p")),
            channel: .response(pToken))))
        _ = store.send(.requestArrived(RequestArrival(id: q, session: session, kind: .question,
            behavior: .blocking(ResolutionCapabilities()), content: .question(QuestionContent(
                items: [], answerSchema: AnswerSchema(keysInProviderOrder: []))), channel: .response(qToken))))
        XCTAssertEqual(store.send(.user(.resolve(q, .answer([])))).count, 1) // diagnostic, not a response effect
        guard case .diagnostic = store.send(.user(.resolve(q, .answer([])))).first else { return XCTFail("expected blocked diagnostic") }
        let effects = store.send(.user(.resolve(p, .allowOnce)))
        guard case let .deliverResolution(pEffect) = effects.first else { return XCTFail("expected permission effect") }
        _ = store.send(.adapter(.resolutionFailed(pEffect.effectID, request: p, token: pToken, failure: .deliveryUnknown("unknown"))))
        XCTAssertEqual(store.snapshot.local.requests[p]?.lifecycle, .awaitingExternalConfirmation(pEffect.effectID))
        XCTAssertEqual(store.send(.user(.resolve(q, .answer([])))).count, 1)
        _ = store.send(.adapter(.externallyResolved(p, evidence: .providerRequestID)))
        let qEffects = store.send(.user(.resolve(q, .answer([]))))
        XCTAssertEqual(qEffects.count, 1)
        if case .deliverResolution = qEffects[0] {} else { XCTFail("expected question response after external fact") }
    }

    func testExternalProjectionRedactsSecretQuestionContent() {
        let store = makeStore(); observe(store)
        let id = RequestID(session: session, upstreamID: "secret", kind: .question)
        let content = QuestionContent(
            items: [QuestionItem(key: "token", prompt: SensitiveText("do not leak", sensitivity: .secret))],
            answerSchema: AnswerSchema(keysInProviderOrder: ["token"], allowsCustomText: true))
        _ = store.send(.requestArrived(RequestArrival(id: id, session: session, kind: .question,
            behavior: .displayOnly, content: .question(content))))
        XCTAssertEqual(store.snapshot.external.requests[id]?.title, "Question (redacted)")
        XCTAssertEqual(store.snapshot.external.requests[id]?.sensitivity, .secret)
        XCTAssertFalse(store.snapshot.external.requests[id]?.title?.contains("do not leak") == true)
        // The redacted session keeps aggregate discoverability while omitting the prompt.
        XCTAssertEqual(store.snapshot.external.sessions[session]?.pendingCount, 1)
    }

    func testTerminalLedgerEvictsOldestAndExpiresDeterministically() {
        let clock = TestClock(Date())
        let ledger = InteractionTerminalLedger(policy: TerminalLedgerPolicy(maxEntries: 2, retention: .seconds(10)))
        let first = EffectID(idsUUID(1))
        let second = EffectID(idsUUID(2))
        let third = EffectID(idsUUID(3))
        ledger.record(.init(effectID: first, endedAt: clock.now))
        clock.advance(by: .seconds(1))
        ledger.record(.init(effectID: second, endedAt: clock.now))
        clock.advance(by: .seconds(1))
        ledger.record(.init(effectID: third, endedAt: clock.now))
        XCTAssertFalse(ledger.contains(first, now: clock.now))
        XCTAssertEqual(ledger.count, 2)
        clock.advance(by: .seconds(11))
        ledger.prune(now: clock.now)
        XCTAssertEqual(ledger.count, 0)
    }

    private func idsUUID(_ value: UInt64) -> UUID {
        let factory = DeterministicIDFactory(seed: value)
        return factory.makeOccurrenceID()
    }
}
