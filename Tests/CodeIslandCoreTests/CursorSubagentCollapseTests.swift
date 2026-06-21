import XCTest
@testable import CodeIslandCore

/// Verifies the `HookEvent.withRewritten(sessionId:agentId:)` helper used by
/// `AppState.mergeIntoParentSessionIfMatches` to route parallel subagent hook
/// events into an existing parent session's `subagents` map.
final class CursorSubagentCollapseTests: XCTestCase {

    // MARK: - withRewritten preserves payload fields

    func testWithRewrittenChangesSessionIdAndAgentId() throws {
        let event = try decode([
            "hook_event_name": "beforeShellExecution",
            "session_id": "orig-id",
            "_source": "cursor",
            "cwd": "/repo",
            "tool_name": "Bash",
        ])
        let rewritten = event.withRewritten(sessionId: "parent-id", agentId: "auto-cwd-orig-id")

        XCTAssertEqual(rewritten.sessionId, "parent-id")
        XCTAssertEqual(rewritten.agentId, "auto-cwd-orig-id")
        // Other fields preserved
        XCTAssertEqual(rewritten.eventName, "beforeShellExecution")
        XCTAssertEqual(rewritten.toolName, "Bash")
        XCTAssertEqual(rewritten.rawJSON["tool_name"] as? String, "Bash")
        XCTAssertEqual(rewritten.rawJSON["cwd"] as? String, "/repo")
        XCTAssertEqual(rewritten.rawJSON["_source"] as? String, "cursor")
    }

    func testWithRewrittenUpdatesBothSessionIdAliasesInRawJSON() throws {
        let event = try decode([
            "hook_event_name": "Stop",
            "session_id": "orig-id",
            "_source": "cursor",
        ])
        let rewritten = event.withRewritten(sessionId: "parent-id", agentId: "auto-cwd-orig-id")

        // Both camelCase and snake_case variants are updated so downstream
        // readers using either alias see the new value.
        XCTAssertEqual(rewritten.rawJSON["session_id"] as? String, "parent-id")
        XCTAssertEqual(rewritten.rawJSON["sessionId"] as? String, "parent-id")
        XCTAssertEqual(rewritten.rawJSON["agent_id"] as? String, "auto-cwd-orig-id")
    }

    func testWithRewrittenClearsAgentIdWhenNil() throws {
        let event = try decode([
            "hook_event_name": "beforeShellExecution",
            "session_id": "orig-id",
            "_source": "cursor",
            "agent_id": "old-agent-id",
        ])
        let rewritten = event.withRewritten(sessionId: "parent-id", agentId: nil)

        XCTAssertNil(rewritten.agentId)
        XCTAssertNil(rewritten.rawJSON["agent_id"], "rawJSON.agent_id should be removed")
    }

    // MARK: - reducer accepts rewritten event as subagent

    func testRewrittenCursorEventIsRoutedToParentSubagents() throws {
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .processing
        var sessions = ["parent": parent]

        let original = try decode([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "sub-id",
            "_source": "cursor",
            "agent_id": "",
            "prompt": "background task",
        ])
        let rewritten = original.withRewritten(sessionId: "parent", agentId: "auto-cwd-sub-id")
        _ = reduceEvent(sessions: &sessions, event: rewritten, maxHistory: 10)

        XCTAssertNotNil(sessions["parent"]?.subagents["auto-cwd-sub-id"], "subagent should be added to parent")
        XCTAssertEqual(sessions["parent"]?.subagents["auto-cwd-sub-id"]?.status, .processing)
        XCTAssertEqual(sessions["parent"]?.status, .running, "parent should be marked running while subagent is active")
    }

    func testAgentIdPrefixIsStable() throws {
        let event = try decode([
            "hook_event_name": "beforeShellExecution",
            "session_id": "sess_abc123",
            "_source": "cursor",
        ])
        let rewritten = event.withRewritten(sessionId: "parent", agentId: "auto-cwd-\(event.sessionId ?? "")")
        XCTAssertEqual(rewritten.agentId, "auto-cwd-sess_abc123")
    }

    // MARK: - Helpers

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "CursorSubagentCollapseTests", code: 1)
        }
        return event
    }
}
