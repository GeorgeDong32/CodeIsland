import Foundation
import Observation

public struct InteractionCenterDependencies {
    public let clock: any InteractionClock
    public let idFactory: any InteractionIDFactory
    public let generationAuthority: (any SessionGenerationAuthority)?
    public let ingressBuffer: (any RequestIngressBuffer)?
    public let ledgerPolicy: TerminalLedgerPolicy
    public let presentationPolicy: PresentationPolicy

    public init(clock: any InteractionClock = SystemInteractionClock(),
                idFactory: any InteractionIDFactory = RandomInteractionIDFactory(),
                generationAuthority: (any SessionGenerationAuthority)? = nil,
                ingressBuffer: (any RequestIngressBuffer)? = nil,
                ledgerPolicy: TerminalLedgerPolicy = TerminalLedgerPolicy(),
                presentationPolicy: PresentationPolicy = PresentationPolicy()) {
        self.clock = clock; self.idFactory = idFactory; self.generationAuthority = generationAuthority
        self.ingressBuffer = ingressBuffer; self.ledgerPolicy = ledgerPolicy; self.presentationPolicy = presentationPolicy
    }
}

/// Fork-owned reducer store. Its only mutation entry point is `send`; effects are
/// returned to the coordinator and never executed from inside this module.
@MainActor
public final class InteractionCenterStore {
    private struct RequestRecord {
        var arrival: RequestArrival
        var ordinal: UInt64
        var lifecycle: RequestLifecycle = .pending
        var presentation: RequestPresentation = .normal
        var error: InteractionError?
        var explicitReveal = false
        var terminal = false
        var finalizedTransport = false
    }

    private struct SessionState {
        var ref: SessionRef
        var facts = SessionDisplayFacts()
        var navigation = NavigationSnapshot()
        var completion: CompletionNotice?
        var capabilities = ProviderCapabilities()
        var observedMode: ObservedPermissionMode?
        var autoRequested: AutoModeIntent?
        var autoExpectedMode: ProviderPermissionMode?
        var autoPhase: AutoPhase = .idle
        var visibility: CLIVisibility = .unknown
        var visibilityObservation: VisibilityObservation?
        var visibilityRevision: UInt64 = 0
        var visibilityAt: Date?
        var observationRevision: UInt64 = 0
        var nextOrdinal: UInt64 = 0
        var queue: [RequestID] = []
        var closed = false
        var nativePromptRevision: UInt64 = 0
    }

    private struct LedgerEntry {
        let endedAt: Date
        let request: RequestID?
        let token: TransportToken?
    }

    private let dependencies: InteractionCenterDependencies
    private var sessions: [SessionRef: SessionState] = [:]
    private var latestGeneration: [SessionKey: UInt64] = [:]
    private var requests: [RequestID: RequestRecord] = [:]
    private var terminalLedger: [EffectID: LedgerEntry] = [:]
    private var terminalTokens: [TransportToken: LedgerEntry] = [:]
    private var navigationEffects: [EffectID: NavigationTarget] = [:]
    private var revision: UInt64 = 0
    private var feedbackNonce: UInt64 = 0
    private var currentSnapshot = InteractionSnapshot()

    public init(dependencies: InteractionCenterDependencies = InteractionCenterDependencies()) {
        self.dependencies = dependencies
        rebuildSnapshot()
    }

    public var snapshot: InteractionSnapshot { currentSnapshot }

    @discardableResult
    public func send(_ input: InteractionInput) -> [InteractionEffect] {
        pruneLedger()
        var effects: [InteractionEffect]
        switch input {
        case let .sessionObserved(observation): effects = reduce(observation)
        case let .requestArrived(arrival): effects = reduce(arrival)
        case let .nativePromptObserved(observation): effects = reduce(observation)
        case let .visibilityChanged(observation): effects = reduce(observation)
        case let .bindBufferedRequests(session): effects = reduceBufferedBind(session)
        case let .expireBufferedRequests(now): effects = reduceBufferedExpire(now)
        case let .user(action): effects = reduce(action)
        case let .adapter(event): effects = reduce(event)
        }
        revision &+= 1
        rebuildSnapshot()
        return effects
    }

    private func reduceBufferedBind(_ session: SessionRef) -> [InteractionEffect] {
        guard let buffer = dependencies.ingressBuffer else { return [] }
        let arrivals = buffer.bind(session, tokenFactory: dependencies.idFactory)
        var effects: [InteractionEffect] = []
        for arrival in arrivals { effects.append(contentsOf: reduce(arrival)) }
        return effects
    }

