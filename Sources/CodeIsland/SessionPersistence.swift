import Foundation
import CodeIslandCore

struct PersistedSession: Codable {
    let sessionId: String
    let cwd: String?
    let source: String
    let model: String?
    let sessionTitle: String?
    let sessionTitleSource: SessionTitleSource?
    let providerSessionId: String?
    let lastUserPrompt: String?
    let lastAssistantMessage: String?
    let termApp: String?
    let itermSessionId: String?
    let ttyPath: String?
    let kittyWindowId: String?
    let tmuxPane: String?
    let tmuxClientTty: String?
    let tmuxEnv: String?
    let termBundleId: String?
    // Multiplexer / fork pane hints — preserved across launches so precise jump-back
    // (cmux focus-panel / zellij go-to-tab / wezterm activate-pane) keeps working
    // after an app restart instead of degrading to cwd/tty fallback.
    let cmuxSurfaceId: String?
    let cmuxWorkspaceId: String?
    let zellijPaneId: String?
    let zellijSessionName: String?
    let weztermPaneId: String?
    let herdrPaneId: String?
    let herdrSocketPath: String?
    let herdrBinaryPath: String?
    let cliPid: Int32?
    let cliStartTime: Date?
    let startTime: Date
    let lastActivity: Date
    /// Absolute JSONL path for session fold and transcript tailing.
    let transcriptPath: String?
    /// Closed subagent ids in insertion order (newest last). Legacy files may
    /// still hold a lexicographically sorted list from the pre-cap `Set.sorted()`
    /// encoder — restore keeps all entries (no fake-recency trim).
    let closedSubagentIds: [String]?
    /// The agent's checklist, so a relaunch mid-plan keeps showing progress
    /// before the transcript backfill finishes. nil when empty (and in files
    /// written before the field existed).
    var agentTasks: AgentTaskList? = nil
    // Session recap + reasoning effort. Defaulted so older files (and call
    // sites) without them keep decoding/compiling; restore is re-checked
    // against the transcript by the attach-time backfill.
    var recap: SessionRecap? = nil
    var reasoningEffort: String? = nil
    /// Legacy fork Auto-mode persistence slot. The pre-cutover value is decoded
    /// and discarded below and never re-encoded, so it cannot re-enter the
    /// runtime after a relaunch.
    let observedPermissionMode: String? = nil
}

