import Foundation

/// Side-channel watcher for MiniMax Code (mcode) permission prompts.
///
/// mcode does NOT dispatch `PermissionRequest` to plugin hooks for
/// interactive TUI asks (verified empirically — tool hooks fire, permission
/// asks go straight to the TUI dialog). Its runtime observability log
/// records the full permission lifecycle instead:
///
///     [00:15:26.825] INFO: [] permission.ask       {"request_id":…,"session_id":"mvs_…","tool_name":"bash",…}
///     [00:16:22.451] INFO: [] permission.resolved  {"request_id":…,"session_id":"mvs_…","decision":"allowOnce"}
///     [00:16:22.451] INFO: [] permission.processed {"request_id":…,"session_id":"mvs_…,"tool_name":"bash",…}
///
/// Tail those lines and surface a DISPLAY-ONLY waitingApproval on the card:
/// the island cannot approve/deny (the user answers in the TUI), but the
/// card explains why the session paused and offers the terminal jump.
///
/// Event-driven, zero idle cost (spec: animation-performance.md — watchers
/// use DispatchSource, never polling timers): a `.write` source on the open
/// log file fires on appends; a `.write` source on the directory fd catches
/// the hourly bucket rollover.
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
    private let onEvents: @Sendable ([Event]) -> Void

    // Tail state
    private var currentFile: String?
    private var offset: UInt64 = 0
    private var carry = ""
    private var fileHandle: FileHandle?
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?

    private var logDir: String {
        if let override = ProcessInfo.processInfo.environment["MINIMAX_DATA_DIR"], !override.isEmpty {
            return override + "/v2/observability/logs"
        }
        return NSHomeDirectory() + "/.minimax/v2/observability/logs"
    }

    init(onEvents: @escaping @Sendable ([Event]) -> Void) {
        self.onEvents = onEvents
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
        try? fileHandle?.close()
    }

    func start() {
        queue.async { [self] in attach() }
    }

    func stop() {
        queue.async { [self] in
            fileSource?.cancel(); fileSource = nil
            dirSource?.cancel(); dirSource = nil
            try? fileHandle?.close(); fileHandle = nil
            currentFile = nil; offset = 0; carry = ""
        }
    }

    // MARK: - DispatchSource wiring

    private func attach() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logDir) else {
            // mcode data dir absent or not yet created — poll lazily for the
            // directory itself (cheap: one stat every 10s until it exists).
            queue.asyncAfter(deadline: .now() + 10) { self.attach() }
            return
        }
        watchDirectory()
        switchToNewestFile()
    }

    private func watchDirectory() {
        guard dirSource == nil else { return }
        let fd = open(logDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: queue)
        src.setEventHandler { [weak self] in self?.queue.async { self?.rolloverIfNeeded() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    private func switchToNewestFile() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logDir) else { return }
        let logs = names.filter { $0.hasPrefix("runtime-") && $0.hasSuffix(".log") }.sorted()
        guard let newest = logs.last else { return }
        guard newest != currentFile else { return }

        fileSource?.cancel(); fileSource = nil
        try? fileHandle?.close()
        carry = ""
        let path = logDir + "/" + newest
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        currentFile = newest
        offset = 0
        fileHandle = handle
        let fd = handle.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: queue)
        src.setEventHandler { [weak self] in self?.queue.async { self?.drain() } }
        // A cancelled source's cancel-handler must not close the shared fd —
        // the FileHandle owns it; we only cancel the source.
        src.resume()
        fileSource = src
        drain()
    }

    private func rolloverIfNeeded() { switchToNewestFile() }

    // MARK: - Tail

    private func drain() {
        guard let handle = fileHandle else { return }
        let size = handle.seekToEndOfFile()
        if size < offset { offset = 0; carry = "" }   // truncated content
        guard size > offset else { return }
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        guard let text = String(data: data, encoding: .utf8) else { return }

        var stream = carry + text
        if let lastNewline = stream.lastIndex(of: "\n") {
            carry = String(stream[stream.index(after: lastNewline)...])
            stream = String(stream[stream.startIndex..<lastNewline])
        } else {
            carry = stream
            stream = ""
        }
        var events: [Event] = []
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
