import Foundation
import Observation

// MARK: - Hook request normalization

/// The provider-facing part of hook ingress.  The hook server remains the owner
/// of byte probing, source/cwd filtering and sub-session routing.  This module
/// only consumes the resulting HookEvent and produces values that are safe to
/// pass through the InteractionCenter seam.
public struct HookAdmissionConfiguration: Sendable, Equatable {
    public let defaultProvider: ProviderID
    public let supportedSources: Set<String>
    public let autoApproveTools: Set<String>
    public let autoApprovedSources: Set<String>
    public let providerOwnedReviewTools: Set<String>
    /// A provider may opt out when it cannot prove a safe neutral response.
    /// Hook `{}` is the default contract for the legacy hook bridge.
    public let safeNeutralResponse: ProviderNeutralResponse?

    public init(
        defaultProvider: ProviderID = ProviderID("claude"),
        supportedSources: Set<String> = [],
        autoApproveTools: Set<String> = [],
        autoApprovedSources: Set<String> = [],
        providerOwnedReviewTools: Set<String> = [],
        safeNeutralResponse: ProviderNeutralResponse? = .hookEmptyObject
    ) {
        self.defaultProvider = defaultProvider
        self.supportedSources = Set(supportedSources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        self.autoApproveTools = autoApproveTools
        self.autoApprovedSources = Set(autoApprovedSources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        self.providerOwnedReviewTools = providerOwnedReviewTools
        self.safeNeutralResponse = safeNeutralResponse
    }
}

/// A normalized request keeps identity and provider handles together until the
/// generation authority can bind them.  No raw HookEvent or JSON crosses this
/// value boundary.
public struct NormalizedHookRequest: Sendable, Equatable {
    public let event: NormalizedHookEvent
    public let correlation: RequestCorrelation
    public let responseHandle: ProviderResponseHandle?

    public init(event: NormalizedHookEvent, correlation: RequestCorrelation, responseHandle: ProviderResponseHandle? = nil) {
        self.event = event
        self.correlation = correlation
        self.responseHandle = responseHandle
    }
}

public struct HookRequestNormalizer: Sendable {
    public let configuration: HookAdmissionConfiguration
    private let idFactory: any InteractionIDFactory

    public init(
        configuration: HookAdmissionConfiguration = HookAdmissionConfiguration(),
        idFactory: any InteractionIDFactory = RandomInteractionIDFactory()
    ) {
        self.configuration = configuration
        self.idFactory = idFactory
    }

    /// Normalize one already-parsed HookEvent.  Source aliases are normalized
    /// using the existing SessionSnapshot implementation; event aliases use the
    /// existing EventNormalizer implementation.  Neither implementation is
    /// reimplemented here.
    public func normalize(
        _ event: HookEvent,
        responseHandle: ProviderResponseHandle? = nil,
        receivedAt: Date = Date()
    ) -> NormalizedHookRequest {
        let source = (event.rawJSON["_source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSource = source.flatMap(SessionSnapshot.normalizedSupportedSource)
        let provider = ProviderID(normalizedSource ?? source ?? configuration.defaultProvider.rawValue)
        let sessionKey = SessionKey(provider: provider, providerSessionID: event.sessionId ?? "default")
        let branch = branch(for: event, normalizedSource: normalizedSource)
        let content = content(for: event, branch: branch)
        let normalized = NormalizedHookEvent(
            provider: provider,
            sessionKey: sessionKey,
            branch: branch,
            content: content,
            receivedAt: receivedAt
        )
        let correlation: RequestCorrelation
        if let toolUseID = normalizedString(event.toolUseId) {
            let kind: InteractionRequestKind = branch == .askUserQuestion || branch == .notificationQuestion
                ? .question
                : .permission
            let discriminator = discriminator(for: event, branch: branch)
            correlation = .stable(StableRequestKey(upstreamID: toolUseID, kind: kind, discriminator: discriminator))
        } else {
            // An occurrence is deliberately created for every no-ID arrival;
            // content fingerprints are not identity evidence.
            correlation = .occurrence(idFactory.makeOccurrenceID())
        }
        return NormalizedHookRequest(event: normalized, correlation: correlation, responseHandle: responseHandle)
    }

    private func branch(for event: HookEvent, normalizedSource: String?) -> HookAdmissionBranch {
        if let source = normalizedSource,
           !configuration.supportedSources.isEmpty,
           !configuration.supportedSources.contains(source) {
            return .unsupported
        }
        if let rawSource = event.rawJSON["_source"] as? String,
           !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           normalizedSource == nil {
            return .unsupported
        }

        let normalizedEvent = EventNormalizer.normalize(event.eventName)
        let isGeminiSource = normalizedSource == "google-antigravity" || normalizedSource == "gemini"
        let isPermission = normalizedEvent == "PermissionRequest"
            || (isGeminiSource && normalizedEvent == "PreToolUse")
        let tool = normalizedString(event.toolName)

        // AskUserQuestion must remain interactive even if a broad tool/source
        // allow-list accidentally contains its name.
        if isPermission, tool == "AskUserQuestion" {
            return .askUserQuestion
        }
        if let tool, configuration.autoApproveTools.contains(tool) {
            return .safeBuiltInTool
        }
        if let source = normalizedSource,
           configuration.autoApprovedSources.contains(source),
           tool != "AskUserQuestion" {
            return .alwaysProceedSource
        }
        if let tool, configuration.providerOwnedReviewTools.contains(tool), isPermission {
            return .providerOwnedReview
        }
        if isPermission {
            return tool == "ExitPlanMode" ? .exitPlanMode : .regularPermission
        }
        if normalizedSource.map(CursorSubsessionRouter.isCursorFamilySource) == true,
           (event.rawJSON["cursorPendingQuestion"] as? Bool == true
            || event.rawJSON["is_native_prompt"] as? Bool == true) {
            return .cursorNativePrompt
        }
        if normalizedEvent == "Notification", QuestionPayload.from(event: event) != nil {
            return .notificationQuestion
        }
        if normalizedEvent.isEmpty {
            return .malformed
        }
        return .ordinaryEvent
    }

    private func content(for event: HookEvent, branch: HookAdmissionBranch) -> RequestContent? {
        switch branch {
        case .regularPermission:
            return .permission(PermissionContent(
                toolName: normalizedString(event.toolName),
                summary: event.toolDescription,
                displayInput: event.toolInput.map { Self.displayValue($0) },
                variant: .regular
            ))
        case .exitPlanMode:
            let input = event.toolInput ?? [:]
            let plan = normalizedString(input["plan"])
                ?? normalizedString(input["content"])
                ?? normalizedString(input["text"])
            let count = (input["allowedPrompts"] as? Int)
                ?? (input["allowed_prompts"] as? Int)
                ?? 0
            return .permission(PermissionContent(
                toolName: normalizedString(event.toolName),
                summary: event.toolDescription,
                displayInput: event.toolInput.map { Self.displayValue($0) },
                variant: .plan(PlanContent(planText: plan.map { SensitiveText($0) }, allowedPromptCount: count))
            ))
        case .askUserQuestion:
            return Self.askQuestionContent(for: event)
        case .notificationQuestion:
            guard let question = QuestionPayload.from(event: event) else { return nil }
            let sensitivity: Sensitivity = question.isSecret ? .secret : .public
            let item = QuestionItem(
                key: normalizedString(question.header) ?? "answer",
                prompt: SensitiveText(question.question, sensitivity: sensitivity),
                options: (question.options ?? []).enumerated().map { index, value in
                    QuestionOption(key: "option_\(index + 1)", label: SensitiveText(value, sensitivity: sensitivity))
                }
            )
            return .question(QuestionContent(items: [item], answerSchema: AnswerSchema(keysInProviderOrder: [item.key])))
        default:
            return nil
        }
    }

    private func discriminator(for event: HookEvent, branch: HookAdmissionBranch) -> String? {
        guard branch == .regularPermission || branch == .exitPlanMode || branch == .askUserQuestion else { return nil }
        let tool = normalizedString(event.toolName) ?? ""
        let input = event.toolInput.map { Self.displayValue($0) }
        return "\(tool):\(String(describing: input))"
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedString(_ value: Any?) -> String? {
        normalizedString(value as? String)
    }

    private static func askQuestionContent(for event: HookEvent) -> RequestContent? {
        let input = event.toolInput ?? [:]
        let sensitivity: Sensitivity = (input["isSecret"] as? Bool == true) ? .secret : .public
        let rawQuestions = input["questions"] as? [[String: Any]]
        var items: [QuestionItem] = []
        var usedKeys = Set<String>()
        if let rawQuestions {
            for (index, question) in rawQuestions.enumerated() {
                guard let text = question["question"] as? String, !text.isEmpty else { continue }
                let baseKey = text
                var key = baseKey
                var suffix = 2
                while usedKeys.contains(key) {
                    key = "\(baseKey)_\(suffix)"
                    suffix += 1
                }
                usedKeys.insert(key)
                let options = (question["options"] as? [[String: Any]] ?? []).enumerated().compactMap { optionIndex, option -> QuestionOption? in
                    guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                    return QuestionOption(key: "option_\(index + 1)_\(optionIndex + 1)", label: SensitiveText(label, sensitivity: sensitivity))
                }
                items.append(QuestionItem(
                    key: key,
                    prompt: SensitiveText(text, sensitivity: sensitivity),
                    options: options,
                    allowsMultiple: question["multiSelect"] as? Bool ?? false
                ))
            }
        }
        if items.isEmpty,
           let text = input["question"] as? String,
           !text.isEmpty {
            let options = (input["options"] as? [String] ?? []).enumerated().map { index, value in
                QuestionOption(key: "option_\(index + 1)", label: SensitiveText(value, sensitivity: sensitivity))
            }
            items = [QuestionItem(key: "answer", prompt: SensitiveText(text, sensitivity: sensitivity), options: options)]
        }
        guard !items.isEmpty else { return nil }
        return .question(QuestionContent(items: items, answerSchema: AnswerSchema(keysInProviderOrder: items.map(\.key))))
    }

    /// Converts only JSON scalar/container values to the closed DisplayValue
    /// tree.  Unsupported values are omitted by the caller before they reach
    /// Center; closures, connections and raw HookEvent objects never do.
    private static func displayValue(_ value: Any, depth: Int = 0) -> DisplayValue {
        guard depth < 6 else { return .redacted(.privateData) }
        if let value = value as? String { return .text(String(value.prefix(8_192))) }
        if let value = value as? Bool { return .boolean(value) }
        if let value = value as? NSNumber { return .number(value.doubleValue) }
        if let value = value as? [Any] { return .list(value.map { displayValue($0, depth: depth + 1) }) }
        if let value = value as? [String: Any] {
            return .object(value.reduce(into: [:]) { result, pair in
                result[pair.key] = displayValue(pair.value, depth: depth + 1)
            })
        }
        return .redacted(.privateData)
    }
}

// MARK: - Transport registry

public enum HookWireResponse: Sendable, Equatable {
    case resolution(ResolutionCommand)
    case provider(ProviderResponsePlan)
    case neutral(ProviderNeutralResponse)
}

/// Result of a local transport operation.  `delivered` means only that this
/// process accepted the first submission; it makes no wire exactly-once claim.
public enum HookTransportOperation: Sendable, Equatable {
    case delivered(HookWireResponse)
    case finalized(ProviderNeutralResponse)
    case quarantined(TransportQuarantine)
    case duplicate
    case unknown
    case failed(String)
}

/// The narrow production seam for a Unix hook connection.  A sink owns byte
/// encoding and socket lifetime; this adapter only dispatches typed responses.
public protocol HookWireResponseSink: Sendable {
    func send(_ response: HookWireResponse) -> Bool
}

public final class ClosureHookWireResponseSink: HookWireResponseSink, @unchecked Sendable {
    private let body: (HookWireResponse) -> Bool

    public init(_ body: @escaping (HookWireResponse) -> Bool) {
        self.body = body
    }

    public func send(_ response: HookWireResponse) -> Bool { body(response) }
}

/// Adapter-owned atomic responder.  It makes the once-finalization contract
/// explicit while leaving protocol bytes and NWConnection details to the sink.
public final class HookOnceResponder: OnceResponder<HookWireResponse>, @unchecked Sendable {
    private let sink: any HookWireResponseSink
    private let lock = NSLock()
    private var finished = false

    public init(sink: any HookWireResponseSink) {
        self.sink = sink
    }

    public func finish(_ response: HookWireResponse) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        lock.unlock()
        // The first invocation is the only local submission attempt.  A socket
        // without provider idempotency cannot honestly be called wire exactly-once.
        return sink.send(response)
    }
}

public enum HookTransportRegistrationResult: Sendable, Equatable {
    case registered
    case duplicate
    case unknown
    case invalidIdentity
    case quarantined(TransportQuarantine)
}

/// An adapter-owned registry.  Center sees only the opaque token.  The
/// continuation/connection callback remains here and is finished at most once.
public final class HookTransportRegistry: @unchecked Sendable {
    private struct Entry {
        let request: RequestID?
        let token: TransportToken
        let neutral: ProviderNeutralResponse?
        let responder: any OnceResponder<HookWireResponse>
        let createdAt: Date
    }

    private struct PendingEntry {
        let handle: ProviderResponseHandle
        let request: RequestID?
        let neutral: ProviderNeutralResponse?
        let responder: any OnceResponder<HookWireResponse>
        let createdAt: Date
    }

    private let policy: TerminalLedgerPolicy
    private let clock: any InteractionClock
    private var entries: [TransportToken: Entry] = [:]
    private var pending: [ProviderResponseHandle: PendingEntry] = [:]
    private var terminal: [TransportToken: Date] = [:]
    private let lock = NSLock()

    public init(policy: TerminalLedgerPolicy = TerminalLedgerPolicy(), clock: any InteractionClock = SystemInteractionClock()) {
        self.policy = policy
        self.clock = clock
    }

    @discardableResult
    public func register(
        token: TransportToken,
        request: RequestID? = nil,
        neutralResponse: ProviderNeutralResponse?,
        responder: any OnceResponder<HookWireResponse>
    ) -> HookTransportRegistrationResult {
        guard request?.session == nil || request?.session == token.session else { return .invalidIdentity }
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: clock.now)
        guard entries[token] == nil, terminal[token] == nil else { return .duplicate }
        entries[token] = Entry(request: request, token: token, neutral: neutralResponse, responder: responder, createdAt: clock.now)
        return .registered
    }

    @discardableResult
    public func registerPending(
        handle: ProviderResponseHandle,
        request: RequestID? = nil,
        neutralResponse: ProviderNeutralResponse?,
        responder: any OnceResponder<HookWireResponse>
    ) -> HookTransportRegistrationResult {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: clock.now)
        guard pending[handle] == nil else { return .duplicate }
        pending[handle] = PendingEntry(handle: handle, request: request, neutral: neutralResponse, responder: responder, createdAt: clock.now)
        return .registered
    }

    /// Binds a response handle only after the shared generation authority has
    /// supplied a complete SessionRef.
    @discardableResult
    public func bind(_ handle: ProviderResponseHandle, to token: TransportToken) -> HookTransportRegistrationResult {
        lock.lock(); defer { lock.unlock() }
        guard let item = pending.removeValue(forKey: handle) else { return .unknown }
        guard item.request?.session == nil || item.request?.session == token.session else { return .invalidIdentity }
        if let request = item.request, request.session != token.session { return .invalidIdentity }
        guard entries[token] == nil, terminal[token] == nil else { return .duplicate }
        entries[token] = Entry(request: item.request, token: token, neutral: item.neutral, responder: item.responder, createdAt: item.createdAt)
        return .registered
    }

    public func removePending(_ handle: ProviderResponseHandle) {
        lock.lock(); pending.removeValue(forKey: handle); lock.unlock()
    }

    public func respond(token: TransportToken, command: ResolutionCommand) -> HookTransportOperation {
        lock.lock()
        guard let entry = entries.removeValue(forKey: token) else {
            let wasTerminal = terminal[token] != nil
            lock.unlock()
            return wasTerminal ? .duplicate : .unknown
        }
        terminal[token] = clock.now
        pruneLocked(now: clock.now)
        lock.unlock()
        guard entry.responder.finish(.resolution(command)) else { return .duplicate }
        return .delivered(.resolution(command))
    }

    public func finalize(token: TransportToken, reason: TransportEndReason) -> TransportFinalizationResult {
        lock.lock()
        guard let entry = entries.removeValue(forKey: token) else {
            let wasTerminal = terminal[token] != nil
            lock.unlock()
            return wasTerminal ? .failed(.unavailable("transport token already finalized")) : .failed(.unavailable("unknown transport token"))
        }
        terminal[token] = clock.now
        pruneLocked(now: clock.now)
        lock.unlock()

        guard let neutral = entry.neutral else {
            return .quarantined(.noSafeNeutralResponse(token))
        }
        guard entry.responder.finish(.neutral(neutral)) else {
            return .failed(.unavailable("responder already finalized"))
        }
        _ = reason // The reason is carried by Center's effect and remains typed.
        return .finalized(NeutralFinalizationReceipt(token: token, response: neutral))
    }

    public func isRegistered(_ token: TransportToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[token] != nil
    }

    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        pruneLocked(now: clock.now)
        return entries.count + pending.count
    }

    public func prune(now: Date) {
        lock.lock(); pruneLocked(now: now); lock.unlock()
    }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.retention.timeInterval)
        terminal = terminal.filter { $0.value > cutoff }
        entries = entries.filter { $0.value.createdAt > cutoff }
        pending = pending.filter { $0.value.createdAt > cutoff }
        if terminal.count > policy.maxEntries {
            let oldest = terminal.sorted { $0.value < $1.value }.prefix(terminal.count - policy.maxEntries).map(\.key)
            oldest.forEach { terminal.removeValue(forKey: $0) }
        }
    }
}

