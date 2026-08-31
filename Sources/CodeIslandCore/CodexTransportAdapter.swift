import Foundation

// MARK: - Codex question transport identity

/// Generation of the app-server client process/connection.  This is deliberately
/// separate from SessionRef.generation: replacing a client must invalidate its
/// old request replies without reopening or mutating a CLI session.
public struct CodexClientGeneration: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct CodexQuestionTransportIdentity: Hashable, Codable, Sendable {
    public let requestID: String
    public let clientGeneration: CodexClientGeneration

    public init(requestID: String, clientGeneration: CodexClientGeneration) {
        self.requestID = requestID
        self.clientGeneration = clientGeneration
    }
}

public extension CodexRequestID {
    /// Stable, type-preserving identity suitable for RequestCorrelation.  The
    /// prefix prevents JSON-RPC id `1` from colliding with string id `"1"`.
    var transportIdentity: String {
        switch self {
        case let .int(value): return "int:\(value)"
        case let .string(value): return "string:\(value)"
        }
    }
}

extension CodexRequestID: @unchecked Sendable {}

// MARK: - Typed Codex response boundary

/// JSON encoding belongs to the Codex adapter.  The Center only sees a typed
/// ResolutionCommand and an opaque TransportToken.
public protocol CodexResponseSink: Sendable {
    func sendResponse(id: CodexRequestID, result: [String: Any]) -> Bool
}

public final class ClosureCodexResponseSink: CodexResponseSink, @unchecked Sendable {
    private let body: (CodexRequestID, [String: Any]) -> Bool

    public init(_ body: @escaping (CodexRequestID, [String: Any]) -> Bool) {
        self.body = body
    }

    public func sendResponse(id: CodexRequestID, result: [String: Any]) -> Bool {
        body(id, result)
    }
}

/// Bridges the existing app-server client without putting that client in the
/// Center.  The adapter owns this sink and can be replaced in tests.
public final class CodexAppServerResponseSink: CodexResponseSink, @unchecked Sendable {
    private weak var client: CodexAppServerClient?

    public init(client: CodexAppServerClient) {
        self.client = client
    }

    public func sendResponse(id: CodexRequestID, result: [String: Any]) -> Bool {
        guard let client else { return false }
        do {
            try client.sendResponse(id: id, result: result)
            return true
        } catch {
            return false
        }
    }
}

public enum CodexTransportOperation: Sendable, Equatable {
    case registered(CodexQuestionTransportIdentity)
    case duplicate
    case staleClient
    case invalidRequest
    case unknown
    case delivered
    case notDelivered
}

public struct CodexQuestionArrival: Sendable, Equatable {
    public let arrival: RequestArrival
    public let identity: CodexQuestionTransportIdentity
    public let codexRequestID: CodexRequestID

    public init(arrival: RequestArrival,
                identity: CodexQuestionTransportIdentity,
                codexRequestID: CodexRequestID) {
        self.arrival = arrival
        self.identity = identity
        self.codexRequestID = codexRequestID
    }
}

public enum CodexIngressResult: Sendable, Equatable {
    case question(CodexQuestionArrival)
    case externallyResolved(RequestID)
    case duplicate
    case ignored
    case staleClient
    case invalidRequest
}

// MARK: - Codex app-server adapter

/// Normalizes `item/tool/requestUserInput` and owns the app-server response
/// channel. This is a fork-owned contract seam wired by AppDelegate into the
/// process-wide InteractionCoordinator.
@MainActor
public final class CodexTransportAdapter: @preconcurrency InteractionEffectExecutor {
    private struct Entry {
        let identity: CodexQuestionTransportIdentity
        let codexRequestID: CodexRequestID
        let requestID: RequestID
        let session: SessionRef
        let sink: any CodexResponseSink
        var ended: Bool = false
        var attemptedEffects: Set<EffectID> = []
    }

