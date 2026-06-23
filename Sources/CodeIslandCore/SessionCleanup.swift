import Foundation

/// Pure cleanup helpers used by `AppState.cleanupIdleSessions`. Extracted into
/// Core so they can be unit-tested without spinning up an `AppState` instance
/// (which is `@MainActor` and `@Observable`).
public enum SessionCleanup {

    /// Cleanup phase 5: remove stale non-running subagent entries.
    /// `threshold == 0` disables the phase entirely.
    /// `mergedSessionIds` (when non-empty) lists subagent agentIds that are
    /// still being actively redirected by `AppState.handleEvent`; those entries
    /// are preserved as long as the underlying subagent is still active, so
    /// the redirect path can keep landing on the same subagent channel key.
    /// However, a subagent that has been silent for much longer than
    /// `staleRedirectMultiplier * threshold` is presumed to be abandoned and
    /// is returned in `evictedMergedIds` so the caller can drop the
    /// `mergedSessionIds` cache entry too. Without this escape hatch, a
    /// truly-idle merged child would pin its parent's `subagents` dictionary
    /// (and the entire retained session) forever — a major contributor to
    /// the v1.2.8 idle-memory regression.
    /// - Returns: the agentIds whose `mergedSessionIds` cache entry should
    ///   also be evicted. Empty when no merge redirects were stale.
    @discardableResult
    public static func performSubagentFastCleanup(
        sessions: inout [String: SessionSnapshot],
        threshold: TimeInterval,
        mergedSessionIds: [String: String] = [:],
        staleRedirectMultiplier: Double = 10
    ) -> [String] {
        guard threshold > 0 else { return [] }
        let staleRedirectThreshold = threshold * staleRedirectMultiplier
        var evictedMergedIds: [String] = []
        var subagentMutations: [(String, [String])] = []
        for (sessionId, session) in sessions {
            var staleAgentIds: [String] = []
            for (agentId, sub) in session.subagents
                where sub.status != .running {
                let silentFor = -sub.lastActivity.timeIntervalSinceNow
                guard silentFor > threshold else { continue }
                if mergedSessionIds[agentId] == nil {
                    // Non-redirected: drop on first sight of staleness.
                    staleAgentIds.append(agentId)
                } else if silentFor > staleRedirectThreshold {
                    // Redirected: only drop when the redirect has been stale
                    // for many threshold cycles. After this drop the caller
                    // also evicts the mergedSessionIds entry so a subsequent
                    // event for this child is treated as a fresh session.
                    staleAgentIds.append(agentId)
                    evictedMergedIds.append(agentId)
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
        return evictedMergedIds
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
