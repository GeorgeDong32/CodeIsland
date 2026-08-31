import Foundation

public extension AutoPhase {
    var effectID: EffectID? {
        switch self {
        case let .transitioning(effectID), let .delivered(effectID),
             let .awaitingConfirmation(effectID):
            return effectID
        case .idle, .confirmed, .unknown, .failed:
            return nil
        }
    }
}

/// The fork-owned Auto state for one concrete session generation.
///
/// This value intentionally lives beside, rather than inside, `SessionSnapshot`.
/// `SessionSnapshot.permissionMode` is an upstream fact; requested mode,
/// in-flight effects, and the delivery phase belong to CodeIsland's interaction
/// lifecycle and must not be restored as if they were CLI facts.
public struct InteractionAutoContext: Sendable, Equatable, Codable {
    public let capabilities: AutoCapabilities
    public private(set) var observedMode: ObservedPermissionMode?
    public private(set) var requestedMode: AutoModeIntent?
    public private(set) var phase: AutoPhase
    public private(set) var inFlightEffect: EffectID?

    public init(
        capabilities: AutoCapabilities = AutoCapabilities(),
        observedMode: ObservedPermissionMode? = nil,
        requestedMode: AutoModeIntent? = nil,
        phase: AutoPhase = .idle,
        inFlightEffect: EffectID? = nil
    ) {
        self.capabilities = capabilities
        self.observedMode = observedMode
        self.requestedMode = requestedMode
        self.phase = phase
        self.inFlightEffect = inFlightEffect
    }

    public var snapshot: AutoSnapshot {
        AutoSnapshot(
            observedMode: observedMode,
            requestedMode: requestedMode,
            phase: phase,
            capabilities: capabilities,
            inFlightEffect: inFlightEffect
        )
    }

    public mutating func updateCapabilities(_ capabilities: AutoCapabilities) {
        self = InteractionAutoContext(
            capabilities: capabilities,
            observedMode: observedMode,
            requestedMode: requestedMode,
            phase: phase,
            inFlightEffect: inFlightEffect
        )
    }

    /// Records the current provider fact. A delivery acknowledgement never
    /// reaches this method; only this observation can move Auto to confirmed.
    public mutating func observe(_ mode: ObservedPermissionMode) {
        observedMode = mode

        guard let expected = expectedMode else { return }
        if mode.matches(expected) {
            phase = .confirmed(expected)
            inFlightEffect = nil
        } else if isKnown(mode), phase != .idle {
            // The CLI changed the mode outside this interaction. Do not keep
            // presenting an old request as confirmed.
            phase = .unknown
            requestedMode = nil
            inFlightEffect = nil
        }
    }

    /// Starts one independent Auto command transaction.
    public mutating func request(
        _ intent: AutoModeIntent,
        effectID: EffectID,
        expectedMode: ProviderPermissionMode
    ) {
        requestedMode = intent
        inFlightEffect = effectID
        phase = .transitioning(effectID)
        // `AutoPhase` carries only the effect ID. Keep the expected provider
        // mode in the requested intent / observation boundary; confirmation
        // compares against the deterministic mapping below.
        _ = expectedMode
    }

    public mutating func markDelivered(effectID: EffectID) -> Bool {
        guard inFlightEffect == effectID,
              case .transitioning(effectID) = phase else { return false }
        phase = .delivered(effectID)
        return true
    }

    public mutating func markAwaitingConfirmation(effectID: EffectID) -> Bool {
        guard inFlightEffect == effectID else { return false }
        switch phase {
        case .transitioning(effectID), .delivered(effectID):
            phase = .awaitingConfirmation(effectID)
            return true
        default:
            return false
        }
    }

    public mutating func fail(effectID: EffectID, message: String) -> Bool {
        guard inFlightEffect == effectID else { return false }
        switch phase {
        case .transitioning(effectID), .delivered(effectID), .awaitingConfirmation(effectID):
            phase = .failed(message)
            requestedMode = nil
            inFlightEffect = nil
            return true
        default:
            return false
        }
    }

