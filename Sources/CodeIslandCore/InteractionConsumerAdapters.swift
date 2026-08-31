import Foundation

// MARK: - Snapshot readers

/// A consumer is deliberately handed only the audience-specific projection.
/// In particular, an external device must never be able to downcast this to a
/// local snapshot or recover a provider payload from it.
public protocol RedactedInteractionSnapshotReader: AnyObject, Sendable {
    var snapshot: RedactedInteractionSnapshot { get }
}

public protocol LocalInteractionSnapshotReader: AnyObject, Sendable {
    var snapshot: LocalInteractionSnapshot { get }
}

// MARK: - Shortcut adapter

/// The actions exposed by global shortcuts.  This is intentionally a closed
/// set: UI code cannot invent a stringly-typed command or silently add a queue
/// operation.
public enum InteractionShortcut: Sendable, Equatable, Codable {
    case allowOnce
    case allowAlways
    case deny
    case dismiss
    case reveal
    /// Kept only so old key bindings can be safely ignored after cutover; it
    /// must never become a generic question resolution action.
    case skipQuestion
    case answer(String, answerKey: String?)
}

public enum InteractionConsumerDecision: Sendable, Equatable {
    case action(InteractionInput)
    case ignored(InteractionConsumerIgnoreReason)
}

public enum InteractionConsumerIgnoreReason: Sendable, Equatable {
    case noProminentRequest
    case staleRequest
    case wrongKind
    case unavailableAction
    case ambiguousTarget
    case staleSequence
    case unsupportedMajor
    case duplicateCommand
    case legacyCommandRequiresUniqueVisibleTarget
}

/// Resolves a shortcut against the snapshot's highlighted RequestID.  It never
/// asks a queue for its head; no highlighted request means a safe no-op.
public struct InteractionShortcutAdapter: Sendable {
    public init() {}

    public func decision(
        _ shortcut: InteractionShortcut,
        snapshot: LocalInteractionSnapshot
    ) -> InteractionConsumerDecision {
        guard let requestID = snapshot.presentation.prominentRequest,
              let request = snapshot.requests[requestID],
              isPending(request.lifecycle) else {
            return .ignored(.noProminentRequest)
        }

        switch shortcut {
        case .allowOnce:
            guard request.kind == .permission,
                  contains(.allowOnce, in: request.availableActions) else {
                return .ignored(.unavailableAction)
            }
            return .action(.user(.resolve(requestID, .allowOnce)))
        case .allowAlways:
            guard request.kind == .permission,
                  contains(.allowAlways, in: request.availableActions) else {
                return .ignored(.unavailableAction)
            }
            return .action(.user(.resolve(requestID, .allowAlways)))
        case .deny:
            guard contains(.deny, in: request.availableActions) else {
                return .ignored(.unavailableAction)
            }
            return .action(.user(.resolve(requestID, .deny(message: nil))))
        case .dismiss:
            return .action(.user(.dismiss(requestID)))
        case .reveal:
            return .action(.user(.reveal(requestID)))
        case .skipQuestion:
            return .ignored(.unavailableAction)
        case let .answer(value, answerKey):
            guard request.kind == .question,
                  contains(.answer, in: request.availableActions),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .ignored(.unavailableAction)
            }
            let key = answerKey ?? firstQuestionKey(request.content) ?? "answer"
            return .action(.user(.resolve(requestID, .answer([
                QuestionAnswer(questionKey: key, values: [.custom(SensitiveText(value))])
            ]))))
        }
    }

    private func isPending(_ lifecycle: RequestLifecycle) -> Bool {
        switch lifecycle {
        case .pending, .resolving, .awaitingExternalConfirmation: return true
        }
    }

    private func contains(_ action: AvailableResolutionAction, in actions: [AvailableResolutionAction]) -> Bool {
        actions.contains(action)
    }

    private func firstQuestionKey(_ content: RequestContent) -> String? {
        guard case let .question(question) = content else { return nil }
        return question.answerSchema.keysInProviderOrder.first ?? question.items.first?.key
    }
}

// MARK: - Apple Companion compatibility

/// Compatibility policy for MC/BLE companion commands. The publisher owns
/// transport; this adapter owns only version/target validation and conversion
/// into typed Center input.
@MainActor
public final class AppleCompanionCompatibilityAdapter {
    public static let supportedMajor = 1
    public static let supportedMinor = 0

