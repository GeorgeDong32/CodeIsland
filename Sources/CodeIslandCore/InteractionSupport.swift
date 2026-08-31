import Foundation

public extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

// MARK: - Input envelopes omitted from the model file to keep the public vocabulary grouped

public enum InteractionInput: Sendable, Equatable {
    case sessionObserved(SessionObservation)
    case requestArrived(RequestArrival)
    case nativePromptObserved(NativePromptObservation)
    case visibilityChanged(VisibilityObservation)
    case bindBufferedRequests(SessionRef)
    case expireBufferedRequests(Date)
    case user(InteractionUserAction)
    case adapter(InteractionAdapterEvent)
}

public protocol InteractionClock: Sendable {
    var now: Date { get }
}

public final class SystemInteractionClock: InteractionClock, @unchecked Sendable {
    public init() {}
    public var now: Date { Date() }
}

/// A deterministic clock for reducer traces. It is deliberately a value boundary
/// (rather than a Task/sleep dependency) so tests never depend on wall time.
public final class TestClock: InteractionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    public init(_ initial: Date = Date(timeIntervalSince1970: 0)) { value = initial }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func advance(by duration: Duration) {
        lock.lock(); value = value.addingTimeInterval(duration.timeInterval); lock.unlock()
    }

    public func set(_ date: Date) {
        lock.lock(); value = date; lock.unlock()
    }
}

public protocol InteractionIDFactory: TransportTokenFactory, Sendable {
    func makeEffectID() -> EffectID
    func makeOccurrenceID() -> UUID
    func makeBufferToken() -> BufferToken
    func makeTransportToken(for session: SessionRef) -> TransportToken
    func makeAutoControlToken(for session: SessionRef) -> AutoControlToken
}

public final class RandomInteractionIDFactory: InteractionIDFactory, @unchecked Sendable {
    public init() {}
    public func makeEffectID() -> EffectID { EffectID(UUID()) }
    public func makeOccurrenceID() -> UUID { UUID() }
    public func makeBufferToken() -> BufferToken { BufferToken(UUID()) }
    public func makeTransportToken(for session: SessionRef) -> TransportToken { TransportToken(session: session, rawValue: UUID()) }
    public func makeAutoControlToken(for session: SessionRef) -> AutoControlToken { AutoControlToken(session: session, rawValue: UUID()) }
    public func bind(_ handle: ProviderResponseHandle, to session: SessionRef) -> TransportToken {
        // The provider handle remains opaque. A new local token makes its generation
        // binding explicit and prevents a raw response handle from crossing sessions.
        TransportToken(session: session, rawValue: handle.rawValue)
    }
}

/// Predictable UUIDs make interaction traces stable without weakening production IDs.
public final class DeterministicIDFactory: InteractionIDFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64

    public init(seed: UInt64 = 1) { nextValue = seed }

    private func uuid() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let n = nextValue; nextValue &+= 1
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: n.bigEndian) { raw in
            for (index, byte) in raw.enumerated() { bytes[8 + index] = byte }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public func makeEffectID() -> EffectID { EffectID(uuid()) }
    public func makeOccurrenceID() -> UUID { uuid() }
    public func makeBufferToken() -> BufferToken { BufferToken(uuid()) }
    public func makeTransportToken(for session: SessionRef) -> TransportToken { TransportToken(session: session, rawValue: uuid()) }
    public func makeAutoControlToken(for session: SessionRef) -> AutoControlToken { AutoControlToken(session: session, rawValue: uuid()) }
    public func bind(_ handle: ProviderResponseHandle, to session: SessionRef) -> TransportToken {
        makeTransportToken(for: session)
    }
}

// MARK: - Adapter ports

public protocol InteractionEffectExecutor {
    func execute(_ effects: [InteractionEffect], report: @escaping (InteractionAdapterEvent) -> Void)
}

public protocol AutoCommandAdapter {
    func submit(_ transaction: AutoCommandTransaction, completion: @escaping (Result<AutoDelivery, AutoAdapterFailure>) -> Void)
}

public struct AutoDelivery: Sendable, Equatable {
    public let effectID: EffectID
    public init(effectID: EffectID) { self.effectID = effectID }
}