    private func reduceBufferedExpire(_ now: Date) -> [InteractionEffect] {
        guard let buffer = dependencies.ingressBuffer else { return [] }
        let expired = buffer.expire(now: now)
        guard !expired.isEmpty else { return [] }
        return expired.map { _ in .diagnostic(.code(.bufferExpired)) }
    }

    // MARK: Session reconciliation

    private func reduce(_ observation: SessionObservation) -> [InteractionEffect] {
        guard observation.display.session == observation.session,
              observation.navigation.session == observation.session else {
            return diagnostic(.code(.invalidIdentity))
        }

        if let latest = latestGeneration[observation.session.key], observation.session.generation < latest {
            return diagnostic(.code(.staleGeneration))
        }
        if let authority = dependencies.generationAuthority,
           authority.current(for: observation.session.key) != nil,
           !authority.isCurrent(observation.session),
           observation.lifecycle != .closed,
           observation.session.generation == latestGeneration[observation.session.key] {
            return diagnostic(.code(.staleGeneration))
        }

        if latestGeneration[observation.session.key] != observation.session.generation {
            // A replacement generation is a new namespace. Old records remain in
            // the terminal/no-op domain and can never be addressed by this ref.
            latestGeneration[observation.session.key] = observation.session.generation
            sessions = sessions.filter { $0.key.key != observation.session.key || $0.key.generation == observation.session.generation }
            requests = requests.filter { $0.key.session.key != observation.session.key || $0.key.session.generation == observation.session.generation }
        }

        var state = sessions[observation.session] ?? SessionState(ref: observation.session)
        guard observation.revision > state.observationRevision else {
            return diagnostic(.code(.staleRevision))
        }
        state.observationRevision = observation.revision
        state.facts = observation.display.facts
        state.navigation = NavigationSnapshot(context: observation.navigation.context,
                                               route: observation.navigation.route,
                                               canNavigate: observation.navigation.context.terminal != nil,
                                               lastFailure: state.navigation.lastFailure)
        state.capabilities = observation.providerCapabilities
        state.observedMode = observation.permissionMode
        let visibilityObservation = VisibilityObservation(
            session: observation.session,
            state: observation.cliVisibility,
            evidence: .unavailable,
            revision: observation.revision,
            measuredAt: observation.observedAt,
            maxAge: dependencies.presentationPolicy.visibilityMaxAge
        )
        state.visibilityObservation = visibilityObservation
        state.visibility = visibilityObservation.state
        state.visibilityRevision = max(state.visibilityRevision, observation.revision)
        state.visibilityAt = observation.observedAt
        if let completion = observation.completion,
           completion.session == observation.session,
           completion.revision >= (state.completion?.revision ?? 0) {
            state.completion = CompletionNotice(session: completion.session, message: completion.message, revision: completion.revision)
        }

        // Confirmation is a fact, not an optimistic consequence of a button click.
        if let mode = state.autoExpectedMode, observedMode(observation.permissionMode, matches: mode) {
            state.autoPhase = .confirmed(mode)
        }
        if observation.lifecycle == .closed {
            state.closed = true
            // A closed generation must never retain a local Auto intent. A
            // later provider observation may reopen a new SessionRef, but it
            // cannot inherit requested/in-flight state from this generation.
            state.autoRequested = nil
            state.autoExpectedMode = nil
            state.autoPhase = .unknown
        }
        sessions[observation.session] = state

        if observation.lifecycle == .closed {
            return closeRequests(for: observation.session, reason: .sessionClosed)
        }
        return []
    }

    private func reduce(_ observation: NativePromptObservation) -> [InteractionEffect] {
        guard isCurrent(observation.session) else { return diagnostic(.code(.staleGeneration)) }
        guard var state = sessions[observation.session], observation.revision > state.nativePromptRevision else {
            return diagnostic(.code(.staleRevision))
        }
        state.nativePromptRevision = observation.revision
        sessions[observation.session] = state
        return []
    }