    private var consumedCommands: Set<CommandFingerprint> = []
    private let maxConsumedCommands = 256

    public init() {}

    /// Validate only the protocol and publisher sequence envelope. This is
    /// useful for non-resolution commands (for example focus) that still must
    /// not be accepted from an old companion card.
    public func accepts(_ command: AppleCompanionCommandPayload, latestSequence: UInt64? = nil) -> Bool {
        guard command.effectiveMajor == Self.supportedMajor else { return false }
        guard let observed = command.observedSequence, let latestSequence else { return true }
        return observed == latestSequence
    }

    public func decision(
        _ command: AppleCompanionCommandPayload,
        snapshot: RedactedInteractionSnapshot,
        latestSequence: UInt64? = nil
    ) -> InteractionConsumerDecision {
        guard command.effectiveMajor == Self.supportedMajor else {
            return .ignored(.unsupportedMajor)
        }
        if let observed = command.observedSequence,
           let latestSequence,
           observed != latestSequence {
            return .ignored(.staleSequence)
        }

        switch command.type {
        case .requestCurrentState, .focus:
            // These commands are presentation/transport concerns and do not
            // enter the Center action stream.
            return .ignored(.unavailableAction)
        case .skipCurrentQuestion:
            // There is no generic Skip semantics. A source may expose a typed
            // question action, but the legacy wire command cannot prove one.
            return .ignored(.unavailableAction)
        case .approveCurrentPermission:
            return action(
                command: command,
                snapshot: snapshot,
                commandBuilder: { .resolve($0, .allowOnce) }
            )
        case .denyCurrentPermission:
            return action(
                command: command,
                snapshot: snapshot,
                commandBuilder: { .resolve($0, .deny(message: nil)) }
            )
        case .answerQuestion:
            guard let answer = command.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                return .ignored(.unavailableAction)
            }
            return action(
                command: command,
                snapshot: snapshot,
                commandBuilder: { requestID in
                    let answerKey = command.answerKey ?? snapshot.requests[requestID].flatMap(Self.firstQuestionKey) ?? "answer"
                    return .resolve(requestID, .answer([
                        QuestionAnswer(questionKey: answerKey, values: [.custom(SensitiveText(answer))])
                    ]))
                }
            )
        }
    }

    private func action(
        command: AppleCompanionCommandPayload,
        snapshot: RedactedInteractionSnapshot,
        commandBuilder: (RequestID) -> InteractionUserAction
    ) -> InteractionConsumerDecision {
        guard let requestID = target(for: command, snapshot: snapshot) else {
            return .ignored(command.requestID == nil ? .legacyCommandRequiresUniqueVisibleTarget : .staleRequest)
        }
        guard let request = snapshot.requests[requestID], request.pending, request.actionable else {
            return .ignored(.staleRequest)
        }

        let fingerprint = CommandFingerprint(command: command, target: requestID)
        guard consumedCommands.insert(fingerprint).inserted else {
            return .ignored(.duplicateCommand)
        }
        if consumedCommands.count > maxConsumedCommands {
            // This is a replay guard, not a durable history. Old command
            // fingerprints are evicted deterministically to keep the adapter
            // bounded; Center's EffectID ledger remains authoritative.
            consumedCommands.remove(consumedCommands.sorted().first!)
        }
        return .action(.user(commandBuilder(requestID)))
    }

    private func target(
        for command: AppleCompanionCommandPayload,
        snapshot: RedactedInteractionSnapshot
    ) -> RequestID? {
        if let requestID = command.requestID {
            guard let request = snapshot.requests[requestID], request.pending, request.actionable else { return nil }
            guard sessionMatches(command: command, request: request) else { return nil }
            return requestID
        }

        // v1 had no request identity. Only the currently visible request is a
        // legal target, and an optional legacy session/source must match it.
        let visible: [RedactedRequestSnapshot] = snapshot.requests.values.filter { request in
            request.pending && request.actionable && snapshot.presentation.surface == .request(request.id)
        }
        guard visible.count == 1, let request = visible.first else { return nil }
        guard sessionMatches(command: command, request: request) else { return nil }
        return request.id
    }

    private func sessionMatches(command: AppleCompanionCommandPayload, request: RedactedRequestSnapshot) -> Bool {
        if let expectedGeneration = command.sessionGeneration,
           expectedGeneration != request.session.generation {
            return false
        }
        if let expectedSession = command.sessionId, !expectedSession.isEmpty,
           expectedSession != request.session.key.providerSessionID {
            return false
        }
        if let expectedSource = command.source, !expectedSource.isEmpty,
           expectedSource.lowercased() != request.session.key.provider.rawValue {
            return false
        }
        return true
    }

    private static func firstQuestionKey(_ request: RedactedRequestSnapshot) -> String? {
        // Redacted snapshots intentionally don't contain prompt text. Answer
        // keys are non-sensitive protocol metadata and are carried additively
        // by newer command senders when a provider needs a non-default key.
        _ = request
        return nil
    }

    private struct CommandFingerprint: Hashable, Comparable {
        let sequence: UInt64?
        let requestID: RequestID?
        let type: AppleCompanionCommandType
        let answer: String?

        init(command: AppleCompanionCommandPayload, target: RequestID) {
            sequence = command.observedSequence
            requestID = command.requestID ?? target
            type = command.type
            answer = command.answer
        }

        static func < (lhs: CommandFingerprint, rhs: CommandFingerprint) -> Bool {
            String(describing: lhs) < String(describing: rhs)
        }
    }
}