    /// A lost control channel is not evidence that the provider changed mode.
    /// Clear local intent and expose an unknown state until a fresh observation.
    public mutating func disconnect() {
        observedMode = nil
        requestedMode = nil
        inFlightEffect = nil
        phase = .unknown
    }

    private var expectedMode: ProviderPermissionMode? {
        guard let requestedMode else { return nil }
        switch requestedMode {
        case .off: return .defaultMode
        case .enable:
            if capabilities.nativeAuto { return .auto }
            if capabilities.acceptEditsRules { return .acceptEdits }
            return nil
        case .bypassExplicit: return .bypassPermissions
        }
    }

    private func isKnown(_ mode: ObservedPermissionMode) -> Bool {
        if case .unknown = mode { return false }
        return true
    }
}

private extension ObservedPermissionMode {
    func matches(_ expected: ProviderPermissionMode) -> Bool {
        switch (self, expected) {
        case (.defaultMode, .defaultMode), (.auto, .auto),
             (.acceptEdits, .acceptEdits), (.bypassPermissions, .bypassPermissions):
            return true
        default:
            return false
        }
    }
}

/// SessionRef-keyed fork state. The store is deliberately not persistent:
/// after relaunch, the CLI must report a fresh observation before Auto is shown
/// as confirmed.
@MainActor
public final class InteractionSessionContextStore {
    private var contexts: [SessionRef: InteractionSessionContext] = [:]
    private var fallbackRevisions: [SessionRef: UInt64] = [:]

    public init() {}

    public var sessions: [SessionRef] { contexts.keys.sorted(by: Self.sort).map { $0 } }

    public func context(for session: SessionRef) -> InteractionSessionContext? {
        contexts[session]
    }

    public func snapshot(for session: SessionRef) -> AutoSnapshot? {
        contexts[session]?.auto.snapshot
    }

    @discardableResult
    public func observe(_ observation: SessionObservation) -> AutoSnapshot {
        var context = contexts[observation.session] ?? InteractionSessionContext(
            session: observation.session,
            capabilities: observation.providerCapabilities.auto
        )
        context.auto.updateCapabilities(observation.providerCapabilities.auto)
        context.auto.observe(observation.permissionMode)
        if observation.lifecycle == .closed {
            context.close()
        }
        contexts[observation.session] = context
        fallbackRevisions[observation.session] = max(fallbackRevisions[observation.session] ?? 0, observation.revision)
        return context.auto.snapshot
    }

    @discardableResult
    public func observe(
        session: SessionRef,
        permissionMode: ObservedPermissionMode,
        capabilities: AutoCapabilities
    ) -> AutoSnapshot {
        observe(SessionObservation(
            session: session,
            permissionMode: permissionMode,
            providerCapabilities: ProviderCapabilities(auto: capabilities),
            revision: nextRevision(for: session)
        ))
    }

    /// Starts Auto only after the compiler has produced a transaction for this
    /// exact SessionRef. A permission token is never accepted here.
    public func beginAuto(
        session: SessionRef,
        intent: AutoModeIntent,
        effectID: EffectID,
        token: AutoControlToken,
        compiler: AutoCommandCompiler = AutoCommandCompiler()
    ) -> Result<AutoCommandTransaction, AutoCompileError> {
        guard token.session == session,
              var context = contexts[session], !context.isClosed else {
            return .failure(.unavailable)
        }
        let result = compiler.compile(intent, capabilities: context.auto.capabilities, token: token)
        guard case let .success(transaction) = result else { return result }
        guard let expected = transaction.commands.compactMap({ command -> ProviderPermissionMode? in
            guard case let .setMode(mode) = command else { return nil }
            return mode
        }).first else { return .failure(.unavailable) }
        context.auto.request(intent, effectID: effectID, expectedMode: expected)
        contexts[session] = context
        return .success(transaction)
    }

    @discardableResult
    public func markDelivered(_ effectID: EffectID, session: SessionRef) -> Bool {
        guard var context = contexts[session] else { return false }
        let changed = context.auto.markDelivered(effectID: effectID)
        if changed { contexts[session] = context }
        return changed
    }