/// Production transport adapter for hook resolution/finalization effects.  It
/// is intentionally independent of Network.framework: HookServer supplies a
/// sink for each connection, while contract tests supply a recording sink.
public final class HookTransportAdapter: InteractionEffectExecutor, @unchecked Sendable {
    public let registry: HookTransportRegistry

    public init(registry: HookTransportRegistry = HookTransportRegistry()) {
        self.registry = registry
    }

    /// Lets the single production executor route an effect to the adapter
    /// that owns its opaque token without probing provider strings or trying
    /// an effect against every transport.
    public func canHandle(token: TransportToken) -> Bool {
        registry.isRegistered(token)
    }

    @discardableResult
    public func register(
        token: TransportToken,
        request: RequestID? = nil,
        neutralResponse: ProviderNeutralResponse?,
        sink: any HookWireResponseSink
    ) -> HookTransportRegistrationResult {
        registry.register(token: token, request: request, neutralResponse: neutralResponse, responder: HookOnceResponder(sink: sink))
    }

    @discardableResult
    public func registerPending(
        handle: ProviderResponseHandle,
        request: RequestID? = nil,
        neutralResponse: ProviderNeutralResponse?,
        sink: any HookWireResponseSink
    ) -> HookTransportRegistrationResult {
        registry.registerPending(handle: handle, request: request, neutralResponse: neutralResponse, responder: HookOnceResponder(sink: sink))
    }