    private func reduce(_ observation: VisibilityObservation) -> [InteractionEffect] {
        guard isCurrent(observation.session) else { return diagnostic(.code(.staleGeneration)) }
        guard var state = sessions[observation.session] else { return diagnostic(.code(.invalidIdentity)) }
        guard observation.revision > state.visibilityRevision else { return diagnostic(.code(.staleRevision)) }
        state.visibilityObservation = observation
        state.visibility = observation.state; state.visibilityRevision = observation.revision; state.visibilityAt = observation.measuredAt
        sessions[observation.session] = state
        return []
    }

    // MARK: Request admission

    private func reduce(_ arrival: RequestArrival) -> [InteractionEffect] {
        guard arrival.id.session == arrival.session,
              (arrival.id.correlationKind == nil || arrival.id.correlationKind == arrival.kind),
              isCurrent(arrival.session) else {
            return diagnostic(.code(.invalidIdentity))
        }
        guard var session = sessions[arrival.session], !session.closed else {
            return diagnostic(.code(.staleGeneration))
        }

        switch (arrival.behavior, arrival.channel) {
        case (.blocking, .response(let token)) where token.session != arrival.session:
            return diagnostic(.code(.invalidChannel))
        case (.blocking, .none):
            return diagnostic(.code(.invalidChannel))
        case (.displayOnly, .response), (.nativeOwned, _):
            return diagnostic(.code(.invalidChannel))
        default: break
        }
        if case .permission = arrival.content, arrival.kind != .permission { return diagnostic(.code(.invalidIdentity)) }
        if case .question = arrival.content, arrival.kind != .question { return diagnostic(.code(.invalidIdentity)) }
        if case .nativeOwned = arrival.behavior { return diagnostic(.code(.invalidIdentity)) }

        if case let .replay(original, proof) = arrival.association {
            guard proof.isValid, original == arrival.id, var record = requests[original], !record.terminal else {
                return diagnostic(.stale("invalid replay proof"))
            }
            // A replay may replace a transport only after the previous binding has
            // ended. Its lifecycle, ordinal, dismiss and in-flight effect survive.
            if case .resolving = record.lifecycle, !record.finalizedTransport {
                return diagnostic(.code(.invalidChannel))
            }
            record.arrival = arrival
            record.finalizedTransport = false
            requests[original] = record
            return []
        }

        var requestID = arrival.id
        var normalizedArrival = arrival
        if requests[requestID] != nil {
            // A provider ID collision without replay proof is a new occurrence,
            // never an overwrite of the existing transport/lifecycle.
            guard case .stable = requestID.correlation else {
                return diagnostic(.stale("duplicate request identity"))
            }
            requestID = RequestID(session: arrival.session, correlation: .occurrence(dependencies.idFactory.makeOccurrenceID()))
            normalizedArrival = RequestArrival(id: requestID, session: arrival.session, kind: arrival.kind,
                                               behavior: arrival.behavior, content: arrival.content,
                                               channel: arrival.channel, association: .new,
                                               receivedAt: arrival.receivedAt)
        }
        session.nextOrdinal &+= 1
        let record = RequestRecord(arrival: normalizedArrival, ordinal: session.nextOrdinal)
        requests[requestID] = record
        session.queue.append(requestID)
        sessions[arrival.session] = session
        return []
    }

    // MARK: User actions

    private func reduce(_ action: InteractionUserAction) -> [InteractionEffect] {
        switch action {
        case let .dismiss(id):
            guard var record = requests[id], record.lifecycle == .pending else { return diagnostic(.stale("dismiss target unavailable")) }
            record.presentation = .dismissed; record.explicitReveal = false; requests[id] = record; return []
        case let .reveal(id):
            guard var record = requests[id], !record.terminal else { return diagnostic(.stale("reveal target unavailable")) }
            record.presentation = .normal; record.explicitReveal = true; requests[id] = record; return []
        case let .resolve(id, command):
            return beginResolution(id: id, command: command)
        case let .setAutoMode(session, intent):
            return beginAuto(session: session, intent: intent)
        case let .navigate(target):
            return beginNavigation(target)
        }
    }

