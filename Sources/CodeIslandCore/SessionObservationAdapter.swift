import Foundation

/// Provider capability compilation is kept at the observation boundary. The
/// Center receives typed capabilities and never switches on provider strings.
/// The default is conservative about the control channel: a provider must be
/// wired to an independent Auto adapter before callers opt into it.
public struct ProviderCapabilityCompiler: Sendable {
    public init() {}

    public func compile(
        provider: ProviderID,
        independentControlChannel: Bool = false,
        questionActions: Set<QuestionResolutionAction> = [],
        canNeutralFinalize: Bool = false
    ) -> ProviderCapabilities {
        capabilities(for: provider, independentControlChannel: independentControlChannel,
                     questionActions: questionActions, canNeutralFinalize: canNeutralFinalize)
    }

    public func autoCapabilities(
        for provider: ProviderID,
        independentControlChannel: Bool = false
    ) -> AutoCapabilities {
        capabilities(for: provider, independentControlChannel: independentControlChannel).auto
    }

    public func capabilities(
        for provider: ProviderID,
        independentControlChannel: Bool = false,
        questionActions: Set<QuestionResolutionAction> = [],
        canNeutralFinalize: Bool = false
    ) -> ProviderCapabilities {
        let auto: AutoCapabilities
        switch provider.rawValue {
        case "claude":
            auto = AutoCapabilities(
                nativeAuto: true,
                acceptEditsRules: true,
                explicitBypass: true,
                independentControlChannel: independentControlChannel
            )
        default:
            auto = AutoCapabilities(independentControlChannel: independentControlChannel)
        }
        return ProviderCapabilities(auto: auto, questionActions: questionActions, canNeutralFinalize: canNeutralFinalize)
    }

    public func capabilities(
        for provider: String,
        independentControlChannel: Bool = false,
        questionActions: Set<QuestionResolutionAction> = [],
        canNeutralFinalize: Bool = false
    ) -> ProviderCapabilities {
        capabilities(
            for: ProviderID(provider),
            independentControlChannel: independentControlChannel,
            questionActions: questionActions,
            canNeutralFinalize: canNeutralFinalize
        )
    }
}

public typealias AutoCapabilityCompiler = ProviderCapabilityCompiler

/// The one mapper from upstream `SessionSnapshot` facts to the Center's typed
/// observation envelope. It deliberately does not expose `SessionSnapshot` to
/// consumers and never reads the fork-owned observed-permission history.
@MainActor
public final class SessionObservationAdapter {
    private let generationAuthority: any SessionGenerationAuthority
    private let capabilityCompiler: ProviderCapabilityCompiler
    private var lastRevision: [SessionKey: UInt64] = [:]

    public init(
        generationAuthority: any SessionGenerationAuthority,
        capabilityCompiler: ProviderCapabilityCompiler = ProviderCapabilityCompiler()
    ) {
        self.generationAuthority = generationAuthority
        self.capabilityCompiler = capabilityCompiler
    }