    /// Writes an immediate typed hook acknowledgement without creating a
    /// Center request or a transport token.
    @discardableResult
    public func sendImmediate(_ response: HookWireResponse, sink: any HookWireResponseSink) -> Bool {
        HookOnceResponder(sink: sink).finish(response)
    }

    public func execute(_ effects: [InteractionEffect], report: @escaping (InteractionAdapterEvent) -> Void) {
        for effect in effects {
            switch effect {
            case let .deliverResolution(resolution):
                if case .delivered = registry.respond(token: resolution.token, command: resolution.command) {
                    report(.resolutionSucceeded(resolution.effectID, request: resolution.requestID, token: resolution.token))
                }
            case let .finalizeTransport(finalization):
                _ = registry.finalize(token: finalization.token, reason: reason(from: finalization.finalization))
            case .changeAutoMode, .cancelTransport, .navigate, .feedback, .diagnostic:
                // Other effects belong to their own adapters; they are still
                // returned to the coordinator in the original array order.
                break
            }
        }
    }

    private func reason(from finalization: TransportFinalization) -> TransportEndReason {
        switch finalization {
        case let .providerSafeNeutral(reason): return reason
        case .externallyResolved: return .replacement
        }
    }
}

// MARK: - Adapter and single executor

public enum HookIngressResult: Sendable, Equatable {
    case request(RequestArrival)
    case buffered(BufferToken)
    case providerResponse(ProviderResponsePlan)
    case nativePrompt(NativePromptObservation)
    case quarantine(QuarantineReason)
    case ignored(AdmissionIgnoreReason)
    case diagnostic(DiagnosticCode)
}

