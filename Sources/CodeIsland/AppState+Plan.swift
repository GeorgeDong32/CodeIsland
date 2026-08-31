import Foundation
import CodeIslandCore
import OSLog

private let planLog = Logger(subsystem: "com.codeisland", category: "Plan")

extension AppState {
    // MARK: - Plan Approval (ExitPlanMode)

    /// Extract setMode suggestion from the targeted ExitPlanMode request.
    ///
    /// Plan actions must carry the card's session identity.  In particular, a
    /// Plan helper must never silently act on `permissionQueue.first`, since a
    /// regular permission from another session can move the queue head while a
    /// card is being rendered.
    func suggestedModeForPendingPlan(expectedSessionId: String) -> String? {
        guard let pending = pendingPlan(expectedSessionId: expectedSessionId),
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

    /// Resolve the setMode value for the Plan card's Allow always action.
    /// Priority:
    /// 1. permission_suggestions (preserves Claude Code's explicit hint)
    /// 2. SettingsManager.shared.planAutoAcceptMode.rawValue ("auto" or "acceptEdits")
    /// 3. "acceptEdits" as the final safety net (handled by the caller)
    func smartModeForPendingPlan(expectedSessionId: String) -> String? {
        if let suggested = suggestedModeForPendingPlan(expectedSessionId: expectedSessionId) {
            return suggested
        }
        return SettingsManager.shared.planAutoAcceptMode.rawValue
    }

    /// Resolve the targeted ExitPlanMode request with an explicit Plan action.
    ///
    /// `mode == nil` is the typed/manual Plan resolution.  Its historical wire
    /// representation is a plain allow, but the helper name and target make it
    /// clear that this is a Plan resolution rather than a queue operation.
    func allowPlan(mode: String?, expectedSessionId: String) {
        guard let index = planIndex(expectedSessionId: expectedSessionId) else {
            discardStalePlanAction(expectedSessionId: expectedSessionId, kind: "allowPlan")
            return
        }

        let pending = permissionQueue.remove(at: index)
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
            responseData = Self.allowResponseData(for: pending.event)
        }

        pending.continuation.resume(returning: responseData)
        sessions[sessionId]?.status = .running
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil

        showNextPending()
        refreshDerivedState()
    }

    /// Deny the targeted Plan request, optionally providing feedback for a
    /// revision.  This is deliberately separate from generic permission deny
    /// so a Plan card cannot resolve whichever request happens to be first.
    func denyPlanWithFeedback(_ feedback: String?, expectedSessionId: String) {
        guard let index = planIndex(expectedSessionId: expectedSessionId) else {
            discardStalePlanAction(expectedSessionId: expectedSessionId, kind: "denyPlan")
            return
        }

        let pending = permissionQueue.remove(at: index)
        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.remove(sessionId)

        let responseData = feedback.flatMap { message in
            message.isEmpty ? nil : Self.denyResponseData(for: pending.event, message: message)
        } ?? Self.denyResponseData(for: pending.event)
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

    /// Finds a Plan request by its explicit session target.
    ///
    /// The current AppState bridge predates Center RequestIDs, so the session
    /// is the strongest identity available at this seam.  Returning nil for a
    /// missing/stale target is a safe no-op; it must never fall back to queue
    /// head and risk answering a different CLI request.
    private func pendingPlan(expectedSessionId: String) -> PermissionRequest? {
        guard let index = planIndex(expectedSessionId: expectedSessionId) else { return nil }
        return permissionQueue[index]
    }

    private func planIndex(expectedSessionId: String) -> Int? {
        permissionQueue.firstIndex {
            ($0.event.sessionId ?? "default") == expectedSessionId
                && $0.event.toolName == "ExitPlanMode"
        }
    }

    private func discardStalePlanAction(expectedSessionId: String, kind: String) {
        planLog.notice(
            "⚠️ ignored \(kind, privacy: .public) for session=\(expectedSessionId, privacy: .public) — Plan request no longer queued"
        )
        showNextPending()
        refreshDerivedState()
    }
}
