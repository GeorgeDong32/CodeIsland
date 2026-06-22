import XCTest
@testable import CodeIslandCore

/// Verifies that `case "Stop"` in `reduceEvent` distinguishes a Cursor user
/// interrupt (ESC / Ctrl+C) from a natural completion and a non-Cursor Stop,
/// routing the former to `.removeSession` and the latter to
/// `.enqueueCompletion`. Source whitelist guards against accidentally
/// affecting Claude Code (whose Stop payload has no `stop_reason`) and other
/// CLIs.
final class StopInterruptTests: XCTestCase {

    // MARK: - Cursor interrupt removes the session

    func testStopWithCursorInterruptRemovesSession() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "cursor"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "cursor",
            "stop_reason": "user",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.removeSession(sessionId: "s1")), "interrupt must remove the session")
        XCTAssertFalse(effects.contains(.enqueueCompletion(sessionId: "s1")), "interrupt must NOT enqueue completion")
        XCTAssertTrue(sessions["s1"]?.interrupted == true)
    }

    func testStopWithCursorCliInterruptRemovesSession() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "cursor-cli"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "cursor-cli",
            "stop_reason": "interrupted",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.removeSession(sessionId: "s1")))
        XCTAssertFalse(effects.contains(.enqueueCompletion(sessionId: "s1")))
    }

    // MARK: - Cursor natural completion still enqueues

    func testStopWithCursorNaturalCompletionEnqueuesCompletion() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "cursor"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "cursor",
            "stop_reason": "end_turn",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
        XCTAssertFalse(effects.contains(.removeSession(sessionId: "s1")))
        XCTAssertFalse(sessions["s1"]?.interrupted == true)
    }

    func testStopWithCursorMissingStopReasonEnqueuesCompletion() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "cursor"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "cursor",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
        XCTAssertFalse(effects.contains(.removeSession(sessionId: "s1")))
    }

    // MARK: - Non-Cursor Stop events are unaffected (Claude/Codex/Gemini/etc.)

    func testStopWithClaudeCodeEnqueuesCompletion() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "claude"
        var sessions = ["s1": snapshot]

        // Claude Code's Stop payload has no `stop_reason` field at all per its hooks docs.
        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "claude",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
        XCTAssertFalse(effects.contains(.removeSession(sessionId: "s1")))
    }

    func testStopWithCodexEnqueuesCompletion() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "codex"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "codex",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
    }

    func testStopWithGeminiEnqueuesCompletion() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "gemini"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "gemini",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
    }

    func testStopWithTraeEnqueuesCompletion() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "trae"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "trae",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
    }

    func testStopWithCodebuddyEnqueuesCompletion() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "codebuddy"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "codebuddy",
        ])
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
    }

    // MARK: - Interrupt flag still flipped for INT badge display

    func testCursorInterruptSetsInterruptedFlag() throws {
        var snapshot = SessionSnapshot()
        snapshot.source = "cursor"
        var sessions = ["s1": snapshot]

        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "_source": "cursor",
            "stop_reason": "interrupted",
        ])
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)
        XCTAssertTrue(sessions["s1"]?.interrupted == true)
    }

    // MARK: - Helpers

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "StopInterruptTests", code: 1)
        }
        return event
    }
}