public struct HookSessionBinding: Sendable, Equatable {
    public let session: SessionRef
    public let arrivals: [RequestArrival]

    public init(session: SessionRef, arrivals: [RequestArrival] = []) {
        self.session = session
        self.arrivals = arrivals
    }
}

@MainActor
public final class HookInteractionAdapter {
    public let generationAuthority: any SessionGenerationAuthority
    public let ingressBuffer: any RequestIngressBuffer
    public let transportRegistry: HookTransportRegistry

    private let idFactory: any InteractionIDFactory
    private let normalizer: HookRequestNormalizer
    private let configuration: HookAdmissionConfiguration

    public init(
        generationAuthority: any SessionGenerationAuthority,
        ingressBuffer: any RequestIngressBuffer = InMemoryRequestIngressBuffer(),
        transportRegistry: HookTransportRegistry = HookTransportRegistry(),
        idFactory: any InteractionIDFactory = RandomInteractionIDFactory(),
        configuration: HookAdmissionConfiguration = HookAdmissionConfiguration()
    ) {
        self.generationAuthority = generationAuthority
        self.ingressBuffer = ingressBuffer
        self.transportRegistry = transportRegistry
        self.idFactory = idFactory
        self.configuration = configuration
        self.normalizer = HookRequestNormalizer(configuration: configuration, idFactory: idFactory)
    }

