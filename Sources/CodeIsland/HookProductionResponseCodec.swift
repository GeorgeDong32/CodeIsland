import Foundation
import CodeIslandCore

/// Provider-wire encoding for the production Hook adapter.  InteractionCenter
/// emits only a typed ResolutionCommand; this codec is the sole place where a
/// HookEvent is combined with that command to make provider JSON.
@MainActor
enum HookProductionResponseCodec {
    static func data(for response: HookWireResponse, event: HookEvent) -> Data {
        switch response {
        case let .provider(plan):
            switch plan {
            case .safeToolAllow, .alwaysProceedAllow:
                return AppState.allowResponseData(for: event)
            case .providerOwnedAck, .ordinaryAck, .malformedQuestionFallback:
                return AppState.ackResponse
            }
        case let .neutral(response):
            switch response {
            case .notificationAck: return AppState.notificationResponse()
            case .hookEmptyObject, .codexEmptyAnswers: return Data("{}".utf8)
            }
        case let .resolution(command):
            return resolutionData(for: command, event: event)
        }
    }

    private static func resolutionData(for command: ResolutionCommand, event: HookEvent) -> Data {
        switch command {
        case .allowOnce:
            return AppState.allowResponseData(for: event)
        case .allowAlways:
            return AppState.permissionAllowResponse(updatedPermissions: [[
                "type": "addRules",
                "rules": [["toolName": event.toolName ?? ""]],
                "behavior": "allow",
                "destination": "session",
            ]])
        case let .allowPlan(mode):
            let modeValue: String
            switch mode {
            case .manual: return AppState.allowResponseData(for: event)
            case let .suggested(value): modeValue = value
            }
            return AppState.permissionAllowResponse(updatedPermissions: [[
                "type": "setMode", "mode": modeValue, "destination": "session",
            ]])
        case let .deny(message):
            return AppState.denyResponseData(for: event, message: message)
        case let .answer(answers):
            return answerData(answers, event: event)
        case let .questionAction(action, reason):
            switch action {
            case .reject:
                return AppState.denyResponseData(for: event, message: reason)
            case .abandon, .continueWithoutAnswer:
                return event.toolName == "AskUserQuestion"
                    ? AppState.denyResponseData(for: event, message: reason)
                    : AppState.notificationResponse()
            }
        }
    }

    private static func answerData(_ answers: [QuestionAnswer], event: HookEvent) -> Data {
        let values = answers.reduce(into: [String: String]()) { result, answer in
            guard let value = answer.values.first else { return }
            switch value {
            case let .option(option): result[answer.questionKey] = option
            case let .custom(text): result[answer.questionKey] = text.value
            }
        }

        if event.toolName == "AskUserQuestion" {
            var updatedInput = event.toolInput ?? [:]
            updatedInput["questions"] = event.toolInput?["questions"] ?? [] as [[String: Any]]
            updatedInput["answers"] = values
            if let answer = values.values.first, !AppState.isQoderEvent(event) {
                updatedInput["answer"] = answer
            }
            return AppState.permissionAllowResponse(updatedInput: updatedInput)
        }
        return AppState.notificationResponse(answer: values.values.first)
    }

}