    private func beginResolution(id: RequestID, command: ResolutionCommand) -> [InteractionEffect] {
        guard var record = requests[id], !record.terminal else { return diagnostic(.stale("resolve target unavailable")) }
        guard case .pending = record.lifecycle else { return [] } // resolving/awaiting is idempotent no-op
        guard let session = sessions[id.session] else { return diagnostic(.code(.invalidIdentity)) }
        guard let token = responseToken(for: record.arrival) else { return diagnostic(.code(.invalidChannel)) }
        if let earlier = earlierUnresolvedRequest(id, in: session) {
            record.error = .blockedByEarlierRequest(earlier); requests[id] = record
            return diagnostic(.stale("blocked by earlier request \(earlier)"))
        }
        guard commandIsAllowed(command, for: record.arrival) else {
            return diagnostic(.code(.invalidChannel))
        }
        let effectID = dependencies.idFactory.makeEffectID()
        record.lifecycle = .resolving(effectID); record.error = nil; record.explicitReveal = false
        requests[id] = record
        return [.deliverResolution(ResolutionEffect(effectID: effectID, requestID: id, token: token, command: command))]
    }

    private func beginAuto(session ref: SessionRef, intent: AutoModeIntent) -> [InteractionEffect] {
        guard var session = sessions[ref], !session.closed else { return diagnostic(.code(.staleGeneration)) }
        let token = dependencies.idFactory.makeAutoControlToken(for: ref)
        let compilation = AutoCommandCompiler().compile(intent, capabilities: session.capabilities.auto, token: token)
        guard case let .success(transaction) = compilation else {
            let error: AutoCompileError
            switch compilation {
            case .success: error = .unavailable
            case let .failure(value): error = value
            }
            let message: String
            switch error {
            case .bypassNotPermitted: message = "bypass mode is not permitted"
            case .independentChannelRequired: message = "Auto requires an independent control channel"
            case .unavailable: message = "Auto is unavailable for this provider"
            }
            feedbackNonce &+= 1
            return [.feedback(InteractionFeedback(message: message, severity: .warning))]
        }
        let effectID = dependencies.idFactory.makeEffectID()
        session.autoRequested = intent
        session.autoExpectedMode = transaction.commands.compactMap {
            if case let .setMode(mode) = $0 { return mode }
            return nil
        }.first
        session.autoPhase = .transitioning(effectID); sessions[ref] = session
        return [.changeAutoMode(AutoModeEffect(effectID: effectID, transaction: transaction))]
    }

    private func beginNavigation(_ target: NavigationTarget) -> [InteractionEffect] {
        let ref: SessionRef
        switch target {
        case let .session(session): ref = session
        case let .request(id): ref = id.session
        }
        guard let session = sessions[ref], !session.closed else { return diagnostic(.code(.staleGeneration)) }
        guard session.navigation.canNavigate else { return diagnostic(.stale("navigation unavailable")) }
        let effectID = dependencies.idFactory.makeEffectID(); navigationEffects[effectID] = target
        return [.navigate(NavigationEffect(effectID: effectID, target: target, context: session.navigation.context))]
    }

    // MARK: Adapter events