    /// Ingests a parsed hook and returns exactly one typed outcome.  The caller
    /// sends `.request`/`.nativePrompt` to Center and writes immediate provider
    /// responses through its registered responder.
    public func receive(
        _ event: HookEvent,
        responseHandle: ProviderResponseHandle? = nil,
        responder: (any OnceResponder<HookWireResponse>)? = nil,
        receivedAt: Date = Date()
    ) -> HookIngressResult {
        let normalized = normalizer.normalize(event, responseHandle: responseHandle, receivedAt: receivedAt)
        switch normalized.event.branch {
        case .safeBuiltInTool:
            return .providerResponse(.safeToolAllow)
        case .alwaysProceedSource:
            return .providerResponse(.alwaysProceedAllow)
        case .providerOwnedReview:
            return .providerResponse(.providerOwnedAck)
        case .ordinaryEvent:
            return .providerResponse(.ordinaryAck)
        case .malformed:
            return .diagnostic(.invalidIdentity)
        case .unsupported:
            return .ignored(.unsupportedSource)
        case .cursorNativePrompt:
            guard let current = generationAuthority.current(for: normalized.event.sessionKey) else {
                return .quarantine(.missingGeneration)
            }
            return .nativePrompt(NativePromptObservation(session: current, isPending: true, title: event.toolDescription, revision: 1))
        case .notificationQuestion:
            // Notification questions are display-only in Phase 2.  They do not
            // claim a resolution channel; the existing hook caller can ack via
            // its immediate response path.
            return requestOrDisplayOnly(normalized: normalized, responder: responder)
        case .regularPermission, .exitPlanMode, .askUserQuestion:
            return enqueue(normalized: normalized, responder: responder)
        }
    }

