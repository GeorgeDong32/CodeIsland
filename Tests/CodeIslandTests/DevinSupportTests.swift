import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Locks in the wire-level pieces of Devin CLI (Cognition) support.
///
/// Devin CLI reads Claude-format hooks from ~/.config/devin/config.json
/// ("hooks" key) and sends Claude-style snake_case payloads with
/// session_id/prompt_id correlation ids. Its PermissionRequest reply contract
/// is NOT Claude's hookSpecificOutput wrapper but a bare top-level
/// {"decision":"approve"|"block","reason"?} — verified against
/// docs.devin.ai/cli/extensibility/hooks (overview + lifecycle-hooks).
/// These assertions guard the pieces that don't need a live Devin install:
/// source recognition, CLI registration, the event set, and the reply shapes
/// produced by the island's approval/deny/drain paths.
final class DevinSupportTests: XCTestCase {

    // MARK: - Source recognition

    func testDevinIsRecognizedAsSupportedSource() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("devin"), "devin")
        var snapshot = SessionSnapshot()
        snapshot.source = "devin"
        XCTAssertEqual(snapshot.sourceLabel, "Devin CLI")
    }

    func testDevinEventDetection() throws {
        let devinEvent = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "devin-1",
            "tool_name": "exec",
            "_source": "devin",
        ] as [String: Any])))
        XCTAssertTrue(AppState.isDevinEvent(devinEvent))

        let claudeEvent = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "c-1",
            "tool_name": "Bash",
            "_source": "claude",
        ] as [String: Any])))
        XCTAssertFalse(AppState.isDevinEvent(claudeEvent))
    }

    // MARK: - CLI registration

    func testDevinCLIConfigIsRegistered() {
        let cli = ConfigInstaller.allCLIs.first { $0.source == "devin" }
        XCTAssertEqual(cli?.name, "Devin")
        XCTAssertEqual(cli?.configPath, ".config/devin/config.json")
        XCTAssertEqual(cli?.configKey, "hooks")
        // Claude entry shape (matcher + hooks array, timeout in seconds).
        XCTAssertEqual(cli?.format, .claude)
    }

    func testDevinEventsStayInsideTheDocumentedSchema() {
        // The eight documented Devin hook events; we register the seven that
        // matter for status + approvals (PostCompaction adds nothing).
        let documented: Set<String> = [
            "PreToolUse", "PostToolUse", "PermissionRequest", "UserPromptSubmit",
            "Stop", "PostCompaction", "SessionStart", "SessionEnd",
        ]
        let cli = ConfigInstaller.allCLIs.first { $0.source == "devin" }
        let names = cli?.events.map { $0.0 } ?? []
        XCTAssertTrue(names.allSatisfy(documented.contains), "undocumented event: \(names.filter { !documented.contains($0) })")
        XCTAssertTrue(names.contains("PermissionRequest"))
        // The blocking approval hook needs a long timeout so the island card
        // can wait on the user (Devin timeout is seconds, like Claude).
        let permission = cli?.events.first { $0.0 == "PermissionRequest" }
        XCTAssertEqual(permission?.1, 86400)
    }

    // MARK: - Reply contract

    func testDevinAllowAndDenyUseBareTopLevelDecision() throws {
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "devin-reply-1",
            "tool_name": "exec",
            "tool_input": ["command": "rm -rf build"],
            "_source": "devin",
        ] as [String: Any])))

        let allow = try XCTUnwrap(JSONSerialization.jsonObject(with: AppState.allowResponseData(for: event)) as? [String: Any])
        XCTAssertEqual(allow["decision"] as? String, "approve")
        XCTAssertNil(allow["hookSpecificOutput"], "Devin has no hookSpecificOutput wrapper")
        XCTAssertNil(allow["continue"], "Devin has no continue field")

        let deny = try XCTUnwrap(JSONSerialization.jsonObject(with: AppState.denyResponseData(for: event, message: "Denied on CodeIsland")) as? [String: Any])
        XCTAssertEqual(deny["decision"] as? String, "block")
        XCTAssertEqual(deny["reason"] as? String, "Denied on CodeIsland")
    }

    // MARK: - End-to-end approval flow

    @MainActor
    func testDevinPermissionApprovalRoundTripUsesBareDecision() async throws {
        let appState = AppState()
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "devin-e2e-1",
            "tool_name": "exec",
            "tool_input": ["command": "git push"],
            "_source": "devin",
        ] as [String: Any])))

        // Approve
        var responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        XCTAssertEqual(appState.permissionQueue.count, 1)
        appState.approvePermission(always: false)
        var responseData = try await awaitValue(of: responseTask)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(json["decision"] as? String, "approve")
        XCTAssertNil(json["hookSpecificOutput"])

        // "Always allow" degrades to a plain approve: Devin's hook output has
        // no rule-persistence form.
        responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.approvePermission(always: true)
        responseData = try await awaitValue(of: responseTask)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(json["decision"] as? String, "approve")
        XCTAssertNil(json["updatedPermissions"])

        // Deny
        responseTask = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }
        appState.denyPermission()
        responseData = try await awaitValue(of: responseTask)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertEqual(json["decision"] as? String, "block")
    }
}