/// Standalone bounded terminal ledger for adapters and trace harnesses. The
/// Center has an equivalent private ledger so its public interface stays at two
/// entries; adapters can use this helper without retaining unbounded histories.
public final class InteractionTerminalLedger: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let effectID: EffectID
        public let request: RequestID?
        public let token: TransportToken?
        public let endedAt: Date

        public init(effectID: EffectID, request: RequestID? = nil, token: TransportToken? = nil, endedAt: Date) {
            self.effectID = effectID; self.request = request; self.token = token; self.endedAt = endedAt
        }
    }

    private let policy: TerminalLedgerPolicy
    private var entries: [EffectID: Entry] = [:]
    private let lock = NSLock()

    public init(policy: TerminalLedgerPolicy = TerminalLedgerPolicy()) { self.policy = policy }

    public func record(_ entry: Entry, now: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now ?? entry.endedAt)
        entries[entry.effectID] = entry
        evictLocked()
    }

    public func contains(_ effectID: EffectID, now: Date? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now ?? Date())
        return entries[effectID] != nil
    }

    public func contains(token: TransportToken, now: Date? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now ?? Date())
        return entries.values.contains { $0.token == token }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: Date())
        return entries.count
    }

    public func prune(now: Date) {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: now); evictLocked()
    }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.retention.timeInterval)
        entries = entries.filter { $0.value.endedAt > cutoff }
    }

    private func evictLocked() {
        guard entries.count > policy.maxEntries else { return }
        let removeCount = entries.count - policy.maxEntries
        for key in entries.sorted(by: { $0.value.endedAt < $1.value.endedAt }).prefix(removeCount).map(\.key) {
            entries.removeValue(forKey: key)
        }
    }
}

public struct AutoAdapterFailure: Sendable, Equatable, Error {
    public let message: String
    public init(message: String) { self.message = message }
}

public protocol OnceResponder<Response>: Sendable {
    associatedtype Response: Sendable
    func finish(_ response: Response) -> Bool
}

public final class InMemoryOnceResponder<Response: Sendable>: OnceResponder, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    public private(set) var responses: [Response] = []

    public init() {}

    public func finish(_ response: Response) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true; responses.append(response); return true
    }
}

public protocol TransportFinalizer {
    func finalize(_ request: TransportFinalizationRequest, responder: any OnceResponder<ProviderNeutralResponse>) -> TransportFinalizationResult
}

public final class InMemoryTransportFinalizer: TransportFinalizer, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var requests: [TransportFinalizationRequest] = []
    public private(set) var results: [TransportFinalizationResult] = []
    private var responders: [TransportToken: InMemoryOnceResponder<ProviderNeutralResponse>] = [:]

    public init() {}

    public func finalize(_ request: TransportFinalizationRequest, responder: any OnceResponder<ProviderNeutralResponse>) -> TransportFinalizationResult {
        lock.lock(); requests.append(request); lock.unlock()
        let didFinish = responder.finish(request.response)
        let result: TransportFinalizationResult = didFinish
            ? .finalized(NeutralFinalizationReceipt(token: request.token, response: request.response))
            : .failed(.unavailable("responder already finalized"))
        lock.lock(); results.append(result); lock.unlock()
        return result
    }
}

public final class RecordingInteractionEffectExecutor: InteractionEffectExecutor, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var submitted: [[InteractionEffect]] = []
    public var automaticallyReport: ((InteractionEffect) -> InteractionAdapterEvent?)?

    public init() {}

    public func execute(_ effects: [InteractionEffect], report: @escaping (InteractionAdapterEvent) -> Void) {
        lock.lock(); submitted.append(effects); let reporter = automaticallyReport; lock.unlock()
        for effect in effects {
            if let event = reporter?(effect) { report(event) }
        }
    }
}

// MARK: - Auto compiler

public struct AutoCommandCompiler: Sendable {
    public static let ownedRules: [AutoRule] = [.tool("codeisland:auto", scope: nil)]

    public init() {}

    public func compile(_ intent: AutoModeIntent, capabilities: AutoCapabilities, token: AutoControlToken) -> Result<AutoCommandTransaction, AutoCompileError> {
        guard capabilities.independentControlChannel else { return .failure(.independentChannelRequired) }
        let commands: [AutoCommand]
        switch intent {
        case .enable:
            if capabilities.nativeAuto {
                commands = [.setMode(.auto)]
            } else if capabilities.acceptEditsRules {
                commands = [.setMode(.acceptEdits), .addRules(Self.ownedRules)]
            } else {
                return .failure(.unavailable)
            }
        case .off:
            commands = [.setMode(.defaultMode), .removeRules(Self.ownedRules)]
        case .bypassExplicit:
            guard capabilities.explicitBypass else { return .failure(.bypassNotPermitted) }
            commands = [.setMode(.bypassPermissions)]
        }
        return .success(AutoCommandTransaction(session: token.session, commands: commands, controlToken: token))
    }
}

