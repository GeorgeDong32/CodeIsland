import Foundation
import CodeIslandCore
import OSLog

private let log = Logger(subsystem: "com.codeisland", category: "AppState")

/// Typed bridge for the Phase 5 Auto owner.  AppState's legacy hook response
/// path is intentionally left below until the permission continuation owner is
/// cut over; this controller is the seam that production wiring can inject
/// without making a pending permission continuation an Auto transport.
@MainActor
final class AppStateAutoApproveController {
    let contexts: InteractionSessionContextStore
    let adapter: AutoCommandAdapter
    let compiler: AutoCommandCompiler

    init(
        contexts: InteractionSessionContextStore,
        adapter: AutoCommandAdapter,
        compiler: AutoCommandCompiler = AutoCommandCompiler()
    ) {
        self.contexts = contexts
        self.adapter = adapter
        self.compiler = compiler
    }

    convenience init(
        adapter: AutoCommandAdapter,
        compiler: AutoCommandCompiler = AutoCommandCompiler()
    ) {
        self.init(
            contexts: InteractionSessionContextStore(),
            adapter: adapter,
            compiler: compiler
        )
    }

    @discardableResult
    func observe(
        _ observation: SessionObservation
    ) -> AutoSnapshot {
        contexts.observe(observation)
    }

    /// Builds an independent Auto transaction for one complete SessionRef.
    /// The returned effect must be submitted by the coordinator; this method
    /// does not execute a permission response or mark the mode confirmed.
    @discardableResult
    func begin(
        session: SessionRef,
        intent: AutoModeIntent,
        effectID: EffectID,
        token: AutoControlToken,
        completion: @escaping (Result<AutoDelivery, AutoAdapterFailure>) -> Void
    ) -> Result<AutoCommandTransaction, AutoCompileError> {
        let result = contexts.beginAuto(session: session, intent: intent, effectID: effectID, token: token, compiler: compiler)
        // The coordinator is the sole effect executor. This controller records
        // the per-session transaction, but never submits it directly (doing so
        // would create a second Auto writer beside InteractionCoordinator).
        _ = completion
        return result
    }

    func markDelivered(_ effectID: EffectID, session: SessionRef) -> Bool {
        contexts.markDelivered(effectID, session: session)
    }

    func markAwaitingConfirmation(_ effectID: EffectID, session: SessionRef) -> Bool {
        contexts.markAwaitingConfirmation(effectID, session: session)
    }

    func fail(_ effectID: EffectID, session: SessionRef, message: String) -> Bool {
        contexts.fail(effectID, session: session, message: message)
    }

    func disconnect(session: SessionRef) {
        contexts.disconnect(session: session)
    }
}

extension AutoApproveMode {
    /// Settings are translated once at the AppState boundary. Provider command
    /// names never leak into the UI-facing intent.
    var interactionIntent: AutoModeIntent {
        switch self {
        case .auto, .addRules: return .enable
        case .bypassPermissions: return .bypassExplicit
        }
    }
}

extension AppState {
    // MARK: - Auto Approve

    /// Whether auto-approve is active for the given session
    func isAutoApproveActive(for sessionId: String) -> Bool {
        autoApproveSessionId == sessionId
    }

    /// Clear AUTO state when a session is removed. Thin hook from `removeSession`.
    func clearAutoApproveState(forRemovedSession sessionId: String) {
        if autoApproveSessionId == sessionId {
            autoApproveSessionId = nil
            autoApproveModeSnapshot = nil
        }
        if pendingAutoCleanup?.sessionId == sessionId {
            pendingAutoCleanup = nil
        }
    }

    /// Sync auto-approve state with hook-reported permission mode.
    /// Thin hook from `handleEvent` after reducer effects.
    func syncAutoApproveWithPermissionMode(sessionId: String) {
        let autoModes: Set<String> = ["auto", "acceptEdits", "bypassPermissions"]
        if let mode = sessions[sessionId]?.permissionMode {
            if autoModes.contains(mode) {
                if autoApproveSessionId != sessionId {
                    autoApproveSessionId = sessionId
                    autoApproveModeSnapshot = {
                        switch mode {
                        case "bypassPermissions": return .bypassPermissions
                        case "acceptEdits": return .addRules
                        default: return .auto
                        }
                    }()
                }
            } else if autoApproveSessionId == sessionId {
                deactivateAutoApprove(sessionId: sessionId)
            }
        }
    }

    /// Consume pending AUTO cleanup for a session, if any.
    /// Returns the mode that was active when AUTO was deactivated (for removeRules decision).
    func consumePendingAutoCleanup(for sessionId: String) -> AutoApproveMode? {
        guard pendingAutoCleanup?.sessionId == sessionId else { return nil }
        let mode = pendingAutoCleanup?.mode
        pendingAutoCleanup = nil
        return mode
    }

    /// Build `updatedPermissions` entries that reset AUTO after deactivation.
    /// - Parameters:
    ///   - mode: Mode snapshot from when AUTO was active
    ///   - preserveToolName: When non-nil (Always allow path), skip removing that tool's rule
    static func autoCleanupPermissionEntries(
        mode: AutoApproveMode,
        preserveToolName: String? = nil
    ) -> [[String: Any]] {
        var permissions: [[String: Any]] = [
            ["type": "setMode", "mode": "default", "destination": "session"],
        ]
        if mode != .auto {
            let rulesToRemove: [String]
            if let preserveToolName {
                rulesToRemove = autoApproveToolNames.filter { $0 != preserveToolName }
            } else {
                rulesToRemove = autoApproveToolNames
            }
            if !rulesToRemove.isEmpty {
                permissions.append([
                    "type": "removeRules",
                    "rules": rulesToRemove.map { ["toolName": $0, "ruleContent": "*"] },
                    "behavior": "allow",
                    "destination": "session",
                ])
            }
        }
        return permissions
    }