    /// Maps a snapshot after obtaining its generation from the shared authority.
    /// Returning nil means the identity is not yet open, is stale, or repeats an
    /// already-applied revision. No partial display/navigation update is emitted.
    public func map(
        snapshot: SessionSnapshot,
        sessionID: String,
        sequence: UInt64,
        revision: UInt64,
        lifecycle: UpstreamSessionLifecycle? = nil,
        visibility: CLIVisibility = .unknown,
        capabilities: ProviderCapabilities? = nil,
        completion: CompletionObservation? = nil,
        observedAt: Date = Date()
    ) -> SessionObservation? {
        let key = SessionKey(
            provider: ProviderID(snapshot.source),
            providerSessionID: snapshot.providerSessionId ?? sessionID
        )
        let resolvedLifecycle = lifecycle ?? lifecycleForStatus(snapshot.status)
        let ref: SessionRef
        if let current = generationAuthority.current(for: key) {
            if generationAuthority.isCurrent(current) {
                let evidence: SessionGenerationEvidence = resolvedLifecycle == .closed ? .providerClose : .providerObservation
                let identityLifecycle: SessionLifecycleFact = resolvedLifecycle == .closed ? .closed(.providerClosed) : .observed
                ref = generationAuthority.apply(SessionIdentityFact(
                    session: current,
                    lifecycle: identityLifecycle,
                    evidence: evidence,
                    sequence: sequence
                ))
            } else {
                // A closed generation may only be replaced by an explicit reopen.
                // A regular discovery observation must not resurrect it.
                return nil
            }
        } else {
            guard resolvedLifecycle != .closed else { return nil }
            ref = generationAuthority.apply(SessionIdentityFact(
                key: key,
                lifecycle: .opened,
                evidence: .initialOpen,
                sequence: sequence
            ))
        }

        guard revision > (lastRevision[key] ?? 0) else { return nil }
        lastRevision[key] = revision

        let display = SessionDisplayObservation(session: ref, facts: displayFacts(from: snapshot, providerSessionID: key.providerSessionID))
        let navigation = SessionNavigationObservation(
            session: ref,
            context: navigationContext(from: snapshot),
            route: routeFact(from: snapshot),
            providerSessionID: key.providerSessionID,
            remote: remoteFact(from: snapshot)
        )
        let compiledCapabilities = capabilities
            ?? capabilityCompiler.capabilities(for: key.provider)
        let completionForSession = completion.flatMap { $0.session == ref ? $0 : nil }
        return SessionObservation(
            session: ref,
            lifecycle: resolvedLifecycle,
            permissionMode: observedPermissionMode(from: snapshot.permissionMode),
            providerCapabilities: compiledCapabilities,
            display: display,
            navigation: navigation,
            cliVisibility: visibility,
            completion: completionForSession,
            revision: revision,
            observedAt: observedAt
        )
    }

    public func observe(
        snapshot: SessionSnapshot,
        sessionID: String,
        sequence: UInt64,
        revision: UInt64,
        lifecycle: UpstreamSessionLifecycle? = nil,
        visibility: CLIVisibility = .unknown,
        capabilities: ProviderCapabilities? = nil,
        completion: CompletionObservation? = nil,
        observedAt: Date = Date()
    ) -> SessionObservation? {
        map(snapshot: snapshot, sessionID: sessionID, sequence: sequence, revision: revision,
            lifecycle: lifecycle, visibility: visibility, capabilities: capabilities,
            completion: completion, observedAt: observedAt)
    }

    /// Explicit reopen is the only path that creates a new generation after a
    /// provider close. Callers still use `map` for all ordinary observations.
    public func reopen(
        snapshot: SessionSnapshot,
        sessionID: String,
        sequence: UInt64,
        revision: UInt64,
        visibility: CLIVisibility = .unknown,
        capabilities: ProviderCapabilities? = nil,
        observedAt: Date = Date()
    ) -> SessionObservation? {
        let key = SessionKey(provider: ProviderID(snapshot.source), providerSessionID: snapshot.providerSessionId ?? sessionID)
        guard let current = generationAuthority.current(for: key), !generationAuthority.isCurrent(current) else {
            return map(snapshot: snapshot, sessionID: sessionID, sequence: sequence, revision: revision,
                       lifecycle: .active, visibility: visibility, capabilities: capabilities, observedAt: observedAt)
        }
        let ref = generationAuthority.apply(SessionIdentityFact(
            key: key,
            lifecycle: .opened,
            evidence: .explicitReopen,
            sequence: sequence
        ))
        guard generationAuthority.isCurrent(ref), revision > (lastRevision[key] ?? 0) else { return nil }
        lastRevision[key] = revision
        let display = SessionDisplayObservation(session: ref, facts: displayFacts(from: snapshot, providerSessionID: key.providerSessionID))
        let navigation = SessionNavigationObservation(session: ref, context: navigationContext(from: snapshot),
                                                       route: routeFact(from: snapshot), providerSessionID: key.providerSessionID,
                                                       remote: remoteFact(from: snapshot))
        return SessionObservation(session: ref, lifecycle: lifecycleForStatus(snapshot.status),
                                  permissionMode: observedPermissionMode(from: snapshot.permissionMode),
                                  providerCapabilities: capabilities ?? capabilityCompiler.capabilities(for: key.provider),
                                  display: display, navigation: navigation, cliVisibility: visibility,
                                  revision: revision, observedAt: observedAt)
    }

    public func resetRevision(for key: SessionKey) {
        lastRevision.removeValue(forKey: key)
    }

    private func lifecycleForStatus(_ status: AgentStatus) -> UpstreamSessionLifecycle {
        switch status {
        case .idle: return .idle
        case .waitingApproval, .waitingQuestion: return .waiting
        case .processing, .running: return .active
        }
    }