    private func reduce(_ event: InteractionAdapterEvent) -> [InteractionEffect] {
        switch event {
        case let .resolutionSucceeded(effectID, request, token):
            guard let record = requests[request], case .resolving(effectID) = record.lifecycle,
                  responseToken(for: record.arrival) == token else { return diagnostic(.code(.terminalLedgerHit)) }
            finish(request, effectID: effectID, token: token); return []
        case let .resolutionFailed(effectID, request, token, failure):
            guard var record = requests[request], case .resolving(effectID) = record.lifecycle,
                  responseToken(for: record.arrival) == token else { return diagnostic(.code(.terminalLedgerHit)) }
            switch failure {
            case let .deliveryUnknown(message):
                record.lifecycle = .awaitingExternalConfirmation(effectID); record.error = .adapterFailure(message)
            case let .notDelivered(message):
                record.lifecycle = .pending; record.error = .adapterFailure(message); record.presentation = .normal; record.explicitReveal = true
            case let .protocolRejected(message), let .unavailable(message):
                record.lifecycle = .pending; record.error = .adapterFailure(message); record.presentation = .normal; record.explicitReveal = true
            }
            requests[request] = record
            // Every response attempt is terminal to this EffectID, including a
            // not-delivered result. A late success must not resurrect the old
            // attempt after the user retries with a new effect.
            markLedger(effectID: effectID, request: request, token: token)
            return []
        case let .externallyResolved(request, evidence):
            guard let record = requests[request], !record.terminal else { return diagnostic(.code(.terminalLedgerHit)) }
            var effects: [InteractionEffect] = []
            if case let .resolving(effectID) = record.lifecycle, let token = responseToken(for: record.arrival) {
                let cancelID = dependencies.idFactory.makeEffectID()
                effects.append(.cancelTransport(CancelTransportEffect(effectID: cancelID, requestID: request, token: token, reason: .externallyResolved)))
                markLedger(effectID: effectID, request: request, token: token)
            }
            removeRequest(request)
            effects.append(contentsOf: evidence == .providerRequestID ? [] : [])
            return effects
        case let .transportEnded(token, evidence):
            return transportEnded(token: token, evidence: evidence)
        case let .sessionChannelEnded(session, _, evidence):
            guard isCurrent(session) else { return diagnostic(.code(.staleGeneration)) }
            if evidence == .providerSessionClosed {
                return closeRequests(for: session, reason: .sessionClosed)
            }
            markRequestsUnavailable(for: session)
            return []
        case let .autoModeDelivered(effectID, session):
            guard var state = sessions[session], case .transitioning(effectID) = state.autoPhase else { return diagnostic(.code(.terminalLedgerHit)) }
            state.autoPhase = .delivered(effectID); sessions[session] = state; return []
        case let .autoModeAwaitingConfirmation(effectID, session):
            guard var state = sessions[session], state.autoPhase == .delivered(effectID) || state.autoPhase == .transitioning(effectID) else { return diagnostic(.code(.terminalLedgerHit)) }
            state.autoPhase = .awaitingConfirmation(effectID); sessions[session] = state; return []
        case let .autoModeFailed(effectID, session, failure):
            guard var state = sessions[session], state.autoPhase == .transitioning(effectID) || state.autoPhase == .delivered(effectID) || state.autoPhase == .awaitingConfirmation(effectID) else { return diagnostic(.code(.terminalLedgerHit)) }
            let message = failureMessage(failure)
            state.autoPhase = .failed(message); state.autoRequested = nil; state.autoExpectedMode = nil; sessions[session] = state
            return [.feedback(InteractionFeedback(message: message, severity: .error))]
        case let .navigationFinished(effectID, outcome):
            guard let target = navigationEffects.removeValue(forKey: effectID) else { return diagnostic(.code(.terminalLedgerHit)) }
            switch outcome {
            case .succeeded: return []
            case .unavailable: return [.feedback(InteractionFeedback(message: "Navigation unavailable", severity: .warning))]
            case let .failed(message):
                if case let .request(id) = target, var record = requests[id] { record.error = .adapterFailure(message); record.explicitReveal = true; requests[id] = record }
                feedbackNonce &+= 1
                return [.feedback(InteractionFeedback(message: message, severity: .error))]
            }
        }
    }

    private func transportEnded(token: TransportToken, evidence: TransportEndEvidence) -> [InteractionEffect] {
        guard let pair = requests.first(where: { responseToken(for: $0.value.arrival) == token }) else {
            return diagnostic(.code(.terminalLedgerHit))
        }
        let id = pair.key
        guard var record = requests[id], !record.terminal else { return diagnostic(.code(.terminalLedgerHit)) }
        switch evidence {
        case let .providerResolved(external):
            return reduce(.externallyResolved(id, evidence: external))
        case .responseDelivered:
            record.error = .unavailable("transport completed without a resolution fact")
        case .peerDisconnected, .timedOut, .replacement:
            record.error = .unavailable("transport ended before delivery")
        }
        record.lifecycle = .pending; record.presentation = .normal; record.explicitReveal = true; requests[id] = record
        guard !record.finalizedTransport else { return [] }
        record.finalizedTransport = true; requests[id] = record
        guard let session = sessions[id.session], session.capabilities.canNeutralFinalize else { return diagnostic(.code(.invalidChannel)) }
        let effectID = dependencies.idFactory.makeEffectID()
        let reason: TransportEndReason
        switch evidence {
        case .timedOut: reason = .timedOut
        case .replacement: reason = .replacement
        default: reason = .peerDisconnected
        }
        return [.finalizeTransport(FinalizeTransportEffect(effectID: effectID, requestID: id, token: token, finalization: .providerSafeNeutral(reason)))]
    }

    private func closeRequests(for session: SessionRef, reason: CancellationReason) -> [InteractionEffect] {
        var effects: [InteractionEffect] = []
        for id in sessions[session]?.queue ?? [] {
            guard let record = requests[id], !record.terminal else { continue }
            if case .resolving = record.lifecycle, let token = responseToken(for: record.arrival) {
                let effectID = dependencies.idFactory.makeEffectID()
                effects.append(.cancelTransport(CancelTransportEffect(effectID: effectID, requestID: id, token: token, reason: reason)))
            }
            removeRequest(id)
        }
        return effects
    }

