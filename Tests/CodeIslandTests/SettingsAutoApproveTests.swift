import XCTest
@testable import CodeIsland

@MainActor
final class SettingsAutoApproveTests: XCTestCase {

    // Use shared singleton — restore autoApproveTools after each test
    private var manager: SettingsManager { SettingsManager.shared }

    // Save original value to restore after test
    private var originalAutoApproveTools: Set<String>?

    override func setUp() {
        // Save current autoApproveTools before any test modifies it
        originalAutoApproveTools = manager.autoApproveTools
    }

    override func tearDown() {
        // Restore original autoApproveTools
        if let original = originalAutoApproveTools {
            manager.autoApproveTools = original
        }
        originalAutoApproveTools = nil
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

        manager.setAutoApproveTool(tool, enabled: false)

        // Other tools in default set should remain ON
        XCTAssertTrue(manager.isAutoApproveTool("TaskCreate"))
        XCTAssertTrue(manager.isAutoApproveTool("EnterPlanMode"))
    }

    func testEnableNonDefaultTool() {
        let tool = "Bash"

        // Not in default set — should be OFF by default
        XCTAssertFalse(manager.isAutoApproveTool(tool))

        // Explicitly enable it
        manager.setAutoApproveTool(tool, enabled: true)
        XCTAssertTrue(manager.isAutoApproveTool(tool))

        // Disable it again
        manager.setAutoApproveTool(tool, enabled: false)
        XCTAssertFalse(manager.isAutoApproveTool(tool))
    }

    func testAllAutoApproveToolsMatchesDefaultSet() {
        // Verify the static UI list (tool names) matches the default set
        let uiToolNames = Set(SettingsManager.allAutoApproveTools.map { $0.name })
        XCTAssertEqual(uiToolNames, SettingsDefaults.autoApproveDefaultTools)
    }
}