    public let idFactory: any InteractionIDFactory
    private var currentGeneration: CodexClientGeneration?
    private var nextGeneration: UInt64 = 0
    private var entries: [TransportToken: Entry] = [:]
    private var terminalTokens: Set<TransportToken> = []
    private var terminalEffects: Set<EffectID> = []

    public init(idFactory: any InteractionIDFactory = RandomInteractionIDFactory()) {
        self.idFactory = idFactory
    }

    public var clientGeneration: CodexClientGeneration? { currentGeneration }

    /// Token ownership query used by the app's single effect executor.  It is
    /// deliberately narrower than exposing the response sink or request
    /// registry: callers can route an effect, but cannot mutate transport
    /// state outside `execute`.
    public func canHandle(token: TransportToken) -> Bool {
        guard let entry = entries[token] else { return false }
        return !entry.ended && !terminalTokens.contains(token)
    }

    /// Opens the first app-server client generation.  Repeated calls preserve
    /// the current generation, making setup idempotent.
    @discardableResult
    public func openClient() -> CodexClientGeneration {
        if let currentGeneration { return currentGeneration }
        // A disconnected client must never reuse its generation.  Reusing the
        // old number would let a late request from the previous process pass
        // the adapter's current-generation check.
        nextGeneration = nextGeneration == UInt64.max ? 1 : nextGeneration &+ 1
        let generation = CodexClientGeneration(nextGeneration)
        currentGeneration = generation
        return generation
    }

    /// Ends all request tokens owned by one provider session without producing
    /// a response. The Center receives the identity-bearing session close and
    /// removes its records; this method only prevents a late effect from
    /// reaching the closed app-server request.
    public func end(session: SessionRef) {
        for (token, var entry) in entries where entry.session == session && !entry.ended {
            entry.ended = true
            entries[token] = entry
            terminalTokens.insert(token)
        }
    }

    /// Replaces the client generation. Existing request tokens remain addressable
    /// only for neutral finalization; no old client response may be submitted.
    @discardableResult
    public func replaceClient() -> CodexClientGeneration {
        let generation = CodexClientGeneration(nextGeneration &+ 1)
        nextGeneration = generation.rawValue
        for token in entries.keys where entries[token]?.identity.clientGeneration != generation {
            entries[token]?.ended = true
        }
        currentGeneration = generation
        return generation
    }

    /// Marks one client generation disconnected and returns token-scoped events.
    /// No request from another generation/session is affected.
    public func disconnect(
        generation: CodexClientGeneration,
        evidence: TransportEndEvidence = .peerDisconnected
    ) -> [InteractionAdapterEvent] {
        var events: [InteractionAdapterEvent] = []
        for (token, var entry) in entries where entry.identity.clientGeneration == generation && !entry.ended {
            entry.ended = true
            entries[token] = entry
            events.append(.transportEnded(token: token, evidence: evidence))
        }
        if currentGeneration == generation { currentGeneration = nil }
        return events
    }

    /// Handles a typed serverRequest/resolved notification. Matching includes
    /// request ID and client generation, so two requests in one thread remain
    /// independent and stale replacement notifications are harmless.
    public func externallyResolve(
        requestID: CodexRequestID,
        threadID: String,
        generation: CodexClientGeneration
    ) -> CodexIngressResult {
        guard isCurrent(generation) else { return .staleClient }
        guard let pair = entries.first(where: {
            $0.value.identity.clientGeneration == generation
                && $0.value.codexRequestID == requestID
                && $0.value.session.key.providerSessionID == threadID
                && !$0.value.ended
        }) else { return .ignored }
        entries[pair.key]?.ended = true
        terminalTokens.insert(pair.key)
        return .externallyResolved(pair.value.requestID)
    }

