import XCTest
@testable import CodeIsland

@MainActor
final class SettingsAutoApproveTests: XCTestCase {

    private var manager: SettingsManager { SettingsManager.shared }
    private var modifiedKeys: [String] = []

    override func tearDown() {
        for key in modifiedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        modifiedKeys.removeAll()
    }

    private func trackKey(_ key: String) -> String {
        modifiedKeys.append(key)
        return key
    }

    // MARK: - Default Fallback (upstream empty default)

    func testDefaultAutoApproveToolsIsEmpty() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.autoApproveTools)
        XCTAssertTrue(manager.autoApproveTools.isEmpty)
        XCTAssertFalse(manager.autoApproveTools.contains("ExitPlanMode"))
        XCTAssertFalse(manager.autoApproveTools.contains("Bash"))
    }

    func testAllAutoApproveToolsNamesMatchUICatalog() {
        let names = Set(SettingsManager.allAutoApproveTools.map(\.name))
        XCTAssertTrue(names.contains("ExitPlanMode"))
        XCTAssertTrue(names.contains("TaskCreate"))
        XCTAssertEqual(names.count, SettingsManager.allAutoApproveTools.count)
    }

    // MARK: - Set/Get Round-Trip

    func testSetAutoApproveOffThenOn() {
        let tool = "ExitPlanMode"
        trackKey(SettingsKey.autoApproveTools)

        var tools = manager.autoApproveTools
        tools.insert(tool)
        manager.autoApproveTools = tools
        XCTAssertTrue(manager.autoApproveTools.contains(tool))

        tools.remove(tool)
        manager.autoApproveTools = tools
        XCTAssertFalse(manager.autoApproveTools.contains(tool))
    }

    func testSetAutoApproveDoesNotAffectOtherTools() {
        trackKey(SettingsKey.autoApproveTools)

        var tools: Set<String> = ["ExitPlanMode", "TaskCreate"]
        manager.autoApproveTools = tools
        tools.remove("ExitPlanMode")
        manager.autoApproveTools = tools

        XCTAssertFalse(manager.autoApproveTools.contains("ExitPlanMode"))
        XCTAssertTrue(manager.autoApproveTools.contains("TaskCreate"))
    }

    func testEnableNonDefaultTool() {
        let tool = "Bash"
        trackKey(SettingsKey.autoApproveTools)

        XCTAssertFalse(manager.autoApproveTools.contains(tool))

        var tools = manager.autoApproveTools
        tools.insert(tool)
        manager.autoApproveTools = tools
        XCTAssertTrue(manager.autoApproveTools.contains(tool))
    }

    func testAutoApproveModeDefaultIsAuto() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.autoApproveMode)
        XCTAssertEqual(manager.autoApproveMode, .auto)
    }

    func testPlanAutoAcceptModeDefaultIsAuto() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.planAutoAcceptMode)
        XCTAssertEqual(manager.planAutoAcceptMode, .auto)
    }
}
