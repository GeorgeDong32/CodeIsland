import XCTest
@testable import CodeIsland

@MainActor
final class SettingsAutoApproveTests: XCTestCase {

    // Use shared singleton — clean up keys after each test
    private var manager: SettingsManager { SettingsManager.shared }

    // Track keys we write so we can clean up
    private var modifiedKeys: [String] = []

    override func tearDown() {
        // Remove all keys written during the test
        for key in modifiedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        modifiedKeys.removeAll()
    }

    private func toolKey(_ tool: String) -> String {
        let key = SettingsKey.autoApproveTool(tool)
        modifiedKeys.append(key)
        return key
    }

    // MARK: - Default Fallback (T002)

    func testDefaultFallbackReturnsTrueForToolInDefaultSet() {
        // No UserDefaults override key — should fall back to default set
        XCTAssertTrue(manager.isAutoApproveTool("ExitPlanMode"))
        XCTAssertTrue(manager.isAutoApproveTool("TaskCreate"))
        XCTAssertTrue(manager.isAutoApproveTool("TodoRead"))
    }

    func testDefaultFallbackReturnsFalseForUnknownTool() {
        // Tool not in default set, no override key — should return false
        XCTAssertFalse(manager.isAutoApproveTool("SomeRandomTool"))
        XCTAssertFalse(manager.isAutoApproveTool("Bash"))
    }

    func testAllDefaultToolsAreEnabledByDefault() {
        for tool in SettingsDefaults.autoApproveDefaultTools {
            XCTAssertTrue(
                manager.isAutoApproveTool(tool),
                "Tool '\(tool)' should be auto-approved by default"
            )
        }
    }

    // MARK: - Set/Get Round-Trip (T003)

    func testSetAutoApproveOffThenOn() {
        let tool = "ExitPlanMode"
        let _ = toolKey(tool) // Track for cleanup

        // Default is ON
        XCTAssertTrue(manager.isAutoApproveTool(tool))

        // Set OFF
        manager.setAutoApproveTool(tool, enabled: false)
        XCTAssertFalse(manager.isAutoApproveTool(tool))

        // Set back ON
        manager.setAutoApproveTool(tool, enabled: true)
        XCTAssertTrue(manager.isAutoApproveTool(tool))
    }

    func testSetAutoApproveDoesNotAffectOtherTools() {
        let tool = "ExitPlanMode"
        let _ = toolKey(tool) // Track for cleanup

        manager.setAutoApproveTool(tool, enabled: false)

        // Other tools in default set should remain ON
        XCTAssertTrue(manager.isAutoApproveTool("TaskCreate"))
        XCTAssertTrue(manager.isAutoApproveTool("EnterPlanMode"))
    }

    func testAllAutoApproveToolsContainsAllDefaults() {
        // Verify the static UI list matches the default set
        XCTAssertEqual(
            Set(SettingsManager.allAutoApproveTools),
            SettingsDefaults.autoApproveDefaultTools
        )
    }
}