extension PersistedSession {
    /// Explicit Codable over the full v1.0.35 field set. Accepts the
    /// pre-cutover fork Auto key without allowing the fork-owned Auto mode to
    /// re-enter the runtime. The key is intentionally omitted on every encode.
    enum CodingKeys: String, CodingKey {
        case sessionId, cwd, source, model, sessionTitle, sessionTitleSource
        case providerSessionId, lastUserPrompt, lastAssistantMessage, termApp
        case itermSessionId, ttyPath, kittyWindowId, tmuxPane, tmuxClientTty
        case tmuxEnv, termBundleId, cmuxSurfaceId, cmuxWorkspaceId, zellijPaneId
        case zellijSessionName, weztermPaneId, herdrPaneId, herdrSocketPath
        case herdrBinaryPath, cliPid, cliStartTime, startTime
        case lastActivity, transcriptPath, closedSubagentIds, observedPermissionMode
        case agentTasks, recap, reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        source = try c.decode(String.self, forKey: .source)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        sessionTitle = try c.decodeIfPresent(String.self, forKey: .sessionTitle)
        sessionTitleSource = try c.decodeIfPresent(SessionTitleSource.self, forKey: .sessionTitleSource)
        providerSessionId = try c.decodeIfPresent(String.self, forKey: .providerSessionId)
        lastUserPrompt = try c.decodeIfPresent(String.self, forKey: .lastUserPrompt)
        lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        termApp = try c.decodeIfPresent(String.self, forKey: .termApp)
        itermSessionId = try c.decodeIfPresent(String.self, forKey: .itermSessionId)
        ttyPath = try c.decodeIfPresent(String.self, forKey: .ttyPath)
        kittyWindowId = try c.decodeIfPresent(String.self, forKey: .kittyWindowId)
        tmuxPane = try c.decodeIfPresent(String.self, forKey: .tmuxPane)
        tmuxClientTty = try c.decodeIfPresent(String.self, forKey: .tmuxClientTty)
        tmuxEnv = try c.decodeIfPresent(String.self, forKey: .tmuxEnv)
        termBundleId = try c.decodeIfPresent(String.self, forKey: .termBundleId)
        cmuxSurfaceId = try c.decodeIfPresent(String.self, forKey: .cmuxSurfaceId)
        cmuxWorkspaceId = try c.decodeIfPresent(String.self, forKey: .cmuxWorkspaceId)
        zellijPaneId = try c.decodeIfPresent(String.self, forKey: .zellijPaneId)
        zellijSessionName = try c.decodeIfPresent(String.self, forKey: .zellijSessionName)
        weztermPaneId = try c.decodeIfPresent(String.self, forKey: .weztermPaneId)
        herdrPaneId = try c.decodeIfPresent(String.self, forKey: .herdrPaneId)
        herdrSocketPath = try c.decodeIfPresent(String.self, forKey: .herdrSocketPath)
        herdrBinaryPath = try c.decodeIfPresent(String.self, forKey: .herdrBinaryPath)
        cliPid = try c.decodeIfPresent(Int32.self, forKey: .cliPid)
        cliStartTime = try c.decodeIfPresent(Date.self, forKey: .cliStartTime)
        startTime = try c.decode(Date.self, forKey: .startTime)
        lastActivity = try c.decode(Date.self, forKey: .lastActivity)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        closedSubagentIds = try c.decodeIfPresent([String].self, forKey: .closedSubagentIds)
        agentTasks = try c.decodeIfPresent(AgentTaskList.self, forKey: .agentTasks)
        recap = try c.decodeIfPresent(SessionRecap.self, forKey: .recap)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        // Decode and discard the pre-cutover fork-owned Auto field.
        _ = try c.decodeIfPresent(String.self, forKey: .observedPermissionMode)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(sessionTitle, forKey: .sessionTitle)
        try c.encodeIfPresent(sessionTitleSource, forKey: .sessionTitleSource)
        try c.encodeIfPresent(providerSessionId, forKey: .providerSessionId)
        try c.encodeIfPresent(lastUserPrompt, forKey: .lastUserPrompt)
        try c.encodeIfPresent(lastAssistantMessage, forKey: .lastAssistantMessage)
        try c.encodeIfPresent(termApp, forKey: .termApp)
        try c.encodeIfPresent(itermSessionId, forKey: .itermSessionId)
        try c.encodeIfPresent(ttyPath, forKey: .ttyPath)
        try c.encodeIfPresent(kittyWindowId, forKey: .kittyWindowId)
        try c.encodeIfPresent(tmuxPane, forKey: .tmuxPane)
        try c.encodeIfPresent(tmuxClientTty, forKey: .tmuxClientTty)
        try c.encodeIfPresent(tmuxEnv, forKey: .tmuxEnv)
        try c.encodeIfPresent(termBundleId, forKey: .termBundleId)
        try c.encodeIfPresent(cmuxSurfaceId, forKey: .cmuxSurfaceId)
        try c.encodeIfPresent(cmuxWorkspaceId, forKey: .cmuxWorkspaceId)
        try c.encodeIfPresent(zellijPaneId, forKey: .zellijPaneId)
        try c.encodeIfPresent(zellijSessionName, forKey: .zellijSessionName)
        try c.encodeIfPresent(weztermPaneId, forKey: .weztermPaneId)
        try c.encodeIfPresent(herdrPaneId, forKey: .herdrPaneId)
        try c.encodeIfPresent(herdrSocketPath, forKey: .herdrSocketPath)
        try c.encodeIfPresent(herdrBinaryPath, forKey: .herdrBinaryPath)
        try c.encodeIfPresent(cliPid, forKey: .cliPid)
        try c.encodeIfPresent(cliStartTime, forKey: .cliStartTime)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(lastActivity, forKey: .lastActivity)
        try c.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try c.encodeIfPresent(closedSubagentIds, forKey: .closedSubagentIds)
        try c.encodeIfPresent(agentTasks, forKey: .agentTasks)
        try c.encodeIfPresent(recap, forKey: .recap)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    }
}