// MARK: - ESP32 legacy controls

/// The original Buddy opcodes cannot carry a RequestID. They therefore only
/// resolve the one request currently displayed by the redacted projection.
/// Ambiguous, hidden, dismissed and cross-session targets are safe no-ops.
public struct ESP32LegacyActionAdapter: Sendable {
    public init() {}

    public func decision(
        _ command: BuddyControlCommand,
        snapshot: RedactedInteractionSnapshot
    ) -> InteractionConsumerDecision {
        let visible = snapshot.requests.values.filter { request in
            request.pending && request.actionable && snapshot.presentation.surface == .request(request.id)
        }
        guard visible.count == 1, let request = visible.first else {
            return .ignored(.ambiguousTarget)
        }

        switch command {
        case .approveCurrentPermission:
            guard request.kind == .permission, request.availableActionKinds.contains(.allow) else {
                return .ignored(.wrongKind)
            }
            return .action(.user(.resolve(request.id, .allowOnce)))
        case .denyCurrentPermission:
            guard request.availableActionKinds.contains(.deny) else {
                return .ignored(.unavailableAction)
            }
            return .action(.user(.resolve(request.id, .deny(message: nil))))
        case .skipCurrentQuestion:
            return .ignored(.unavailableAction)
        }
    }
}

/// The small, redacted state contract understood by the legacy Buddy
/// publisher. It intentionally contains no messages, cwd, terminal route,
/// PID, provider payload or request content.
public struct ESP32RedactedProjection: Sendable, Equatable {
    public let source: String
    public let status: MascotStatusCode
    public let pendingCount: Int
    public let pendingRequestID: RequestID?
    public let session: SessionRef?
    public let workspaceLabel: String?

    public init(snapshot: RedactedInteractionSnapshot) {
        let sessions = snapshot.sessions.values.sorted {
            if $0.pendingCount != $1.pendingCount { return $0.pendingCount > $1.pendingCount }
            return $0.session.key.provider.rawValue < $1.session.key.provider.rawValue
        }
        let request = snapshot.presentation.prominentRequest.flatMap { snapshot.requests[$0] }
        let selected = request.flatMap { snapshot.sessions[$0.session] } ?? sessions.first
        let selectedKind = request?.kind
            ?? selected?.pendingKinds.sorted(by: { String(describing: $0) < String(describing: $1) }).first
        self.source = selected?.session.key.provider.rawValue ?? "claude"
        switch selectedKind {
        case .permission: self.status = .waitingApproval
        case .question: self.status = .waitingQuestion
        case nil: self.status = .idle
        }
        self.pendingCount = snapshot.sessions.values.reduce(0) { $0 + $1.pendingCount }
        self.pendingRequestID = request?.id
        self.session = selected?.session
        // A title is a presentation label supplied by the upstream mapper. It
        // is not a path; external publishers never receive cwd in this type.
        self.workspaceLabel = selected?.title
    }
}

private extension RequestLifecycle {
    var isPendingForConsumer: Bool {
        switch self {
        case .pending, .resolving, .awaitingExternalConfirmation: return true
        }
    }
}