    /// Parses a server-to-client `item/tool/requestUserInput` request. The caller
    /// supplies the already-authorized SessionRef from the shared generation
    /// authority; this adapter never constructs a session generation from a raw
    /// thread ID.
    public func receive(
        _ message: CodexJSONRPCMessage,
        session: SessionRef,
        generation: CodexClientGeneration,
        sink: any CodexResponseSink,
        receivedAt: Date = Date()
    ) -> CodexIngressResult {
        guard isCurrentOrAdopt(generation) else { return .staleClient }
        guard case let .request(method, codexID) = message.kind,
              method == "item/tool/requestUserInput",
              let params = message.raw["params"]?.asObject,
              let threadID = params["threadId"]?.asString,
              threadID == session.key.providerSessionID,
              case let .array(rawQuestions)? = params["questions"] else {
            return .invalidRequest
        }

        let items = makeQuestionItems(rawQuestions)
        guard !items.isEmpty else { return .invalidRequest }

        let requestID = RequestID(
            session: session,
            upstreamID: codexID.transportIdentity,
            kind: .question,
            discriminator: threadID
        )
        let token = idFactory.makeTransportToken(for: session)
        let identity = CodexQuestionTransportIdentity(
            requestID: codexID.transportIdentity,
            clientGeneration: generation
        )
        let content = QuestionContent(
            items: items,
            answerSchema: AnswerSchema(keysInProviderOrder: items.map(\.key), allowsCustomText: true)
        )
        let capabilities = ResolutionCapabilities(
            // Empty answers are a documented Codex requestUserInput result and
            // are named as an adapter capability, never exposed as "Skip".
            questionActions: [.abandon]
        )
        let arrival = RequestArrival(
            id: requestID,
            session: session,
            kind: .question,
            behavior: .blocking(capabilities),
            content: .question(content),
            channel: .response(token),
            receivedAt: receivedAt
        )
        // A retransmitted JSON-RPC request keeps the same upstream id and
        // generation but receives a fresh local token from the ID factory.
        // Deduplicate on the provider identity before allocating ownership;
        // token uniqueness alone would allow the same server request to be
        // presented twice in Center.
        guard !entries.values.contains(where: {
            !$0.ended
                && $0.identity == identity
                && $0.session == session
        }) else { return .duplicate }
        guard entries[token] == nil else { return .duplicate }
        entries[token] = Entry(
            identity: identity,
            codexRequestID: codexID,
            requestID: requestID,
            session: session,
            sink: sink
        )
        return .question(CodexQuestionArrival(arrival: arrival, identity: identity, codexRequestID: codexID))
    }

    /// Convenience overload for callers that already extracted the request ID
    /// and params. It keeps parsing and normalization in this adapter.
    public func receiveRequest(
        message: CodexJSONRPCMessage,
        session: SessionRef,
        clientGeneration: CodexClientGeneration,
        sink: any CodexResponseSink,
        receivedAt: Date = Date()
    ) -> CodexIngressResult {
        receive(message, session: session, generation: clientGeneration, sink: sink, receivedAt: receivedAt)
    }

    public func execute(
        _ effects: [InteractionEffect],
        report: @escaping (InteractionAdapterEvent) -> Void
    ) {
        for effect in effects {
            switch effect {
            case let .deliverResolution(resolution):
                executeResolution(resolution, report: report)
            case let .finalizeTransport(finalization):
                executeFinalization(finalization)
            default:
                break
            }
        }
    }

    private func executeResolution(
        _ effect: ResolutionEffect,
        report: @escaping (InteractionAdapterEvent) -> Void
    ) {
        guard var entry = entries[effect.token],
              entry.requestID == effect.requestID,
              !entry.ended,
              !terminalTokens.contains(effect.token),
              isCurrent(entry.identity.clientGeneration) else { return }
        guard entry.attemptedEffects.insert(effect.effectID).inserted,
              terminalEffects.insert(effect.effectID).inserted else { return }

        guard let result = responseResult(for: effect.command, request: effect.requestID),
              entry.sink.sendResponse(id: entry.codexRequestID, result: result) else {
            // A failed local submission is not a response and leaves the request
            // retryable with a new EffectID. It never submits an empty answer by
            // accident.
            entries[effect.token] = entry
            report(.resolutionFailed(effect.effectID, request: effect.requestID, token: effect.token,
                                     failure: .notDelivered("Codex response was not delivered")))
            return
        }
        entry.ended = true
        entries[effect.token] = entry
        terminalTokens.insert(effect.token)
        report(.resolutionSucceeded(effect.effectID, request: effect.requestID, token: effect.token))
    }