    private func markRequestsUnavailable(for session: SessionRef) {
        for id in sessions[session]?.queue ?? [] {
            guard var record = requests[id], !record.terminal else { continue }
            record.error = .unavailable("session transport ended")
            record.presentation = .normal
            record.explicitReveal = true
            requests[id] = record
        }
    }

    // MARK: Invariants and snapshots

    private func isCurrent(_ ref: SessionRef) -> Bool {
        guard latestGeneration[ref.key] == ref.generation else { return false }
        guard let state = sessions[ref] else {
            // The first observation establishes the local current namespace.
            return latestGeneration[ref.key] == ref.generation
        }
        return !state.closed
    }

    private func responseToken(for arrival: RequestArrival) -> TransportToken? {
        guard case let .response(token) = arrival.channel else { return nil }; return token
    }

    private func earlierUnresolvedRequest(_ id: RequestID, in session: SessionState) -> RequestID? {
        for candidate in session.queue {
            if candidate == id { return nil }
            guard let record = requests[candidate], !record.terminal else { continue }
            switch record.lifecycle {
            case .pending, .resolving, .awaitingExternalConfirmation: return candidate
            }
        }
        return nil
    }

    private func commandIsAllowed(_ command: ResolutionCommand, for arrival: RequestArrival) -> Bool {
        guard case let .blocking(capabilities) = arrival.behavior else { return false }
        switch (arrival.kind, arrival.content, command) {
        case (.permission, .permission(let content), .allowOnce):
            if case .plan = content.variant { return false }; return true
        case (.permission, .permission(let content), .allowAlways):
            if case .plan = content.variant { return false }; return capabilities.allowAlways
        case (.permission, .permission(let content), .allowPlan(let mode)):
            guard case .plan = content.variant else { return false }; return capabilities.planModes.contains(mode)
        case (.permission, _, .deny): return true
        case (.question, .question(let content), .answer(let answers)):
            return validate(answers: answers, against: content)
        case (.question, .question, .questionAction(let action, _)):
            return capabilities.questionActions.contains(action)
        default: return false
        }
    }

    private func validate(answers: [QuestionAnswer], against content: QuestionContent) -> Bool {
        let keys = content.answerSchema.keysInProviderOrder
        guard answers.count <= keys.count else { return false }
        var seen: Set<String> = []
        for answer in answers {
            guard keys.contains(answer.questionKey), seen.insert(answer.questionKey).inserted else { return false }
            for value in answer.values {
                switch value {
                case let .custom(text): guard content.answerSchema.allowsCustomText || text.sensitivity == .public else { return false }
                case .option: break
                }
            }
        }
        return true
    }

    private func providerMode(for intent: AutoModeIntent) -> ProviderPermissionMode? {
        switch intent {
        case .off: return .defaultMode
        case .enable: return .auto
        case .bypassExplicit: return .bypassPermissions
        }
    }

    private func observedMode(_ observed: ObservedPermissionMode, matches expected: ProviderPermissionMode) -> Bool {
        switch (observed, expected) {
        case (.defaultMode, .defaultMode), (.auto, .auto), (.acceptEdits, .acceptEdits), (.bypassPermissions, .bypassPermissions): return true
        default: return false
        }
    }

    private func failureMessage(_ failure: AdapterFailure) -> String {
        switch failure {
        case let .notDelivered(message), let .deliveryUnknown(message), let .protocolRejected(message), let .unavailable(message): return message
        }
    }

    private func finish(_ id: RequestID, effectID: EffectID, token: TransportToken) {
        markLedger(effectID: effectID, request: id, token: token)
        removeRequest(id)
    }

    private func removeRequest(_ id: RequestID) {
        requests.removeValue(forKey: id)
        guard var session = sessions[id.session] else { return }
        session.queue.removeAll { $0 == id }; sessions[id.session] = session
    }

    private func markLedger(effectID: EffectID, request: RequestID?, token: TransportToken?) {
        let entry = LedgerEntry(endedAt: dependencies.clock.now, request: request, token: token)
        terminalLedger[effectID] = entry
        if let token { terminalTokens[token] = entry }
        pruneLedger()
    }

