import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateAutoApproveTests: XCTestCase {
    // MARK: - smartModeForPendingPlan

    func testSmartModeReturnsPermissionSuggestionsWhenPresent() async throws {
        let appState = AppState()

        // Queue a PermissionRequest with permission_suggestions hinting bypassPermissions
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": "do x"],
            "permission_suggestions": [
                ["type": "setMode", "mode": "bypassPermissions"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            return
        }

        _ = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }
        await Task.yield()

        let mode = appState.smartModeForPendingPlan()
        XCTAssertEqual(mode, "bypassPermissions")
    }

    func testSmartModeReturnsPlanSettingWhenNoSuggestions() {
        let appState = AppState()
        // Empty queue — no pending plan, so no suggestions
        let mode = appState.smartModeForPendingPlan()
        // Falls back to planAutoAcceptMode setting (default: "auto")
        XCTAssertEqual(mode, "auto")
    }

    // MARK: - autoApproveInitialResponse

    /// Extract setMode from the hook response JSON.
    private func setModeFromResponse(_ response: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let hookOutput = json["hookSpecificOutput"] as? [String: Any],
              let decision = hookOutput["decision"] as? [String: Any],
              let permissions = decision["updatedPermissions"] as? [[String: Any]] else {
            return nil
        }
        return permissions.first(where: { ($0["type"] as? String) == "setMode" })?["mode"] as? String
    }

    func testInitialResponseUsesBypassWhenSessionObservedBypass() {
        let appState = AppState()
        let sid = "session-bypass"

        // Simulate a session that has observed bypassPermissions
        appState.sessions[sid] = SessionSnapshot()
        appState.sessions[sid]?.mergeObservedPermissionMode("bypassPermissions")

        let response = appState.autoApproveInitialResponse(for: sid)
        let mode = setModeFromResponse(response)
        XCTAssertEqual(mode, "bypassPermissions")
    }

    func testInitialResponseUsesAutoWhenSessionObservedAuto() {
        let appState = AppState()
        let sid = "session-auto"

        // Simulate a session that has observed auto
        appState.sessions[sid] = SessionSnapshot()
        appState.sessions[sid]?.mergeObservedPermissionMode("auto")

        let response = appState.autoApproveInitialResponse(for: sid)
        let mode = setModeFromResponse(response)
        XCTAssertEqual(mode, "auto")
    }

    func testInitialResponseFallsBackToGlobalSettingForNewSession() {
        let appState = AppState()
        // No session — nil sessionId
        let response = appState.autoApproveInitialResponse(for: nil)
        let mode = setModeFromResponse(response)
        // Default global setting is .auto
        XCTAssertEqual(mode, "auto")
    }

    func testInitialResponseFallsBackToGlobalAddRulesWhenObservedIsAcceptEdits() {
        let appState = AppState()
        let sid = "session-acceptedits"

        // Simulate a session that has only observed acceptEdits (lowest rank)
        appState.sessions[sid] = SessionSnapshot()
        appState.sessions[sid]?.mergeObservedPermissionMode("acceptEdits")

        let response = appState.autoApproveInitialResponse(for: sid)
        let mode = setModeFromResponse(response)
        // acceptEdits does NOT escalate — falls back to global (default: .auto)
        XCTAssertEqual(mode, "auto")
    }
}