    private func observedPermissionMode(from value: String?) -> ObservedPermissionMode {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unknown(nil) }
        switch value {
        case "default", "normal": return .defaultMode
        case "auto": return .auto
        case "acceptEdits": return .acceptEdits
        case "bypassPermissions": return .bypassPermissions
        default: return .unknown(value)
        }
    }

    private func displayFacts(from snapshot: SessionSnapshot, providerSessionID: String) -> SessionDisplayFacts {
        let subagents = snapshot.subagents.values.sorted { $0.agentId < $1.agentId }.map {
            SubagentDisplayFact(id: $0.agentId, title: $0.agentType, status: statusString($0.status))
        }
        let recentMessages = snapshot.recentMessages.map {
            RecentMessageFact(role: $0.isUser ? .user : .assistant, preview: SensitiveText($0.text))
        }
        return SessionDisplayFacts(
            title: snapshot.sessionLabel,
            project: snapshot.projectDisplayName,
            source: snapshot.source,
            cwd: snapshot.cwd,
            model: snapshot.model,
            status: statusString(snapshot.status),
            currentTool: snapshot.currentTool,
            toolDescription: snapshot.toolDescription,
            subagents: subagents,
            recentMessages: recentMessages,
            git: snapshot.gitBranch == nil && !snapshot.gitIsWorktree ? nil : GitDisplayFact(branch: snapshot.gitBranch, isWorktree: snapshot.gitIsWorktree),
            providerSessionID: providerSessionID,
            remote: remoteFact(from: snapshot)
        )
    }

    private func navigationContext(from snapshot: SessionSnapshot) -> NavigationContext {
        if let hostID = snapshot.remoteHostId, !hostID.isEmpty {
            return NavigationContext(terminal: .remote(hostID: hostID), isRemote: true)
        }
        let bundleID = snapshot.termBundleId ?? snapshot.termApp
        let hasRoute = bundleID != nil || snapshot.ttyPath != nil || snapshot.itermSessionId != nil
            || snapshot.kittyWindowId != nil || snapshot.tmuxPane != nil || snapshot.cmuxSurfaceId != nil
            || snapshot.zellijPaneId != nil || snapshot.weztermPaneId != nil || snapshot.supersetPaneId != nil
            || snapshot.orcaTerminalHandle != nil
        guard hasRoute else { return NavigationContext() }
        return NavigationContext(terminal: .local(bundleID: bundleID ?? "terminal"), isRemote: false)
    }

    private func routeFact(from snapshot: SessionSnapshot) -> TerminalRouteFact {
        TerminalRouteFact(
            termApp: snapshot.termApp,
            itermSessionID: snapshot.itermSessionId,
            ttyPath: snapshot.ttyPath,
            kittyWindowID: snapshot.kittyWindowId,
            tmuxPane: snapshot.tmuxPane,
            tmuxClientTTY: snapshot.tmuxClientTty,
            tmuxEnvironment: snapshot.tmuxEnv,
            termBundleID: snapshot.termBundleId,
            cmuxSurfaceID: snapshot.cmuxSurfaceId,
            cmuxWorkspaceID: snapshot.cmuxWorkspaceId,
            zellijPaneID: snapshot.zellijPaneId,
            zellijSessionName: snapshot.zellijSessionName,
            weztermPaneID: snapshot.weztermPaneId,
            supersetWorkspaceID: snapshot.supersetWorkspaceId,
            supersetPaneID: snapshot.supersetPaneId,
            orcaTerminalHandle: snapshot.orcaTerminalHandle,
            orcaWorktreeID: snapshot.orcaWorktreeId,
            cliPID: snapshot.cliPid,
            cliStartTime: snapshot.cliStartTime
        )
    }

    private func remoteFact(from snapshot: SessionSnapshot) -> RemoteDisplayFact? {
        guard let hostID = snapshot.remoteHostId, !hostID.isEmpty else { return nil }
        return RemoteDisplayFact(hostID: hostID, hostName: snapshot.remoteDisplayName)
    }

    private func statusString(_ status: AgentStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .processing: return "processing"
        case .running: return "running"
        case .waitingApproval: return "waitingApproval"
        case .waitingQuestion: return "waitingQuestion"
        }
    }
}