    /// Deactivate auto-approve for a session. Called when Claude Code
    /// sends PermissionRequest despite a setMode mode being active,
    /// indicating the session's permission mode changed away from the
    /// hook-controlled mode (e.g., user toggled mode in CLI).
    func deactivateAutoApprove(sessionId: String) {
        guard autoApproveSessionId == sessionId else { return }
        if let mode = autoApproveModeSnapshot {
            pendingAutoCleanup = PendingAutoCleanup(sessionId: sessionId, mode: mode)
        }
        autoApproveSessionId = nil
        autoApproveModeSnapshot = nil
    }

    /// Toggle auto-approve for a session. Only one session at a time.
    func toggleAutoApprove(sessionId: String) {
        if autoApproveSessionId == sessionId {
            if let mode = autoApproveModeSnapshot {
                pendingAutoCleanup = PendingAutoCleanup(sessionId: sessionId, mode: mode)
            }
            autoApproveSessionId = nil
            autoApproveModeSnapshot = nil
        } else {
            if let previousId = autoApproveSessionId, previousId != sessionId {
                log.info("Switching auto-approve from \(previousId) to \(sessionId). Previous session remains in CLI bypass mode.")
            }
            autoApproveSessionId = sessionId
            autoApproveModeSnapshot = SettingsManager.shared.autoApproveMode
            if pendingAutoCleanup?.sessionId == sessionId {
                pendingAutoCleanup = nil
            }
            flushPendingPermissionsForAutoApprove(sessionId: sessionId)
        }
    }

    /// Auto-approve all pending queued permissions for a session.
    func flushPendingPermissionsForAutoApprove(sessionId: String) {
        let isClaudeCode = sessions[sessionId]?.isClaude == true

        var didFlush = false
        while let idx = permissionQueue.firstIndex(where: { $0.event.sessionId == sessionId }) {
            let pending = permissionQueue.remove(at: idx)
            let data: Data
            if isClaudeCode {
                data = autoApproveInitialResponse(for: sessionId)
            } else {
                data = Self.allowResponseData(for: pending.event)
            }
            pending.continuation.resume(returning: data)
            didFlush = true
        }
        if didFlush {
            sessions[sessionId]?.status = .running
            showNextPending()
            refreshDerivedState()
        }
    }

    /// All built-in tool names for addRules-based auto-approve.
    /// Only covers known internal tools; MCP tools (mcp__server__tool) require manual approval.
    static let autoApproveToolNames = [
        "Bash", "Edit", "MultiEdit", "Write", "Read", "Glob", "Grep",
        "NotebookEdit", "WebSearch", "WebFetch",
        "Agent", "Skill",
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop",
        "TodoRead", "TodoWrite", "EnterPlanMode", "ExitPlanMode",
    ]

    /// Resolve the legacy hook response mode from the current upstream fact.
    ///
    /// `observedPermissionMode` used to be a fork-owned peak-memory field on
    /// `SessionSnapshot`. It is intentionally not read here: only the current
    /// CLI `permissionMode` may influence this compatibility response path.
    func effectiveAutoApproveMode(for sessionId: String?) -> AutoApproveMode {
        guard let sid = sessionId,
              let observed = sessions[sid]?.permissionMode else {
            return SettingsManager.shared.autoApproveMode
        }
        switch observed {
        case "bypassPermissions": return .bypassPermissions
        case "auto": return .auto
        default: return SettingsManager.shared.autoApproveMode
        }
    }

    /// Generate the initial AUTO response based on the selected mode.
    ///
    /// - auto: Claude Code's native Auto Mode. Only sends `setMode auto`.
    /// - addRules: Switches to `acceptEdits` + tool-name whitelist rules.
    /// - bypassPermissions: `bypassPermissions` + whitelist (needs --dangerously-skip-permissions).
    @MainActor
    func autoApproveInitialResponse(for sessionId: String? = nil) -> Data {
        let mode = effectiveAutoApproveMode(for: sessionId)
        switch mode {
        case .auto:
            return Self.permissionAllowResponse(updatedPermissions: [
                ["type": "setMode", "mode": "auto", "destination": "session"],
            ])
        case .addRules:
            return Self.permissionAllowResponse(updatedPermissions: [
                [
                    "type": "setMode",
                    "mode": "acceptEdits",
                    "destination": "session",
                ],
                [
                    "type": "addRules",
                    "rules": Self.autoApproveToolNames.map { ["toolName": $0, "ruleContent": "*"] },
                    "behavior": "allow",
                    "destination": "session",
                ],
            ])
        case .bypassPermissions:
            return Self.permissionAllowResponse(updatedPermissions: [
                [
                    "type": "setMode",
                    "mode": "bypassPermissions",
                    "destination": "session",
                ],
                [
                    "type": "addRules",
                    "rules": Self.autoApproveToolNames.map { ["toolName": $0, "ruleContent": "*"] },
                    "behavior": "allow",
                    "destination": "session",
                ],
            ])
        }
    }
}
