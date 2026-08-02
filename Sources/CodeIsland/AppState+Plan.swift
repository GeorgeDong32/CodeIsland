import Foundation
import CodeIslandCore

extension AppState {
    // MARK: - Plan Approval (ExitPlanMode)

    /// Extract setMode suggestion from ExitPlanMode permission_suggestions
    func suggestedModeForPendingPlan() -> String? {
        guard let pending = permissionQueue.first,
              pending.event.toolName == "ExitPlanMode",
              let suggestions = pending.event.rawJSON["permission_suggestions"] as? [[String: Any]] else {
            return nil
        }
        for suggestion in suggestions {
            if suggestion["type"] as? String == "setMode",
               let mode = suggestion["mode"] as? String {
                return mode
            }
        }
        return nil
    }

    /// Resolve the setMode value for the Plan card's auto-accept OptionRow.
    /// Priority:
    /// 1. permission_suggestions (preserves Claude Code's explicit hint)
    /// 2. SettingsManager.shared.planAutoAcceptMode.rawValue ("auto" or "acceptEdits")
    /// 3. "acceptEdits" as the final safety net (handled by the caller)
    func smartModeForPendingPlan() -> String? {
        if let suggested = suggestedModeForPendingPlan() { return suggested }
        return SettingsManager.shared.planAutoAcceptMode.rawValue
    }

    /// Approve ExitPlanMode with optional permission mode change
    func approvePlanWithMode(_ mode: String?) {
        guard !permissionQueue.isEmpty else { return }
        let pending = permissionQueue.removeFirst()
        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.remove(sessionId)

        let responseData: Data
        if let mode {
            responseData = Self.permissionAllowResponse(updatedPermissions: [[
                "type": "setMode",
                "mode": mode,
                "destination": "session",
            ]])
        } else {
            responseData = Self.simpleAllowResponse
        }

        pending.continuation.resume(returning: responseData)
        sessions[sessionId]?.status = .running
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil

        showNextPending()
        refreshDerivedState()
    }

    /// Deny permission with optional feedback message (Plan "Request Changes").
    func denyPermissionWithFeedback(_ feedback: String?) {
        guard !permissionQueue.isEmpty else { return }
        let pending = permissionQueue.removeFirst()
        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.remove(sessionId)

        let responseData: Data
        if let feedback, !feedback.isEmpty {
            responseData = Self.denyResponseData(for: pending.event, message: feedback)
        } else {
            responseData = Self.denyResponseData(for: pending.event)
        }
        pending.continuation.resume(returning: responseData)
        sessions[sessionId]?.status = .idle
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil

        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }

        showNextPending()
        refreshDerivedState()
    }
}
