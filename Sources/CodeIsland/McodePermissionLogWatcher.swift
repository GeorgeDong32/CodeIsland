import Foundation

/// Side-channel watcher for MiniMax Code (mcode) permission prompts.
///
/// mcode 0.5.5 does NOT dispatch `PermissionRequest` to plugin hooks for
/// interactive TUI asks (verified empirically — tool hooks fire, permission
/// asks go straight to the TUI dialog via `channel_dispatch`). Its runtime
/// observability log, however, records the full permission lifecycle:
///
///     [00:15:26.825] INFO: [] permission.ask       {"request_id":…,"session_id":"mvs_…","tool_name":"bash",…}
///     [00:16:22.451] INFO: [] permission.resolved  {"request_id":…,"session_id":"mvs_…","decision":"allowOnce"}
///     [00:16:22.451] INFO: [] permission.processed {"request_id":…,"session_id":"mvs_…,"tool_name":"bash",…}
///
/// Tail those lines and surface a DISPLAY-ONLY waitingApproval on the card:
/// the island cannot approve/deny (the user answers in the TUI), but the
/// card explains why the session paused and offers the terminal jump.
final class McodePermissionLogWatcher: @unchecked Sendable {

    enum Event: Sendable, Equatable {
        /// A permission dialog appeared for `toolName`.
        case ask(requestId: String, sessionId: String, toolName: String)
        /// The dialog was answered (allowOnce / deny / …) or dismissed.
        case resolved(requestId: String, sessionId: String)
        /// Command detail from the checker line immediately before an ask.
        case command(sessionId: String, command: String)
    }

    private let queue = DispatchQueue(label: "codeisland.mcode-perm-watch", qos: .utility)
    private var timer: Timer?
    private let onEvents: @Sendable ([Event]) -> Void

    /// Current tail position: (file name, byte offset, partial line carry).
    private var currentFile: String?
    private var offset: UInt64 = 0
    private var carry = ""

    private var logDir: String {
        if let override = ProcessInfo.processInfo.environment["MINIMAX_DATA_DIR"], !override.isEmpty {
            return override + "/v2/observability/logs"
        }
        return NSHomeDirectory() + "/.minimax/v2/observability/logs"
    }

    init(onEvents: @escaping @Sendable ([Event]) -> Void) {
        self.onEvents = onEvents
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.pollOnce() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.async { [self] in
            currentFile = nil
            offset = 0
            carry = ""
        }
    }

    // MARK: - Tail

    private func pollOnce() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logDir) else { return }
        let logs = names.filter { $0.hasPrefix("runtime-") && $0.hasSuffix(".log") }.sorted()
        guard let newest = logs.last else { return }
        let path = logDir + "/" + newest

        if newest != currentFile {
            // Hourly rollover (or first poll): read the new bucket from the top.
            currentFile = newest
            offset = 0
            carry = ""
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        if size < offset { offset = 0; carry = "" }   // truncated/rotated content
        guard size > offset else { return }
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        guard let text = String(data: data, encoding: .utf8) else { return }

        var events: [Event] = []
        var stream = carry + text
        // Only parse up to the last complete line; keep the remainder.
        if let lastNewline = stream.lastIndex(of: "\n") {
            carry = String(stream[stream.index(after: lastNewline)...])
            stream = String(stream[stream.startIndex..<lastNewline])
        } else {
            carry = stream
            stream = ""
        }
        for line in stream.components(separatedBy: "\n") {
            if let event = Self.parse(line: line) {
                events.append(event)
            }
        }
        if !events.isEmpty {
            onEvents(events)
        }
    }

    // MARK: - Line parsing (pure — unit tested)

    /// One observability line → one event. Lines look like
    /// `[00:15:26.825] INFO: [] permission.ask {"request_id":"perm_…",…}`.
    static func parse(line: String) -> Event? {
        func payload(after marker: String) -> [String: Any]? {
            guard let range = line.range(of: marker) else { return nil }
            let jsonText = String(line[range.upperBound...])
            guard let data = jsonText.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            return object
        }
        func sid(_ p: [String: Any]) -> String? {
            (p["session_id"] as? String).flatMap { $0.hasPrefix("mvs_") ? $0 : nil }
        }

        if let p = payload(after: " permission.ask ") {
            guard let requestId = p["request_id"] as? String,
                  let sessionId = sid(p) else { return nil }
            return .ask(requestId: requestId,
                        sessionId: sessionId,
                        toolName: (p["tool_name"] as? String) ?? "tool")
        }
        if let p = payload(after: " permission.resolved ")
            ?? payload(after: " permission.processed ") {
            guard let requestId = p["request_id"] as? String,
                  let sessionId = sid(p) else { return nil }
            return .resolved(requestId: requestId, sessionId: sessionId)
        }
        if let p = payload(after: " permission.checker.decision ") {
            guard let sessionId = sid(p),
                  let command = p["command"] as? String,
                  !command.isEmpty else { return nil }
            return .command(sessionId: sessionId, command: command)
        }
        return nil
    }
}
