import Foundation

/// Providers that can produce a question-shaped interaction.  This closed set
/// prevents UI callers from inferring protocol behavior from source strings.
public enum QuestionProvider: String, Codable, Sendable, Equatable {
    case hookNotification
    case hookAskUserQuestion
    case codexRequestUserInput
    case nativePrompt
}

/// The provider contract for a question source. `displayOnly` intentionally
/// carries no response channel; callers must not synthesize an empty answer.
public struct QuestionCapabilityDescriptor: Sendable, Equatable, Codable {
    public let provider: QuestionProvider
    public let behavior: RequestBehavior

    public init(provider: QuestionProvider, behavior: RequestBehavior) {
        self.provider = provider
        self.behavior = behavior
    }

    public var capabilities: ResolutionCapabilities? {
        guard case let .blocking(value) = behavior else { return nil }
        return value
    }

    public var isDisplayOnly: Bool {
        if case .displayOnly = behavior { return true }
        return false
    }

    public var isNativeOwned: Bool {
        if case .nativeOwned = behavior { return true }
        return false
    }
}

public extension QuestionCapabilityDescriptor {
    /// Notification has no portable resolution semantics. It may be displayed,
    /// dismissed, and later rediscovered from the provider, but the adapter does
    /// not call a guessed empty-answer or deny response.
    static let hookNotification = QuestionCapabilityDescriptor(
        provider: .hookNotification,
        behavior: .displayOnly
    )

    /// AskUserQuestion is a blocking Hook protocol with a stable deny response.
    static let hookAskUserQuestion = QuestionCapabilityDescriptor(
        provider: .hookAskUserQuestion,
        behavior: .blocking(ResolutionCapabilities(questionActions: [.reject]))
    )

    /// Codex accepts an empty answers object as the explicit abandon/continue
    /// action for requestUserInput. It is named here, never surfaced as Skip.
    static let codexRequestUserInput = QuestionCapabilityDescriptor(
        provider: .codexRequestUserInput,
        behavior: .blocking(ResolutionCapabilities(questionActions: [.abandon]))
    )

    static let nativePrompt = QuestionCapabilityDescriptor(
        provider: .nativePrompt,
        behavior: .nativeOwned
    )
}

/// Shared provider capability lookup used by ingress adapters and AppState
/// migration helpers. It does not own request lifecycle or transport state.
public enum QuestionCapabilityRegistry {
    public static func descriptor(for provider: QuestionProvider) -> QuestionCapabilityDescriptor {
        switch provider {
        case .hookNotification: return .hookNotification
        case .hookAskUserQuestion: return .hookAskUserQuestion
        case .codexRequestUserInput: return .codexRequestUserInput
        case .nativePrompt: return .nativePrompt
        }
    }
}
