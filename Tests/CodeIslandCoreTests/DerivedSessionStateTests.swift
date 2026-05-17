import XCTest
@testable import CodeIslandCore

final class DerivedSessionStateTests: XCTestCase {
    func testAllIdleSessionsUseMostRecentlyActiveSource() {
        var older = SessionSnapshot()
        older.source = "claude"
        older.status = .idle
        older.lastActivity = Date(timeIntervalSince1970: 100)

        var newer = SessionSnapshot()
        newer.source = "codex"
        newer.status = .idle
        newer.lastActivity = Date(timeIntervalSince1970: 200)

        let summary = deriveSessionSummary(from: [
            "older": older,
            "newer": newer,
        ])

        XCTAssertEqual(summary.primarySource, "codex")
        XCTAssertEqual(summary.activeSessionCount, 0)
        XCTAssertEqual(summary.totalSessionCount, 2)
    }

    func testNormalizesTraecliAliases() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("traecli"), "traecli")
    }

    func testNormalizesCocoSnakeCaseEvents() {
        XCTAssertEqual(EventNormalizer.normalize("pre_tool_use"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("permission_request"), "PermissionRequest")
        XCTAssertEqual(EventNormalizer.normalize("post_compact"), "PostCompact")
    }

func testNormalizesClineTaskTerminalEvents() {
        XCTAssertEqual(EventNormalizer.normalize("TaskComplete"), "TaskRoundComplete")
        XCTAssertEqual(EventNormalizer.normalize("TaskCancel"), "TaskRoundComplete")
    }

    func testAfterAgentResponseCompletesIDESource() throws {
        var session = SessionSnapshot()
        session.source = "cursor"
        session.status = .running
        session.currentTool = "Agent"
        session.toolDescription = "planning"

        var sessions = ["cursor-session": session]
        let event = try decode([
            "hook_event_name": "afterAgentResponse",
            "session_id": "cursor-session",
            "_source": "cursor",
            "text": "Done",
        ])

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions["cursor-session"]?.status, .idle)
        XCTAssertNil(sessions["cursor-session"]?.currentTool)
        XCTAssertNil(sessions["cursor-session"]?.toolDescription)
        XCTAssertEqual(sessions["cursor-session"]?.lastAssistantMessage, "Done")
        XCTAssertEqual(sessions["cursor-session"]?.recentMessages.last?.text, "Done")
        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "cursor-session")))
    }

    func testAfterAgentResponseKeepsCLISourceProcessing() throws {
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .running
        session.currentTool = "Agent"

        var sessions = ["cli-session": session]
        let event = try decode([
            "hook_event_name": "afterAgentResponse",
            "session_id": "cli-session",
            "_source": "claude",
            "text": "Still thinking",
        ])

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions["cli-session"]?.status, .processing)
        XCTAssertEqual(sessions["cli-session"]?.currentTool, "Agent")
        XCTAssertEqual(sessions["cli-session"]?.lastAssistantMessage, "Still thinking")
        XCTAssertFalse(effects.contains(.enqueueCompletion(sessionId: "cli-session")))
    }

    func testCLIProcessResolverPrefersTraecliBinaryOverShellParent() {
        let pid = CLIProcessResolver.resolvedTrackedPID(
            immediateParentPID: 100,
            source: "traecli",
            ancestry: [
                (pid: 100, executablePath: "/bin/sh", args: nil),
                (pid: 88, executablePath: "/opt/homebrew/bin/coco", args: nil),
                (pid: 77, executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty", args: nil),
            ]
        )

        XCTAssertEqual(pid, 88)
    }

    func testCLIProcessResolverFallsBackToImmediateParentWhenNoMatchFound() {
        let pid = CLIProcessResolver.resolvedTrackedPID(
            immediateParentPID: 100,
            source: "traecli",
            ancestry: [
                (pid: 100, executablePath: "/bin/sh", args: nil),
                (pid: 88, executablePath: "/usr/bin/login", args: nil),
            ]
        )

        XCTAssertEqual(pid, 100)
    }

    // MARK: - Source inference (issue #95)

    func testInferSourceFindsOpencodeInAncestryWhenSourceTagMissing() {
        // omo plugin triggers Claude hooks, but the real CLI up the ancestry is OpenCode.
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/bin/sh", args: nil),
            (pid: 150, executablePath: "/usr/local/bin/node", args: nil),
            (pid: 100, executablePath: "/Applications/OpenCode.app/Contents/MacOS/OpenCode", args: nil),
        ])

        XCTAssertEqual(source, "opencode")
    }

    func testInferSourceReturnsNilWhenNoKnownBinaryInAncestry() {
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/bin/sh", args: nil),
            (pid: 150, executablePath: "/usr/bin/login", args: nil),
            (pid: 100, executablePath: "/sbin/launchd", args: nil),
        ])

        XCTAssertNil(source)
    }

    func testInferSourceReturnsClosestMatchAlongAncestry() {
        // If multiple known CLIs appear, the nearest ancestor wins.
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 200, executablePath: "/usr/local/bin/codex", args: nil),
            (pid: 100, executablePath: "/Applications/Claude.app/Contents/MacOS/claude", args: nil),
        ])

        XCTAssertEqual(source, "codex")
    }

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "DerivedSessionStateTests", code: 1)
        }
        return event
    }
}