enum SessionPersistence {
    static let dirPath = directory(
        environment: ProcessInfo.processInfo.environment,
        isRunningTests: RuntimeEnvironment.isRunningTests
    )
    private static let filePath = dirPath + "/sessions.json"

    /// Where sessions.json lives: `~/.codeisland`, unless `CODEISLAND_SESSIONS_DIR`
    /// names another folder (as `CODEISLAND_SOCKET_PATH` does for the socket).
    /// A test process defaults to a folder of its own under the temp dir: a
    /// test's AppState used to overwrite the user's real session list from its
    /// 2 s save timer, and `startSessionDiscovery` restored it into the test and
    /// then deleted it.
    static func directory(
        environment: [String: String],
        isRunningTests: Bool,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let override = environment["CODEISLAND_SESSIONS_DIR"], !override.isEmpty {
            return override
        }
        if isRunningTests {
            return (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("codeisland-tests-\(getpid())")
        }
        return home + "/.codeisland"
    }

    /// Whether a card is written out for the next launch. Not a remote one,
    /// and not a Claude Desktop Cowork card: those are rebuilt from Claude
    /// Desktop's own store and vouched for by it at launch, and a CodeIsland
    /// that cannot read the store (an older build after a downgrade) would
    /// bring one back as a ghost Claude Code session.
    static func isPersisted(sessionId: String, session: SessionSnapshot) -> Bool {
        !session.isRemote && !sessionId.hasPrefix(AppState.coworkSessionPrefix)
    }

    static func save(_ sessions: [String: SessionSnapshot]) {
        let persisted: [PersistedSession] = sessions.compactMap { (id, s) in
            guard isPersisted(sessionId: id, session: s) else { return nil }
            return PersistedSession(
                sessionId: id,
                cwd: s.cwd,
                source: s.source,
                model: s.model,
                sessionTitle: s.sessionTitle,
                sessionTitleSource: s.sessionTitleSource,
                providerSessionId: s.providerSessionId,
                lastUserPrompt: s.lastUserPrompt,
                lastAssistantMessage: s.lastAssistantMessage,
                termApp: s.termApp,
                itermSessionId: s.itermSessionId,
                ttyPath: s.ttyPath,
                kittyWindowId: s.kittyWindowId,
                tmuxPane: s.tmuxPane,
                tmuxClientTty: s.tmuxClientTty,
                tmuxEnv: s.tmuxEnv,
                termBundleId: s.termBundleId,
                cmuxSurfaceId: s.cmuxSurfaceId,
                cmuxWorkspaceId: s.cmuxWorkspaceId,
                zellijPaneId: s.zellijPaneId,
                zellijSessionName: s.zellijSessionName,
                weztermPaneId: s.weztermPaneId,
                herdrPaneId: s.herdrPaneId,
                herdrSocketPath: s.herdrSocketPath,
                herdrBinaryPath: s.herdrBinaryPath,
                cliPid: s.cliPid,
                cliStartTime: s.cliStartTime,
                startTime: s.startTime,
                lastActivity: s.lastActivity,
                transcriptPath: s.transcriptPath,
                closedSubagentIds: s.closedSubagentIds.isEmpty ? nil : s.closedSubagentIds,
                agentTasks: s.agentTasks.isEmpty ? nil : s.agentTasks,
                recap: s.recap,
                reasoningEffort: s.reasoningEffort
            )
        }
        do {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: URL(fileURLWithPath: filePath), options: Data.WritingOptions.atomic)
        } catch {}
    }

    static func load() -> [PersistedSession] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }
        return decode(data)
    }

    /// Decode a sessions file entry by entry: one this build cannot read (a
    /// newer version's field values after a downgrade, a hand edit) costs that
    /// session, not every session in the file.
    static func decode(_ data: Data) -> [PersistedSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? decoder.decode([LossyPersistedSession].self, from: data)) ?? []
        return entries.compactMap(\.session)
    }

    private struct LossyPersistedSession: Decodable {
        let session: PersistedSession?

        init(from decoder: Decoder) throws {
            session = try? PersistedSession(from: decoder)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
