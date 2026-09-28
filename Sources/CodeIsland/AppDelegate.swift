import AppKit
import SwiftUI
import os.log
import CodeIslandCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated private static let log = Logger(subsystem: "com.codeisland", category: "AppDelegate")

    var panelController: PanelWindowController?
    private var hookServer: HookServer?
    private var hookRecoveryTimer: Timer?
    private var lastHookCheck: Date = .distantPast
    private let hotKeyManager = GlobalHotKeyManager()
    private var localShortcutMonitor: Any?
    /// Installed by the interaction owner once upstream adapters are ready.
    /// Consumers are kept behind this single router so stale shortcuts cannot
    /// fall through to a different request's queue head.
    private var interactionRouter: InteractionUIActionRouter?
    private var interactionExecutor: InteractionProductionEffectExecutor?
    let appState = AppState()

    /// The production UI remains on the proven upstream/fork overlay until
    /// the Center renderer has visual parity. Developers can opt into the new
    /// owner graph without changing persisted user settings.
    static func interactionCenterProductionEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["CODEISLAND_INTERACTION_CENTER"] == "1"
    }

    /// Production cutover seam for Phase 6. The caller owns the Center and its
    /// one effect executor; AppDelegate only wires read-only external
    /// projection and typed input forwarding to publishers.
    func attachInteractionCoordinator(_ coordinator: InteractionCoordinator) {
        let router = InteractionUIActionRouter(coordinator: coordinator)
        interactionRouter = router
        panelController?.attachInteractionRouter(router)
        AppleCompanionPublisher.shared.attachExternalProjection(
            snapshot: { [weak router] in router?.snapshot.external ?? RedactedInteractionSnapshot() },
            send: { [weak router] input in _ = router?.send(input) }
        )
        ESP32StatePublisher.shared.attachExternalProjection(
            snapshot: { [weak router] in router?.snapshot.external ?? RedactedInteractionSnapshot() },
            send: { [weak router] input in _ = router?.send(input) }
        )
    }

    /// Builds the production interaction graph exactly once, before any hook,
    /// Codex, UI, or companion ingress is started.  The store and coordinator
    /// are retained by AppState; this owner retains the single effect executor
    /// so adapter callbacks cannot outlive the application graph.
    private func installInteractionRuntime() {
        guard interactionRouter == nil else { return }

        let ids = RandomInteractionIDFactory()
        let authority = InMemorySessionGenerationAuthority()
        let buffer = InMemoryRequestIngressBuffer(idFactory: ids)
        let transportRegistry = HookTransportRegistry()
        let hookTransport = HookTransportAdapter(registry: transportRegistry)
        let hookAdapter = HookInteractionAdapter(
            generationAuthority: authority,
            ingressBuffer: buffer,
            transportRegistry: transportRegistry,
            idFactory: ids,
            configuration: HookAdmissionConfiguration(
                defaultProvider: ProviderID("claude"),
                autoApproveTools: SettingsManager.shared.autoApproveTools,
                autoApprovedSources: SettingsManager.shared.autoApproveSources,
                safeNeutralResponse: .hookEmptyObject
            )
        )
        let sessionAdapter = SessionObservationAdapter(generationAuthority: authority)
        let autoAdapter = UnavailableAutoCommandAdapter()
        let autoController = AppStateAutoApproveController(adapter: autoAdapter)
        let codexAdapter = CodexTransportAdapter(idFactory: ids)
        let executor = InteractionProductionEffectExecutor(
            hook: hookTransport,
            codex: codexAdapter,
            auto: autoAdapter,
            navigator: .shared,
            sessionLookup: { [weak appState] ref in
                guard let appState else { return nil }
                return appState.sessionForInteraction(ref)
            }
        )
        let store = InteractionCenterStore(dependencies: InteractionCenterDependencies(
            idFactory: ids,
            generationAuthority: authority,
            ingressBuffer: buffer,
            presentationPolicy: .adaptiveCLI()
        ))
        let coordinator = InteractionCoordinator(store: store, executor: executor)

        interactionExecutor = executor
        appState.installInteractionRuntime(
            coordinator: coordinator,
            hookAdapter: hookAdapter,
            codexAdapter: codexAdapter,
            sessionAdapter: sessionAdapter,
            autoController: autoController
        )
        attachInteractionCoordinator(coordinator)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything else: the launch Apple Event that says "login
        // item" is only current during this synchronous call.
        let isLoginLaunch = LaunchContext.isCurrentLaunchAtLogin()
        ProcessInfo.processInfo.disableAutomaticTermination("CodeIsland must stay running")
        ProcessInfo.processInfo.disableSuddenTermination()
        // Pre-set app icon so Dock/menu bar use the packaged bundle icon.
        NSApp.applicationIconImage = SettingsWindowController.bundleAppIcon()
        SettingsWindowController.shared.appState = appState
        // Keep the proven hook/UI path as the production default. The Center
        // cutover is explicit until its renderer passes behavioral and visual
        // parity gates against that baseline.
        if Self.interactionCenterProductionEnabled() {
            installInteractionRuntime()
        }
        StatusItemController.shared.startObserving()
        // Start HookServer BEFORE installing hooks into CLI configs.
        // If we write settings.json first, Claude Code picks up the new hooks
        // immediately but the socket isn't listening yet — PermissionRequest
        // hooks get no response and Claude Code denies them.
        hookServer = HookServer(appState: appState)
        hookServer?.start()
        RemoteManager.shared.onDisconnect = { [weak appState] hostId in
            appState?.removeRemoteSessions(hostId: hostId)
        }

        // Prewarm the usage footer off the launch path — first panel expansion
        // then shows data immediately instead of popping in a beat later.
        Task { @MainActor [weak appState] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            appState?.refreshClaudeUsageIfStale()
        }

        // Hook installation does subprocess version detection plus disk I/O —
        // keep it off the main thread so app launch isn't blocked even when a
        // CLI binary hangs. See #139.
        Task.detached(priority: .userInitiated) {
            if ConfigInstaller.install() {
                Self.log.info("Hooks installed")
            } else {
                Self.log.warning("Failed to install hooks")
            }
        }

        // Watch system sleep/wake so the mascot animations pause and re-anchor
        // their periodic schedules instead of pinning a core after wake (#225).
        MascotAnimationGate.shared.start()
        // Lock / screen saver / display sleep → event sounds hold off.
        SceneMuteMonitor.shared.start()
        // Back at the screen: follow-ups held back meanwhile go out now.
        // Gone from it: approvals / questions a push skipped while the user
        // was still there go to the phone now.
        SceneMuteMonitor.shared.onQuietChanged = { [weak appState] isQuiet in
            if isQuiet {
                PushNotifier.shared.userLeft()
            } else {
                appState?.followUps.wake()
            }
        }
        // Follow-up reminders also reach the phone / chat push channels.
        appState.connectPushToFollowUps()

        panelController = PanelWindowController(appState: appState, interactionRouter: interactionRouter)
        panelController?.showPanel()

        appState.startSessionDiscovery()
        appState.startCodexAppServerWatcher()
        appState.startAiWorkWatcher()
        appState.startCoworkWatcher()
        RemoteManager.shared.startup()

        // Buddy bridge (opt-in): mirrors the Dynamic Island onto the companion
        // device and routes its button press back to TerminalActivator.
        ESP32StatePublisher.shared.attach(appState)
        ESP32BridgeManager.shared.onFocusRequest = { mascot in
            ESP32StatePublisher.shared.handleFocusRequest(mascot)
        }
        ESP32BridgeManager.shared.onControlCommand = { [weak appState] command in
            guard let appState else { return }
            // The hardware Buddy shows whatever is featured and has no session
            // id on the wire, so it keeps acting on the head of the queue.
            appState.handleBuddyControlCommand(command)
        }
        AppleCompanionPublisher.shared.attach(appState)
        AppleCompanionPublisher.shared.onFocusRequest = { [weak appState] mascot in
            guard let appState else { return }
            // Compatibility fallback; when the Center projection is attached
            // the publisher consumes the redacted session list instead.
            ESP32FocusCoordinator.handle(mascot: mascot, appState: appState)
        }
        AppleCompanionPublisher.shared.onControlCommand = { [weak appState] command, sessionId in
            guard let appState else { return }
            appState.handleBuddyControlCommand(command, expectedSessionId: sessionId)
        }
        AppleCompanionPublisher.shared.onQuestionAnswer = { [weak appState] answer, sessionId in
            guard let appState else { return }
            appState.answerCompanionQuestion(answer, expectedSessionId: sessionId)
        }
        let buddyEnabled = UserDefaults.standard.bool(forKey: SettingsKey.esp32BridgeEnabled)
        let buddySyncInterval = UserDefaults.standard.double(forKey: SettingsKey.esp32HeartbeatSeconds)
        let buddyBrightness = UserDefaults.standard.double(forKey: SettingsKey.buddyScreenBrightnessPercent)
        let buddyScreenOrientation = BuddyScreenOrientation(
            settingsValue: UserDefaults.standard.string(forKey: SettingsKey.buddyScreenOrientation)
        )
        ESP32StatePublisher.shared.configure(
            enabled: buddyEnabled,
            heartbeatSeconds: buddySyncInterval > 0 ? buddySyncInterval : SettingsDefaults.esp32HeartbeatSeconds,
            brightnessPercent: buddyBrightness > 0 ? buddyBrightness : SettingsDefaults.buddyScreenBrightnessPercent,
            screenOrientation: buddyScreenOrientation
        )
        let appleCompanionEnabled = UserDefaults.standard.bool(forKey: SettingsKey.appleCompanionEnabled)
        let appleCompanionHeartbeat = UserDefaults.standard.double(forKey: SettingsKey.appleCompanionHeartbeatSeconds)
        AppleCompanionPublisher.shared.configure(
            enabled: appleCompanionEnabled,
            heartbeatSeconds: appleCompanionHeartbeat > 0 ? appleCompanionHeartbeat : SettingsDefaults.appleCompanionHeartbeatSeconds
        )

        // Hooks auto-recovery: periodic + app activation trigger
        hookRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRepairHooks()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRepairHooks()
            }
        }

        #if DEBUG
        // Preview mode: inject mock data if --preview flag is present
        if let scenario = DebugHarness.requestedScenario() {
            Self.log.debug("Loading scenario: \(scenario.rawValue)")
            DebugHarness.apply(scenario, to: appState)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if appState.surface == .collapsed {
                    withAnimation(NotchAnimation.pop) {
                        appState.surface = .sessionList
                    }
                }
            }
            return
        }
        #endif

        // Sparkle runs scheduled checks itself on the cadence declared in
        // Info.plist (SUScheduledCheckInterval). Start the updater once — it
        // no-ops for Homebrew-installed builds (brew owns those upgrades).
        // Fork overlay: the switch below is off by default so self-built
        // distributions don't fire Sparkle checks against a non-existent
        // appcast. Enable via Settings to restore the upstream flow.
        if UserDefaults.standard.object(forKey: SettingsKey.sparkleAutoUpdateEnabled) as? Bool
            ?? SettingsDefaults.sparkleAutoUpdateEnabled {
            UpdateChecker.shared.start()
        }

        // The jingle confirms a launch the user just made; at login it is
        // noise on every boot for everyone with Launch at Login on.
        if isLoginLaunch {
            Self.log.info("Launched at login — skipping boot sound")
        } else {
            SoundManager.shared.playBoot()
        }
        setupGlobalShortcut()

        // Boot animation: brief expand to confirm app is running
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard appState.surface == .collapsed else { return }
            withAnimation(NotchAnimation.pop) {
                appState.surface = .sessionList
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .sessionList = appState.surface {
                withAnimation(NotchAnimation.close) {
                    appState.surface = .collapsed
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookRecoveryTimer?.invalidate()
        teardownGlobalShortcut()
        appState.saveSessions()
        RemoteManager.shared.shutdown()
        hookServer?.stop()
        appState.stopCodexAppServerWatcher()
        appState.stopAiWorkWatcher()
        appState.stopSessionDiscovery()
    }

    // MARK: - Global Shortcuts

    func setupGlobalShortcut() {
        teardownGlobalShortcut()

        // Collect all enabled shortcut bindings, skip duplicates (first wins)
        var bindings: [(keyCode: UInt16, mods: NSEvent.ModifierFlags, action: ShortcutAction)] = []
        var seen: Set<String> = []
        for action in ShortcutAction.allCases {
            guard action.isEnabled else { continue }
            let b = action.binding
            let key = "\(b.keyCode)-\(b.modifiers.rawValue)"
            guard seen.insert(key).inserted else { continue }
            bindings.append((b.keyCode, b.modifiers, action))
        }
        guard !bindings.isEmpty else { return }

        // Global path: Carbon RegisterEventHotKey fires from any frontmost app
        // and — unlike an NSEvent global keyboard monitor — needs no
        // Accessibility permission. This is the primary handler. See #217.
        for b in bindings {
            hotKeyManager.register(keyCode: b.keyCode, modifiers: b.mods) { [weak self] in
                Task { @MainActor in self?.executeShortcut(b.action) }
            }
        }

        // Local monitor: same-app fallback so the shortcut still works (and is
        // swallowed) while CodeIsland's own panel/settings window is focused.
        let localHandler: (NSEvent) -> Bool = { [weak self] event in
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            for b in bindings where event.keyCode == b.keyCode && eventMods == b.mods {
                Task { @MainActor in self?.executeShortcut(b.action) }
                return true
            }
            return false
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            localHandler(event) ? nil : event
        }
    }

    private func teardownGlobalShortcut() {
        hotKeyManager.unregisterAll()
        if let m = localShortcutMonitor { NSEvent.removeMonitor(m) }
        localShortcutMonitor = nil
    }

    private func executeShortcut(_ action: ShortcutAction) {
        if let interactionRouter {
            switch action {
            case .togglePanel:
                break
            case .jumpToTerminal:
                guard let requestID = interactionRouter.snapshot.local.presentation.prominentRequest,
                      let request = interactionRouter.snapshot.local.requests[requestID] else { return }
                _ = interactionRouter.navigate(.session(request.session))
            case .approve:
                _ = interactionRouter.perform(.allowOnce)
            case .approveAlways:
                _ = interactionRouter.perform(.allowAlways)
            case .deny:
                _ = interactionRouter.perform(.deny)
            case .skipQuestion:
                _ = interactionRouter.perform(.skipQuestion)
            }
            if case .togglePanel = action {
                // Panel presentation remains an AppKit/UI concern.
            } else {
                return
            }
        }

        switch action {
        case .togglePanel:
            if appState.surface.isExpanded {
                withAnimation(NotchAnimation.close) { appState.surface = .collapsed }
            } else {
                withAnimation(NotchAnimation.open) {
                    appState.surface = .sessionList
                    appState.cancelCompletionQueue()
                    if appState.activeSessionId == nil {
                        appState.activeSessionId = appState.sessions.keys.sorted().first
                    }
                }
            }
        // Card shortcuts act only on the card on screen (#308); with the
        // request hidden they open its card instead of acting unseen.
        case .approve, .approveAlways, .deny, .skipQuestion:
            appState.performCardShortcut(action)
        case .jumpToTerminal:
            if let id = appState.activeSessionId, let session = appState.sessions[id] {
                TerminalActivator.activate(session: session, sessionId: id)
            }
        }
    }

    private func checkAndRepairHooks() {
        guard Date().timeIntervalSince(lastHookCheck) > 60 else { return }
        lastHookCheck = Date()
        // verifyAndRepair walks every enabled CLI and rewrites settings on
        // disk — keep it off the main thread so the activation observer (fires
        // on every app switch) can't stutter the UI. See #139.
        Task.detached(priority: .background) {
            let repaired = ConfigInstaller.verifyAndRepair()
            if !repaired.isEmpty {
                Self.log.info("Auto-repaired hooks for: \(repaired.joined(separator: ", "))")
            }
        }
    }

}
