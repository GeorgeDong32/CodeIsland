import Foundation
import CodeIslandCore

extension AppState {
    /// Establishes the upstream session fact needed before a hook request can
    /// be admitted.  Hook ingress can arrive before an explicit SessionStart;
    /// this method creates only the upstream snapshot and lets the shared
    /// generation authority bind the request to it.
    func prepareInteractionHookSession(_ event: HookEvent, question: Bool) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot(startTime: Date())
        }

        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }

        var snapshot = sessions[sessionId] ?? SessionSnapshot(startTime: Date())
        if let source = event.rawJSON["_source"] as? String,
           let normalized = SessionSnapshot.normalizedSupportedSource(source) {
            snapshot.source = normalized
        }
        if snapshot.providerSessionId == nil {
            snapshot.providerSessionId = sessionId
        }
        snapshot.status = question ? .waitingQuestion : .waitingApproval
        snapshot.currentTool = event.toolName
        snapshot.toolDescription = event.toolDescription
        snapshot.lastActivity = Date()
        sessions[sessionId] = snapshot

        publishInteractionObservation(for: sessionId, observedAt: snapshot.lastActivity)
    }

    /// Called by HookServer for provider/session close paths.  The Center gets
    /// an identity-bearing close observation before upstream state is removed.
    func prepareInteractionHookClose(_ sessionId: String) {
        closeInteractionSession(for: sessionId)
    }
}
