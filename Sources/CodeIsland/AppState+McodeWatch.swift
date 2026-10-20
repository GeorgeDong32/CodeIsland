import Foundation
import CodeIslandCore

/// Applies `McodePermissionLogWatcher` events to minimax session cards.
///
/// mcode never routes interactive permission asks to hooks (see the watcher's
/// header), so these waits are always display-only: the card flips to
/// `waitingApproval` with the tool/command detail, follow-up reminders and a
/// one-time push announce it, and the terminal jump takes the user to the TUI
/// where the actual dialog lives. The island itself holds no request.
extension AppState {

    func startMcodePermissionWatcher() {
        guard ConfigInstaller.mcodePresenceDetected() else { return }
        guard mcodePermissionWatcher == nil else { return }
        let watcher = McodePermissionLogWatcher { [weak self] events in
            Task { @MainActor in
                self?.applyMcodePermissionEvents(events)
            }
        }
        watcher.start()
        mcodePermissionWatcher = watcher
    }

    func stopMcodePermissionWatcher() {
        mcodePermissionWatcher?.stop()
        mcodePermissionWatcher = nil
    }

    func applyMcodePermissionEvents(_ events: [McodePermissionLogWatcher.Event]) {
        var commands: [String: String] = [:]
        for event in events {
            if case .command(let sessionId, let command) = event {
                commands[sessionId] = command
            }
        }

        for event in events {
            switch event {
            case .command:
                continue   // folded into the ask below

            case .ask(let requestId, let sessionId, let toolName):
                guard sessions[sessionId]?.source == "minimax" else { continue }
                mcodePendingAsks[requestId] = sessionId

                // Active turns only — an ask implies a running turn, and an
                // idle card must not be woken by a stale log line.
                guard let status = sessions[sessionId]?.status,
                      status == .processing || status == .running else { continue }

                let before = displayOnlyWaitKind(forSession: sessionId)
                sessions[sessionId]?.status = .waitingApproval
                sessions[sessionId]?.currentTool = toolName
                sessions[sessionId]?.toolDescription = commands[sessionId]
                    .map { String($0.prefix(120)) }
                sessions[sessionId]?.lastActivity = Date()
                refreshDerivedState()
                noteDisplayOnlyWait(
                    sessionId: sessionId,
                    was: before,
                    asking: .permission(tool: toolName, detail: commands[sessionId].map { String($0.prefix(80)) }),
                    announce: true
                )

            case .resolved(let requestId, let sessionId):
                mcodePendingAsks.removeValue(forKey: requestId)
                // Only clear the wait when the session's LAST pending ask is
                // gone — concurrent asks keep the card waiting.
                guard mcodePendingAsks.values.first(where: { $0 == sessionId }) == nil else { continue }
                guard sessions[sessionId]?.status == .waitingApproval else { continue }

                let before = displayOnlyWaitKind(forSession: sessionId)
                sessions[sessionId]?.status = .processing
                sessions[sessionId]?.lastActivity = Date()
                refreshDerivedState()
                noteDisplayOnlyWait(sessionId: sessionId, was: before)
            }
        }
    }
}