    private func executeFinalization(_ effect: FinalizeTransportEffect) {
        guard case .providerSafeNeutral = effect.finalization,
              var entry = entries[effect.token],
              entry.requestID == effect.requestID,
              !terminalTokens.contains(effect.token),
              entry.sink.sendResponse(id: entry.codexRequestID, result: Self.emptyAnswersResult) else { return }
        entry.ended = true
        entries[effect.token] = entry
        terminalTokens.insert(effect.token)
        terminalEffects.insert(effect.effectID)
    }

    private func isCurrent(_ generation: CodexClientGeneration) -> Bool {
        currentGeneration == generation
    }

    private func isCurrentOrAdopt(_ generation: CodexClientGeneration) -> Bool {
        if let currentGeneration { return currentGeneration == generation }
        // The caller's client-generation evidence is authoritative for the first
        // receive. Subsequent replacement must go through replaceClient().
        currentGeneration = generation
        nextGeneration = max(nextGeneration, generation.rawValue)
        return true
    }

    private static let emptyAnswersResult: [String: Any] = ["answers": [String: Any]()]

    private func responseResult(
        for command: ResolutionCommand,
        request: RequestID
    ) -> [String: Any]? {
        guard request.correlationKind == .question else { return nil }
        switch command {
        case let .answer(answers):
            var byKey: [String: Any] = [:]
            for answer in answers {
                byKey[answer.questionKey] = ["answers": answer.values.compactMap { value in
                    switch value {
                    case let .option(option): return option
                    case let .custom(text): return text.value
                    }
                }]
            }
            return ["answers": byKey]
        case .questionAction(.abandon, _), .questionAction(.continueWithoutAnswer, _), .questionAction(.reject, _):
            return Self.emptyAnswersResult
        default:
            return nil
        }
    }

    private func makeQuestionItems(_ rawQuestions: [AnyCodableLike]) -> [QuestionItem] {
        var usedKeys: Set<String> = []
        return rawQuestions.compactMap { raw in
            guard let question = raw.asObject else { return nil }
            let text = question["question"]?.asString?.isEmpty == false
                ? question["question"]!.asString!
                : "Question"
            let sensitivity: Sensitivity = question["isSecret"]?.asBool == true ? .secret : .public
            let baseKey = question["id"]?.asString.flatMap { $0.isEmpty ? nil : $0 } ?? text
            var key = baseKey
            var suffix = 2
            while usedKeys.contains(key) {
                key = "\(baseKey)_\(suffix)"
                suffix += 1
            }
            usedKeys.insert(key)

            let options: [QuestionOption]
            if case let .array(rawOptions)? = question["options"] {
                options = rawOptions.enumerated().compactMap { index, rawOption in
                    guard let option = rawOption.asObject,
                          let label = option["label"]?.asString,
                          !label.isEmpty else { return nil }
                    return QuestionOption(
                        key: "option_\(index + 1)",
                        label: SensitiveText(label, sensitivity: sensitivity)
                    )
                }
            } else {
                options = []
            }
            return QuestionItem(
                key: key,
                prompt: SensitiveText(text, sensitivity: sensitivity),
                options: options,
                allowsMultiple: question["multiSelect"]?.asBool ?? false
            )
        }
    }
}

private extension RequestID {
    var correlationKind: InteractionRequestKind? {
        guard case let .stable(key) = correlation else { return nil }
        return key.kind
    }
}