    /// Applies a generation fact and binds buffered requests in their original
    /// arrival order.  A provider observation cannot create the first generation.
    public func apply(_ fact: SessionIdentityFact) -> HookSessionBinding? {
        let previous = generationAuthority.current(for: fact.key)
        let ref = generationAuthority.apply(fact)
        let isClose: Bool
        if case .closed = fact.lifecycle { isClose = true } else { isClose = false }
        guard ref.generation > 0,
              (isClose ? previous != nil : generationAuthority.isCurrent(ref)),
              (previous == nil ? fact.lifecycle == .opened : true) else {
            return nil
        }
        if isClose {
            for handle in pendingHandles(for: fact.key) { transportRegistry.removePending(handle) }
            _ = ingressBuffer.remove(fact.key)
            return HookSessionBinding(session: ref)
        }
        let factory = BindingTokenFactory(idFactory: idFactory, registry: transportRegistry)
        let arrivals = ingressBuffer.bind(ref, tokenFactory: factory)
        return HookSessionBinding(session: ref, arrivals: arrivals)
    }

    public func expire(now: Date) -> [BufferToken] {
        ingressBuffer.expire(now: now)
    }

    private func enqueue(normalized: NormalizedHookRequest, responder: (any OnceResponder<HookWireResponse>)?) -> HookIngressResult {
        guard let content = normalized.event.content else { return .diagnostic(.invalidIdentity) }
        guard let responseHandle = normalized.responseHandle, let responder else {
            // A blocking request without a callback is unsafe.  Do not invent a
            // deny/empty answer to fill the missing transport channel.
            return .quarantine(.unsupportedChannel)
        }
        let capabilities = ResolutionCapabilities(
            allowAlways: normalized.event.branch != .askUserQuestion,
            planModes: normalized.event.branch == .exitPlanMode ? [.manual] : [],
            // AskUserQuestion has a stable Hook deny response. Notification is
            // display-only and intentionally never receives a synthetic action.
            questionActions: normalized.event.branch == .askUserQuestion ? [.reject] : []
        )
        let behavior = UnboundRequestBehavior.blocking(capabilities)
        guard let neutral = configuration.safeNeutralResponse else {
            return .quarantine(.noSafeNeutralResponse)
        }
        let current = generationAuthority.current(for: normalized.event.sessionKey)
        if let current {
            let token = idFactory.bind(responseHandle, to: current)
            let requestID = RequestID(session: current, correlation: normalized.correlation)
            let registration = transportRegistry.register(token: token, request: requestID, neutralResponse: neutral, responder: responder)
            guard registration == .registered else { return mapRegistration(registration) }
            let arrival = RequestArrival(
                id: requestID,
                session: current,
                kind: normalized.event.branch == .askUserQuestion ? .question : .permission,
                behavior: .blocking(capabilities),
                content: content,
                channel: .response(token),
                receivedAt: normalized.event.receivedAt
            )
            return .request(arrival)
        }

        let bufferToken = idFactory.makeBufferToken()
        let registration = transportRegistry.registerPending(handle: responseHandle, neutralResponse: neutral, responder: responder)
        guard registration == .registered else { return mapRegistration(registration) }
        let request = UnboundRequest(
            key: normalized.event.sessionKey,
            bufferToken: bufferToken,
            correlation: normalized.correlation,
            kind: normalized.event.branch == .askUserQuestion ? .question : .permission,
            behavior: behavior,
            content: content,
            channel: .response(responseHandle),
            receivedAt: normalized.event.receivedAt
        )
        switch ingressBuffer.accept(request) {
        case .buffered:
            return .buffered(bufferToken)
        case .admitted:
            // A custom buffer may admit immediately.  The standard buffer only
            // buffers unbound requests, but keeping this branch makes the seam
            // explicit for production replacements.
            return .diagnostic(.invalidIdentity)
        case let .finalizedWithoutResolution(code):
            transportRegistry.removePending(responseHandle)
            return .diagnostic(code)
        }
    }

