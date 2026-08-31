import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class AppStateQuestionLifecycleTests: XCTestCase {
    func testDismissLeavesProviderQuestionPendingAndRevealRestoresPresentation() throws {
        let appState = AppState()
        var replyCount = 0
        let event = try makeEvent(sessionID: "codexapp:lifecycle")
        let payload = QuestionPayload(question: "Continue?", options: ["Yes", "No"], header: "Plan")
        appState.questionQueue.append(QuestionRequest(
            event: event,
            question: payload,
            resolution: .codexAppServer { _ in replyCount += 1 }
        ))
        appState.surface = .questionCard(sessionId: "codexapp:lifecycle")

        appState.dismissQuestionPrompt(expectedSessionId: "codexapp:lifecycle")

        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(replyCount, 0, "dismiss is presentation-only and must not answer Codex")
        XCTAssertTrue(appState.dismissedQuestionSessionIds.contains("codexapp:lifecycle"))

        appState.revealQuestionPrompt(expectedSessionId: "codexapp:lifecycle")

        XCTAssertEqual(appState.surface, .questionCard(sessionId: "codexapp:lifecycle"))
        XCTAssertFalse(appState.dismissedQuestionSessionIds.contains("codexapp:lifecycle"))
        XCTAssertEqual(appState.questionQueue.count, 1)
    }

    func testDismissWithStaleSessionDoesNotTouchAnotherQuestion() throws {
        let appState = AppState()
        let first = try makeEvent(sessionID: "q-first")
        let second = try makeEvent(sessionID: "q-second")
        let payload = QuestionPayload(question: "Pick", options: ["A"])
        appState.questionQueue = [
            QuestionRequest(event: first, question: payload, resolution: .codexAppServer { _ in }),
            QuestionRequest(event: second, question: payload, resolution: .codexAppServer { _ in }),
        ]
        appState.surface = .questionCard(sessionId: "q-second")

        appState.dismissQuestionPrompt(expectedSessionId: "missing")

        XCTAssertEqual(appState.questionQueue.map { $0.event.sessionId }, ["q-first", "q-second"])
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "q-second"))
        XCTAssertTrue(appState.dismissedQuestionSessionIds.isEmpty)
    }

    func testCodexQuestionAdapterExposesAnswerAndTypedAbandonOnly() throws {
        let event = try makeEvent(sessionID: "codexapp:typed")
        let payload = QuestionPayload(question: "Pick", options: ["A"], header: "Choice", isSecret: true)
        let request = QuestionRequest(
            event: event,
            question: payload,
            resolution: .codexAppServer { _ in }
        )

        XCTAssertEqual(appStateForTesting.questionBehavior(for: request),
                       .blocking(ResolutionCapabilities(questionActions: [.abandon])))
        XCTAssertEqual(appStateForTesting.questionAvailableActions(for: request),
                       [.answer, .questionAction(.abandon)])
        let content = AppStateQuestionAdapter.content(for: request)
        XCTAssertEqual(content.items.first?.prompt.sensitivity, .secret)
        XCTAssertEqual(content.answerSchema.keysInProviderOrder, ["Choice"])
    }

    func testProviderRegistryKeepsNotificationDisplayOnlyAndNativePromptOwned() {
        XCTAssertEqual(QuestionCapabilityRegistry.descriptor(for: .hookNotification).behavior, .displayOnly)
        XCTAssertTrue(QuestionCapabilityRegistry.descriptor(for: .hookNotification).isDisplayOnly)
        XCTAssertEqual(QuestionCapabilityRegistry.descriptor(for: .nativePrompt).behavior, .nativeOwned)
        XCTAssertTrue(QuestionCapabilityRegistry.descriptor(for: .nativePrompt).isNativeOwned)
    }

    private var appStateForTesting: AppState { AppState() }

    private func makeEvent(sessionID: String) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "session_id": sessionID,
        ])
        return try XCTUnwrap(HookEvent(from: data))
    }
}
