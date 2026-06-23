import Foundation
import CodeIslandCore

extension AppState {
    /// Start watching a session's transcript file for appended lines. Safe to call
    /// repeatedly with the same (session, path) pair — the tailer reattaches only
    /// when the path actually changed.
    func attachTranscriptTailerIfNeeded(sessionId: String) {
        guard let path = sessions[sessionId]?.transcriptPath, !path.isEmpty else { return }
        if attachedTranscriptPaths[sessionId] == path { return }
        attachedTranscriptPaths[sessionId] = path
        transcriptTailer.attach(sessionId: sessionId, filePath: path)
    }

    /// Stop watching a session's transcript. Called when the session is removed or
    /// when a new transcript path supersedes an older one.
    func detachTranscriptTailer(sessionId: String) {
        attachedTranscriptPaths.removeValue(forKey: sessionId)
        transcriptTailer.detach(sessionId: sessionId)
    }

    /// Apply an incremental update produced by the tailer. Runs on the main actor.
    func applyTranscriptDelta(_ delta: ConversationTailDelta) {
        guard var session = sessions[delta.sessionId] else { return }
        var mutated = false

        if let prompt = delta.lastUserPrompt, session.lastUserPrompt != prompt {
            // Cap at the same per-field byte limit used elsewhere so a long
            // tailer delta cannot blow past the display budget.
            let capped = SessionSnapshot.truncatedForDisplay(prompt)
            session.lastUserPrompt = capped
            if session.recentMessages.last(where: { $0.isUser })?.text != capped {
                session.addRecentMessage(ChatMessage(isUser: true, text: capped))
            }
            mutated = true
        }
        if let reply = delta.lastAssistantMessage, session.lastAssistantMessage != reply {
            let capped = SessionSnapshot.truncatedForDisplay(reply)
            session.lastAssistantMessage = capped
            if session.recentMessages.last(where: { !$0.isUser })?.text != capped {
                session.addRecentMessage(ChatMessage(isUser: false, text: capped))
            }
            mutated = true
        }

        if mutated {
            session.lastActivity = Date()
            sessions[delta.sessionId] = session
        }
    }
}