    private func requestOrDisplayOnly(normalized: NormalizedHookRequest, responder: (any OnceResponder<HookWireResponse>)?) -> HookIngressResult {
        guard let content = normalized.event.content else { return .diagnostic(.invalidIdentity) }
        guard let current = generationAuthority.current(for: normalized.event.sessionKey) else {
            let bufferToken = idFactory.makeBufferToken()
            let request = UnboundRequest(
                key: normalized.event.sessionKey,
                bufferToken: bufferToken,
                correlation: normalized.correlation,
                kind: .question,
                behavior: .displayOnly,
                content: content,
                channel: .none,
                receivedAt: normalized.event.receivedAt
            )
            switch ingressBuffer.accept(request) {
            case .buffered: return .buffered(bufferToken)
            case .admitted: return .diagnostic(.invalidIdentity)
            case let .finalizedWithoutResolution(code): return .diagnostic(code)
            }
        }
        let requestID = RequestID(session: current, correlation: normalized.correlation)
        let arrival = RequestArrival(id: requestID, session: current, kind: .question, behavior: .displayOnly, content: content, channel: .none, receivedAt: normalized.event.receivedAt)
        // The display-only path has no Center resolution channel.  If the hook
        // supplied a callback, acknowledge it immediately without registering a
        // token, preserving the old Notification acknowledgement semantics.
        if let responder { _ = responder.finish(.neutral(.notificationAck)) }
        return .request(arrival)
    }

