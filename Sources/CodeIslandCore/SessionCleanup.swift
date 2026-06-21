import Foundation

/// Pure cleanup helpers used by `AppState.cleanupIdleSessions`. Extracted into
/// Core so they can be unit-tested without spinning up an `AppState` instance
/// (which is `@MainActor` and `@Observable`).
public enum SessionCleanup {

    /// Cleanup phase 5: remove stale `.idle` subagent entries. `threshold == 0`
    /// disables the phase entirely.
    public static func performSubagentFastCleanup(
        sessions: inout [String: SessionSnapshot],
        threshold: TimeInterval
    ) {
        guard threshold > 0 else { return }
        var subagentMutations: [(String, [String])] = []
        for (sessionId, session) in sessions {
            var staleAgentIds: [String] = []
            for (agentId, sub) in session.subagents where sub.status == .idle {
                if -sub.lastActivity.timeIntervalSinceNow > threshold {
                    staleAgentIds.append(agentId)
                }
            }
            if !staleAgentIds.isEmpty {
                subagentMutations.append((sessionId, staleAgentIds))
            }
        }
        for (sessionId, agentIds) in subagentMutations {
            for agentId in agentIds {
                sessions[sessionId]?.subagents.removeValue(forKey: agentId)
            }
        }
    }

    /// Cleanup phase 6: transcript-staleness interrupt detection (Claude Code
    /// double-ESC / single-ESC fallback). For sessions with a `transcriptPath`
    /// in `.running` / `.processing`, when the file hasn't been modified in
    /// `threshold` seconds AND `lastActivity` is also stale, flip status to
    /// `.idle` and mark `interrupted = true`. Threshold `0` disables the phase.
    public static func performTranscriptStalenessDetection(
        sessions: inout [String: SessionSnapshot],
        withToolThreshold: TimeInterval,
        noToolThreshold: TimeInterval
    ) {
        guard withToolThreshold > 0 || noToolThreshold > 0 else { return }
        let now = Date()
        for (key, session) in sessions
            where session.transcriptPath != nil
            && (session.status == .running || session.status == .processing)
            && !session.isRemote {
            let threshold: TimeInterval
            switch session.status {
            case .running:
                threshold = withToolThreshold
            case .processing:
                threshold = noToolThreshold > 0 ? noToolThreshold : withToolThreshold
            default:
                threshold = withToolThreshold
            }
            guard threshold > 0 else { continue }
            let path = session.transcriptPath ?? ""
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let staleSeconds = now.timeIntervalSince(mtime)
            let lastEventSilentFor = now.timeIntervalSince(session.lastActivity)
            if staleSeconds > threshold && lastEventSilentFor > threshold {
                sessions[key]?.interrupted = true
                sessions[key]?.status = .idle
                sessions[key]?.currentTool = nil
                sessions[key]?.toolDescription = nil
            }
        }
    }
}