    private func pruneLedger() {
        let cutoff = dependencies.clock.now.addingTimeInterval(-dependencies.ledgerPolicy.retention.timeInterval)
        terminalLedger = terminalLedger.filter { $0.value.endedAt > cutoff }
        terminalTokens = terminalTokens.filter { $0.value.endedAt > cutoff }
        let maxEntries = dependencies.ledgerPolicy.maxEntries
        if terminalLedger.count > maxEntries {
            let ids = terminalLedger.sorted { $0.value.endedAt < $1.value.endedAt }.prefix(terminalLedger.count - maxEntries).map(\.key)
            ids.forEach { terminalLedger.removeValue(forKey: $0) }
        }
        if terminalTokens.count > maxEntries {
            let tokens = terminalTokens.sorted { $0.value.endedAt < $1.value.endedAt }.prefix(terminalTokens.count - maxEntries).map(\.key)
            tokens.forEach { terminalTokens.removeValue(forKey: $0) }
        }
    }

    private func diagnostic(_ diagnostic: InteractionDiagnostic) -> [InteractionEffect] { [.diagnostic(diagnostic)] }

    private func rebuildSnapshot() {
        var localSessions: [SessionRef: InteractionSessionSnapshot] = [:]
        var localRequests: [RequestID: InteractionRequestSnapshot] = [:]
        var badges: [SessionRef: Badge] = [:]

        for (ref, state) in sessions {
            let activeIDs = state.queue.filter { requests[$0] != nil }
            let activeRecords = activeIDs.compactMap { requests[$0] }
            let kinds = Set(activeRecords.map { $0.arrival.kind })
            if !activeRecords.isEmpty { badges[ref] = Badge(pendingCount: activeRecords.count, kinds: kinds) }
            for (position, id) in activeIDs.enumerated() {
                guard let record = requests[id] else { continue }
                localRequests[id] = InteractionRequestSnapshot(id: id, session: ref, kind: record.arrival.kind,
                                                               content: record.arrival.content, lifecycle: record.lifecycle,
                                                               presentation: record.presentation,
                                                               availableActions: availableActions(for: record.arrival),
                                                               queuePosition: position, error: record.error)
            }
            localSessions[ref] = InteractionSessionSnapshot(session: ref, facts: state.facts,
                                                             completion: state.completion, pendingCount: activeRecords.count,
                                                             pendingKinds: kinds,
                                                             auto: AutoSnapshot(observedMode: state.observedMode,
                                                                                requestedMode: state.autoRequested,
                                                                                phase: state.autoPhase,
                                                                                capabilities: state.capabilities.auto,
                                                                                inFlightEffect: state.autoPhase.effectID),
                                                             navigation: state.navigation)
        }

        let prominent = selectProminent()
        let surface: Surface
        if let prominent { surface = .request(prominent) }
        else if let completion = sessions.values.compactMap(\.completion).max(by: { $0.revision < $1.revision }) { surface = .completion(completion) }
        else if !localSessions.isEmpty { surface = .sessionList }
        else { surface = .collapsed }
        let presentation = PresentationSnapshot(surface: surface, prominentRequest: prominent, badgeCounts: badges, feedbackNonce: feedbackNonce)
        let externalRequests = Dictionary(uniqueKeysWithValues: localRequests.map { id, request in
            (id, redacted(request))
        })
        let externalSessions = Dictionary(uniqueKeysWithValues: localSessions.map { ref, session in
            (ref, RedactedSessionSnapshot(session: ref, title: session.facts.title ?? session.facts.project ?? session.facts.source,
                                           pendingCount: session.pendingCount, pendingKinds: session.pendingKinds))
        })
        let externalSurface: RedactedSurface
        switch surface {
        case .collapsed: externalSurface = .collapsed
        case .sessionList: externalSurface = .sessionList
        case let .request(id): externalSurface = .request(id)
        case let .completion(notice): externalSurface = .completion(RedactedCompletionNotice(session: notice.session, revision: notice.revision))
        }
        let externalPresentation = RedactedPresentationSnapshot(surface: externalSurface, prominentRequest: prominent)
        currentSnapshot = InteractionSnapshot(revision: revision, local: LocalInteractionSnapshot(sessions: localSessions, requests: localRequests, presentation: presentation), external: RedactedInteractionSnapshot(sessions: externalSessions, requests: externalRequests, presentation: externalPresentation))
    }