    @discardableResult
    public func markAwaitingConfirmation(_ effectID: EffectID, session: SessionRef) -> Bool {
        guard var context = contexts[session] else { return false }
        let changed = context.auto.markAwaitingConfirmation(effectID: effectID)
        if changed { contexts[session] = context }
        return changed
    }

    @discardableResult
    public func fail(_ effectID: EffectID, session: SessionRef, message: String) -> Bool {
        guard var context = contexts[session] else { return false }
        let changed = context.auto.fail(effectID: effectID, message: message)
        if changed { contexts[session] = context }
        return changed
    }

    /// Clears only this concrete generation. A same provider/session ID with a
    /// new generation cannot inherit the old Auto intent.
    public func disconnect(session: SessionRef) {
        guard var context = contexts[session] else { return }
        context.auto.disconnect()
        contexts[session] = context
    }

    public func remove(session: SessionRef) {
        contexts.removeValue(forKey: session)
        fallbackRevisions.removeValue(forKey: session)
    }

    public func close(session: SessionRef) {
        guard var context = contexts[session] else { return }
        context.close()
        contexts[session] = context
    }

    private static func sort(_ lhs: SessionRef, _ rhs: SessionRef) -> Bool {
        if lhs.key.provider.rawValue != rhs.key.provider.rawValue {
            return lhs.key.provider.rawValue < rhs.key.provider.rawValue
        }
        if lhs.key.providerSessionID != rhs.key.providerSessionID {
            return lhs.key.providerSessionID < rhs.key.providerSessionID
        }
        return lhs.generation < rhs.generation
    }

    private func nextRevision(for session: SessionRef) -> UInt64 {
        // This helper is only for direct adapter callers that do not have an
        // upstream revision. SessionObservationAdapter remains the production
        // owner of revisions and never uses this fallback.
        let next = (fallbackRevisions[session] ?? 0) + 1
        fallbackRevisions[session] = next
        return next
    }
}

public struct InteractionSessionContext: Sendable, Equatable, Codable {
    public let session: SessionRef
    public fileprivate(set) var auto: InteractionAutoContext
    public private(set) var closed: Bool

    public init(session: SessionRef, capabilities: AutoCapabilities = AutoCapabilities()) {
        self.session = session
        self.auto = InteractionAutoContext(capabilities: capabilities)
        self.closed = false
    }

    fileprivate var isClosed: Bool { closed }

    public mutating func close() {
        closed = true
        auto.disconnect()
    }
}

/// A recording Auto adapter used by production coordinators and contract tests
/// as the local-substitutable seam. It never runs a permission continuation and
/// never infers confirmation from submission.
public final class InMemoryAutoCommandAdapter: AutoCommandAdapter, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var submissions: [AutoCommandTransaction] = []
    private var completions: [AutoControlToken: (Result<AutoDelivery, AutoAdapterFailure>) -> Void] = [:]

    public init() {}

    public func submit(
        _ transaction: AutoCommandTransaction,
        completion: @escaping (Result<AutoDelivery, AutoAdapterFailure>) -> Void
    ) {
        guard transaction.controlToken.session == transaction.session else {
            completion(.failure(AutoAdapterFailure(message: "Auto control token/session mismatch")))
            return
        }
        lock.lock()
        guard completions[transaction.controlToken] == nil else {
            lock.unlock()
            completion(.failure(AutoAdapterFailure(message: "Auto control token already submitted")))
            return
        }
        submissions.append(transaction)
        completions[transaction.controlToken] = completion
        lock.unlock()
    }

    /// Delivers an adapter acknowledgement for a previously submitted control
    /// token. The caller supplies the effect ID because the effect is owned by
    /// the Center, not fabricated by the transport adapter.
    public func acknowledge(
        token: AutoControlToken,
        effectID: EffectID,
        result: Result<Void, AutoAdapterFailure> = .success(())
    ) {
        lock.lock()
        let completion = completions.removeValue(forKey: token)
        lock.unlock()
        guard let completion else { return }
        switch result {
        case .success: completion(.success(AutoDelivery(effectID: effectID)))
        case let .failure(error): completion(.failure(error))
        }
    }
}