    private func mapRegistration(_ result: HookTransportRegistrationResult) -> HookIngressResult {
        switch result {
        case .registered: return .diagnostic(.invalidIdentity)
        case .duplicate: return .diagnostic(.terminalLedgerHit)
        case .unknown: return .diagnostic(.invalidChannel)
        case .invalidIdentity: return .diagnostic(.invalidIdentity)
        case .quarantined: return .quarantine(.unsupportedChannel)
        }
    }

    private func pendingHandles(for key: SessionKey) -> [ProviderResponseHandle] {
        // The buffer owns the unbound request list.  Pending callbacks are
        // intentionally opaque, so close removes buffered requests first; stale
        // callback invocations are then harmlessly ignored by the registry.
        _ = key
        return []
    }

    private struct BindingTokenFactory: TransportTokenFactory {
        let idFactory: any InteractionIDFactory
        let registry: HookTransportRegistry

        func bind(_ handle: ProviderResponseHandle, to session: SessionRef) -> TransportToken {
            let token = idFactory.bind(handle, to: session)
            _ = registry.bind(handle, to: token)
            return token
        }
    }
}

// MARK: - Coordinator

/// The only caller allowed to execute returned effects.  Adapter callbacks are
/// fed back as typed Center input on MainActor, so a response cannot bypass the
/// reducer or create a second executor.
@MainActor
@Observable
public final class InteractionCoordinator {
    public let store: InteractionCenterStore
    private let executor: any InteractionEffectExecutor
    private var isDispatching = false
    private var queuedInputs: [InteractionInput] = []

    public init(store: InteractionCenterStore, executor: any InteractionEffectExecutor) {
        self.store = store
        self.executor = executor
        self.snapshot = store.snapshot
    }

    public private(set) var snapshot: InteractionSnapshot

    @discardableResult
    public func send(_ input: InteractionInput) -> [InteractionEffect] {
        if isDispatching {
            queuedInputs.append(input)
            return []
        }
        let effects = store.send(input)
        snapshot = store.snapshot
        dispatch(effects)
        return effects
    }

    private func dispatch(_ effects: [InteractionEffect]) {
        guard !effects.isEmpty else {
            drainQueuedInputs()
            return
        }
        isDispatching = true
        executor.execute(effects) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receiveAck(event)
            }
        }
        isDispatching = false
        drainQueuedInputs()
    }

    private func receiveAck(_ event: InteractionAdapterEvent) {
        let effects = store.send(.adapter(event))
        snapshot = store.snapshot
        dispatch(effects)
    }

    private func drainQueuedInputs() {
        guard !isDispatching, !queuedInputs.isEmpty else { return }
        let input = queuedInputs.removeFirst()
        let effects = store.send(input)
        snapshot = store.snapshot
        dispatch(effects)
    }
}

/// A transport-focused executor suitable for the hook production adapter and
/// for recording contract tests.  Unknown effect kinds are deliberately not
/// executed here; another coordinator-level adapter can handle them while
/// preserving one ordered dispatch call.
public final class HookInteractionEffectExecutor: InteractionEffectExecutor, @unchecked Sendable {
    private let registry: HookTransportRegistry

    public init(registry: HookTransportRegistry) {
        self.registry = registry
    }

    public func execute(_ effects: [InteractionEffect], report: @escaping (InteractionAdapterEvent) -> Void) {
        for effect in effects {
            switch effect {
            case let .deliverResolution(resolution):
                if case .delivered = registry.respond(token: resolution.token, command: resolution.command) {
                    report(.resolutionSucceeded(resolution.effectID, request: resolution.requestID, token: resolution.token))
                }
            case let .finalizeTransport(finalization):
                _ = registry.finalize(token: finalization.token, reason: reason(from: finalization.finalization))
            case .changeAutoMode, .cancelTransport, .navigate, .feedback, .diagnostic:
                break
            }
        }
    }

    private func reason(from finalization: TransportFinalization) -> TransportEndReason {
        switch finalization {
        case let .providerSafeNeutral(reason): return reason
        case .externallyResolved: return .replacement
        }
    }
}
