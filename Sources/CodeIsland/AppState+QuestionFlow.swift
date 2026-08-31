import Foundation
import CodeIslandCore

/// Typed projection used while the legacy AppState question queue remains the
/// sole production owner. It deliberately contains no continuation or queue
/// mutation and can be replaced by InteractionCenter snapshots in a later
/// phase without changing provider capability semantics.
struct AppStateQuestionAdapter {
    static func provider(for request: QuestionRequest) -> QuestionProvider {
        if request.isCodexAppServer { return .codexRequestUserInput }
        if request.isFromPermission { return .hookAskUserQuestion }
        return .hookNotification
    }

    static func descriptor(for request: QuestionRequest) -> QuestionCapabilityDescriptor {
        QuestionCapabilityRegistry.descriptor(for: provider(for: request))
    }

    static func behavior(for request: QuestionRequest) -> RequestBehavior {
        descriptor(for: request).behavior
    }

    static func content(for request: QuestionRequest) -> QuestionContent {
        if let state = request.askUserQuestionState, !state.items.isEmpty {
            let items = state.items.map(questionItem)
            return QuestionContent(
                items: items,
                answerSchema: AnswerSchema(
                    keysInProviderOrder: items.map(\.key),
                    allowsCustomText: true
                )
            )
        }

        let payload = request.question
        let key = payload.header.flatMap { $0.isEmpty ? nil : $0 } ?? "answer"
        let sensitivity: Sensitivity = payload.isSecret ? .secret : .public
        let options = (payload.options ?? []).enumerated().map { index, label in
            QuestionOption(
                key: "option_\(index + 1)",
                label: SensitiveText(label, sensitivity: sensitivity)
            )
        }
        let item = QuestionItem(
            key: key,
            prompt: SensitiveText(payload.question, sensitivity: sensitivity),
            options: options
        )
        return QuestionContent(
            items: [item],
            answerSchema: AnswerSchema(keysInProviderOrder: [key], allowsCustomText: true)
        )
    }

    static func availableActions(for request: QuestionRequest) -> [AvailableResolutionAction] {
        guard case let .blocking(capabilities) = behavior(for: request) else { return [] }
        return [.answer]
            + capabilities.questionActions.sorted { String(describing: $0) < String(describing: $1) }
                .map(AvailableResolutionAction.questionAction)
    }

    private static func questionItem(_ item: AskUserQuestionItem) -> QuestionItem {
        let payload = item.payload
        let sensitivity: Sensitivity = payload.isSecret ? .secret : .public
        let options = (payload.options ?? []).enumerated().map { index, label in
            QuestionOption(
                key: "option_\(index + 1)",
                label: SensitiveText(label, sensitivity: sensitivity)
            )
        }
        return QuestionItem(
            key: item.answerKey,
            prompt: SensitiveText(payload.question, sensitivity: sensitivity),
            options: options,
            allowsMultiple: item.multiSelect
        )
    }
}

extension AppState {
    /// Dismisses only the local question presentation. The request remains in
    /// `questionQueue` and its provider channel is untouched, so dismiss cannot
    /// accidentally answer/deny a CLI request.
    func dismissQuestionPrompt(expectedSessionId: String? = nil) {
        let index: Int?
        if let expectedSessionId {
            index = questionQueue.firstIndex { ($0.event.sessionId ?? "default") == expectedSessionId }
        } else {
            index = questionQueue.isEmpty ? nil : 0
        }
        guard let index else { return }

        let sessionId = questionQueue[index].event.sessionId ?? "default"
        dismissedQuestionSessionIds.insert(sessionId)
        if case let .questionCard(shownSessionId) = surface, shownSessionId == sessionId {
            surface = .collapsed
        }
        refreshDerivedState()
    }

    /// Explicit local recovery for a previously dismissed question. This does
    /// not create a response effect; it only restores the presentation.
    func revealQuestionPrompt(expectedSessionId: String) {
        guard questionQueue.contains(where: { ($0.event.sessionId ?? "default") == expectedSessionId }) else {
            return
        }
        dismissedQuestionSessionIds.remove(expectedSessionId)
        activeSessionId = expectedSessionId
        surface = .questionCard(sessionId: expectedSessionId)
        refreshDerivedState()
    }

    func questionBehavior(for request: QuestionRequest) -> RequestBehavior {
        AppStateQuestionAdapter.behavior(for: request)
    }

    func questionAvailableActions(for request: QuestionRequest) -> [AvailableResolutionAction] {
        AppStateQuestionAdapter.availableActions(for: request)
    }
}
