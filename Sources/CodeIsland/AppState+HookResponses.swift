import Foundation
import CodeIslandCore

extension AppState {
    /// Simple allow response for auto-approved permissions (no setMode)
    static let simpleAllowResponse = Data(
        #"{"continue":true,"suppressOutput":true,"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8
    )

    /// Codex-specific simple allow response. Codex CLI rejects `suppressOutput: true`.
    private static let codexSimpleAllowResponse = Data(
        #"{"continue":true,"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8
    )

    /// Pick the right allow-response bytes for the event's CLI source.
    static func allowResponseData(for event: HookEvent? = nil) -> Data {
        if let event, CodexPermissionRules.isCodexEvent(event) {
            return codexSimpleAllowResponse
        }
        return simpleAllowResponse
    }

    /// Generic ack response for non-permission events
    static let ackResponse = Data(#"{"continue":true,"suppressOutput":true}"#.utf8)

    static func hookResponse(
        hookEventName: String,
        decision: [String: Any],
        omitSuppressOutput: Bool = false
    ) -> Data {
        var obj: [String: Any] = [
            "continue": true,
            "hookSpecificOutput": [
                "hookEventName": hookEventName,
                "decision": decision,
            ] as [String: Any],
        ]
        if !omitSuppressOutput {
            obj["suppressOutput"] = true
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Self.simpleAllowResponse
    }

    static func permissionAllowResponse(
        updatedPermissions: [[String: Any]]? = nil,
        updatedInput: [String: Any]? = nil
    ) -> Data {
        var decision: [String: Any] = ["behavior": "allow"]
        if let updatedPermissions { decision["updatedPermissions"] = updatedPermissions }
        if let updatedInput { decision["updatedInput"] = updatedInput }
        return hookResponse(hookEventName: "PermissionRequest", decision: decision)
    }

    static func permissionDenyResponse(message: String? = nil) -> Data {
        var decision: [String: Any] = ["behavior": "deny"]
        if let message, !message.isEmpty { decision["message"] = message }
        return hookResponse(hookEventName: "PermissionRequest", decision: decision)
    }

    static func denyResponseData(for event: HookEvent? = nil, message: String? = nil) -> Data {
        if let event, CodexPermissionRules.isCodexEvent(event) {
            var decision: [String: Any] = ["behavior": "deny"]
            if let message, !message.isEmpty { decision["message"] = message }
            return hookResponse(
                hookEventName: "PermissionRequest",
                decision: decision,
                omitSuppressOutput: true
            )
        }
        return permissionDenyResponse(message: message)
    }

    static func notificationResponse(answer: String? = nil) -> Data {
        var hookOutput: [String: Any] = ["hookEventName": "Notification"]
        if let answer { hookOutput["answer"] = answer }
        let obj: [String: Any] = [
            "continue": true,
            "suppressOutput": true,
            "hookSpecificOutput": hookOutput,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Self.simpleAllowResponse
    }
}