// MARK: - Admission and compatibility vocabulary

public enum HookAdmissionBranch: Sendable, Equatable, Codable {
    case regularPermission
    case exitPlanMode
    case askUserQuestion
    case notificationQuestion
    case cursorNativePrompt
    case safeBuiltInTool
    case alwaysProceedSource
    case providerOwnedReview
    case ordinaryEvent
    case malformed
    case unsupported
}

public struct NormalizedHookEvent: Sendable, Equatable {
    public let provider: ProviderID
    public let sessionKey: SessionKey
    public let branch: HookAdmissionBranch
    public let content: RequestContent?
    public let receivedAt: Date

    public init(provider: ProviderID, sessionKey: SessionKey, branch: HookAdmissionBranch, content: RequestContent? = nil, receivedAt: Date = Date()) {
        self.provider = provider; self.sessionKey = sessionKey; self.branch = branch; self.content = content; self.receivedAt = receivedAt
    }
}

public struct RequestAdmissionContext: Sendable, Equatable {
    public let session: SessionRef?
    public let capabilities: ProviderCapabilities
    public let sourceAllowed: Bool

    public init(session: SessionRef? = nil, capabilities: ProviderCapabilities = ProviderCapabilities(), sourceAllowed: Bool = true) {
        self.session = session; self.capabilities = capabilities; self.sourceAllowed = sourceAllowed
    }
}

public enum ProviderResponsePlan: Sendable, Equatable, Codable {
    case safeToolAllow
    case alwaysProceedAllow
    case providerOwnedAck
    case malformedQuestionFallback
    case ordinaryAck
}

public enum QuarantineReason: Sendable, Equatable, Codable {
    case noSafeNeutralResponse
    case missingGeneration
    case bufferLimit
    case unsupportedChannel
}

public enum AdmissionIgnoreReason: Sendable, Equatable, Codable {
    case unsupportedSource
    case excludedWorkingDirectory
    case unrelatedEvent
}

public enum RequestAdmissionEffect: Sendable, Equatable {
    case enqueue(RequestArrival)
    case buffer(UnboundRequest)
    case nativeOwned(NativePromptObservation)
    case sendProviderResponse(ProviderResponsePlan)
    case quarantine(QuarantineReason)
    case ignore(AdmissionIgnoreReason)
}

public struct RequestAdmission: Sendable, Equatable {
    public let branch: HookAdmissionBranch
    public let effect: RequestAdmissionEffect

    public init(branch: HookAdmissionBranch, effect: RequestAdmissionEffect) {
        self.branch = branch; self.effect = effect
    }
}

public protocol RequestAdmissionPolicy {
    func decide(_ event: NormalizedHookEvent, context: RequestAdmissionContext) -> RequestAdmission
}

public struct LegacyInteractionProjection: Sendable, Equatable {
    public let permissionQueue: [LegacyRequestView]
    public let questionQueue: [LegacyRequestView]

    public init(permissionQueue: [LegacyRequestView] = [], questionQueue: [LegacyRequestView] = []) {
        self.permissionQueue = permissionQueue; self.questionQueue = questionQueue
    }

    /// Independent migration adapter: legacy consumers derive a read-only view
    /// from the public snapshot and never reach into the Store.
    public init(snapshot: InteractionSnapshot) {
        let views = snapshot.local.requests.values.sorted {
            if $0.session != $1.session { return $0.session.key.provider.rawValue < $1.session.key.provider.rawValue }
            return $0.queuePosition < $1.queuePosition
        }.map { LegacyRequestView(id: $0.id, kind: $0.kind, isPending: true) }
        self.init(permissionQueue: views.filter { $0.kind == .permission },
                  questionQueue: views.filter { $0.kind == .question })
    }

    public init(_ snapshot: InteractionSnapshot) {
        self.init(snapshot: snapshot)
    }
}

public struct LegacyCommandAdapter: Sendable {
    public init() {}
    public func approve(_ requestID: RequestID) -> InteractionInput { .user(.resolve(requestID, .allowOnce)) }
    public func deny(_ requestID: RequestID, message: String? = nil) -> InteractionInput { .user(.resolve(requestID, .deny(message: message))) }
    public func answer(_ requestID: RequestID, _ answer: QuestionAnswer) -> InteractionInput { .user(.resolve(requestID, .answer([answer]))) }
    public func dismiss(_ requestID: RequestID) -> InteractionInput { .user(.dismiss(requestID)) }
}
