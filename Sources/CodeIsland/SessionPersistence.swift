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
}

extension PersistedSession {
    /// Accept the pre-cutover key without allowing the fork-owned Auto mode to
    /// re-enter the runtime. The key is intentionally omitted on every encode.
    enum CodingKeys: String, CodingKey {
        case sessionId, cwd, source, model, sessionTitle, sessionTitleSource
        case providerSessionId, lastUserPrompt, lastAssistantMessage, termApp
        case itermSessionId, ttyPath, kittyWindowId, tmuxPane, tmuxClientTty
        case tmuxEnv, termBundleId, cmuxSurfaceId, cmuxWorkspaceId, zellijPaneId
        case zellijSessionName, weztermPaneId, cliPid, cliStartTime, startTime
        case lastActivity, transcriptPath, closedSubagentIds, observedPermissionMode
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
        cliPid = try c.decodeIfPresent(Int32.self, forKey: .cliPid)
        cliStartTime = try c.decodeIfPresent(Date.self, forKey: .cliStartTime)
        startTime = try c.decode(Date.self, forKey: .startTime)
        lastActivity = try c.decode(Date.self, forKey: .lastActivity)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        closedSubagentIds = try c.decodeIfPresent([String].self, forKey: .closedSubagentIds)
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
        try c.encodeIfPresent(cliPid, forKey: .cliPid)
        try c.encodeIfPresent(cliStartTime, forKey: .cliStartTime)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(lastActivity, forKey: .lastActivity)
        try c.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try c.encodeIfPresent(closedSubagentIds, forKey: .closedSubagentIds)
    }
}

enum SessionPersistence {
    private static let dirPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.codeisland"
    private static let filePath = dirPath + "/sessions.json"

    static func save(_ sessions: [String: SessionSnapshot]) {
        let persisted: [PersistedSession] = sessions.compactMap { (id, s) in
            guard !s.isRemote else { return nil }
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
                cliPid: s.cliPid,
                cliStartTime: s.cliStartTime,
                startTime: s.startTime,
                lastActivity: s.lastActivity,
                transcriptPath: s.transcriptPath,
                closedSubagentIds: s.closedSubagentIds.isEmpty ? nil : s.closedSubagentIds
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PersistedSession].self, from: data)) ?? []
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: filePath)
    }
}