    private func selectProminent() -> RequestID? {
        var candidates: [(RequestID, Int, UInt64, String)] = []
        for (id, record) in requests {
            guard !record.terminal, case .pending = record.lifecycle else {
                if case .awaitingExternalConfirmation = record.lifecycle { continue }
                continue
            }
            let automaticPresentation: VisibilityPresentation
            if let state = sessions[id.session] {
                automaticPresentation = dependencies.presentationPolicy.automaticPresentation(
                    for: state.visibilityObservation,
                    now: dependencies.clock.now
                )
            } else {
                automaticPresentation = .prominent
            }
            let automaticEligible = automaticPresentation == .prominent
            guard record.explicitReveal || automaticEligible else { continue }
            let priority: Int
            if record.error != nil { priority = 0 }
            else if record.explicitReveal { priority = 1 }
            else if record.presentation == .normal { priority = 2 }
            else { continue }
            let tie: String
            switch id.correlation { case let .stable(key): tie = key.upstreamID; case let .occurrence(uuid): tie = uuid.uuidString }
            candidates.append((id, priority, record.ordinal, tie))
        }
        return candidates.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.3 < $1.3
        }.first?.0
    }

    private func availableActions(for arrival: RequestArrival) -> [AvailableResolutionAction] {
        guard case let .blocking(capabilities) = arrival.behavior else { return [] }
        switch (arrival.kind, arrival.content) {
        case (.permission, .permission(let content)):
            if case .plan = content.variant {
                return capabilities.planModes.sorted(by: { String(describing: $0) < String(describing: $1) }).map(AvailableResolutionAction.allowPlan)
                    + [.deny]
            }
            var actions: [AvailableResolutionAction] = [.allowOnce]
            if capabilities.allowAlways { actions.append(.allowAlways) }
            actions.append(.deny); return actions
        case (.question, .question):
            var actions: [AvailableResolutionAction] = [.answer]
            actions.append(contentsOf: capabilities.questionActions.sorted { String(describing: $0) < String(describing: $1) }.map { .questionAction($0) })
            return actions
        default: return []
        }
    }

    private func redacted(_ request: InteractionRequestSnapshot) -> RedactedRequestSnapshot {
        let sensitivity: Sensitivity
        let title: String?
        switch request.content {
        case let .permission(content):
            sensitivity = content.displayInput.map(sensitivity(of:)) ?? .public
            title = sensitivity == .public ? (content.summary ?? content.toolName) : "Permission (redacted)"
        case let .question(content):
            sensitivity = content.items.reduce(.public) { maxSensitivity($0, $1.prompt.sensitivity) }
            title = sensitivity == .public ? "Question" : "Question (redacted)"
        }
        let pending: Bool
        switch request.lifecycle { case .pending, .resolving, .awaitingExternalConfirmation: pending = true }
        let kinds: Set<ExternalActionKind>
        switch request.kind {
        case .permission: kinds = [.allow, .deny]
        case .question: kinds = request.availableActions.contains(.answer) ? [.answer] : []
        }
        return RedactedRequestSnapshot(id: request.id, session: request.session, kind: request.kind, title: title,
                                       sensitivity: sensitivity, pending: pending,
                                       actionable: request.lifecycle == .pending,
                                       availableActionKinds: kinds)
    }

    private func sensitivity(of value: DisplayValue) -> Sensitivity {
        switch value {
        case .redacted(let sensitivity): return sensitivity
        case .list(let values): return values.reduce(.public) { maxSensitivity($0, sensitivity(of: $1)) }
        case .object(let values): return values.values.reduce(.public) { maxSensitivity($0, sensitivity(of: $1)) }
        default: return .public
        }
    }

    private func maxSensitivity(_ lhs: Sensitivity, _ rhs: Sensitivity) -> Sensitivity {
        let rank: [Sensitivity: Int] = [.public: 0, .privateData: 1, .secret: 2]
        return rank[lhs, default: 0] >= rank[rhs, default: 0] ? lhs : rhs
    }
}

private extension RequestID {
    var correlationKind: InteractionRequestKind? {
        guard case let .stable(key) = correlation else { return nil }
        return key.kind
    }
}

private extension AutoCompileError {
    var failureValue: AutoCompileError { self }
}

/// Naming alias used by migration adapters while the concrete store remains the
/// sole owner of the reducer state.
public typealias InteractionCenter = InteractionCenterStore
