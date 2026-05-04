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

    private func trackKey(_ key: String) -> String {
        modifiedKeys.append(key)
        return key
    }

    // MARK: - Default Fallback

    func testDefaultFallbackReturnsTrueForToolInDefaultSet() {
        // No UserDefaults override key — should fall back to default set
        XCTAssertTrue(manager.autoApproveTools.contains("ExitPlanMode"))
        XCTAssertTrue(manager.autoApproveTools.contains("TaskCreate"))
        XCTAssertTrue(manager.autoApproveTools.contains("TodoRead"))
    }

    func testDefaultFallbackReturnsFalseForUnknownTool() {
        // Tool not in default set, no override key — should return false
        XCTAssertFalse(manager.autoApproveTools.contains("SomeRandomTool"))
        XCTAssertFalse(manager.autoApproveTools.contains("Bash"))
    }

    func testAllDefaultToolsAreEnabledByDefault() {
        // Parse the default string into a set
        let defaultTools = Set(SettingsDefaults.autoApproveTools.split(separator: ",").map(String.init))
        for tool in defaultTools {
            XCTAssertTrue(
                manager.autoApproveTools.contains(tool),
                "Tool '\(tool)' should be auto-approved by default"
            )
        }
    }

    // MARK: - Set/Get Round-Trip

    func testSetAutoApproveOffThenOn() {
        let tool = "ExitPlanMode"
        trackKey(SettingsKey.autoApproveTools)

        // Default is ON
        XCTAssertTrue(manager.autoApproveTools.contains(tool))

        // Set OFF
        var tools = manager.autoApproveTools
        tools.remove(tool)
        manager.autoApproveTools = tools
        XCTAssertFalse(manager.autoApproveTools.contains(tool))

        // Set back ON
        tools.insert(tool)
        manager.autoApproveTools = tools
        XCTAssertTrue(manager.autoApproveTools.contains(tool))
    }

    func testSetAutoApproveDoesNotAffectOtherTools() {
        let tool = "ExitPlanMode"
        trackKey(SettingsKey.autoApproveTools)

        var tools = manager.autoApproveTools
        tools.remove(tool)
        manager.autoApproveTools = tools

        // Other tools in default set should remain ON
        XCTAssertTrue(manager.autoApproveTools.contains("TaskCreate"))
        XCTAssertTrue(manager.autoApproveTools.contains("EnterPlanMode"))
    }

    func testEnableNonDefaultTool() {
        let tool = "Bash"
        trackKey(SettingsKey.autoApproveTools)

        // Not in default set — should be OFF by default
        XCTAssertFalse(manager.autoApproveTools.contains(tool))

        // Explicitly enable it
        var tools = manager.autoApproveTools
        tools.insert(tool)
        manager.autoApproveTools = tools
        XCTAssertTrue(manager.autoApproveTools.contains(tool))

        // Disable it again
        tools.remove(tool)
        manager.autoApproveTools = tools
        XCTAssertFalse(manager.autoApproveTools.contains(tool))
    }

    func testAllAutoApproveToolsNamesMatchDefaultSet() {
        // Verify the static UI list names match the default set
        let defaultTools = Set(SettingsDefaults.autoApproveTools.split(separator: ",").map(String.init))
        let uiListNames = Set(SettingsManager.allAutoApproveTools.map { $0.name })
        XCTAssertEqual(uiListNames, defaultTools)
    }
}