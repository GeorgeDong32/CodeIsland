import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class IdleThresholdSettingsTests: XCTestCase {

    private let allKeys: [String] = [
        SettingsKey.subagentCleanupSeconds,
        SettingsKey.transcriptStaleNoToolSeconds,
        SettingsKey.transcriptStaleWithToolSeconds,
        SettingsKey.sessionTimeout,
    ]

    override func tearDown() {
        for key in allKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Default values

    func testSubagentCleanupDefault() {
        XCTAssertEqual(
            SettingsManager.shared.subagentCleanupSeconds,
            SettingsDefaults.subagentCleanupSeconds,
            "default should match SettingsDefaults"
        )
        XCTAssertEqual(SettingsDefaults.subagentCleanupSeconds, 30)
    }

    func testTranscriptStaleNoToolDefault() {
        XCTAssertEqual(
            SettingsManager.shared.transcriptStaleNoToolSeconds,
            SettingsDefaults.transcriptStaleNoToolSeconds
        )
        XCTAssertEqual(SettingsDefaults.transcriptStaleNoToolSeconds, 60)
    }

    func testTranscriptStaleWithToolDefault() {
        XCTAssertEqual(
            SettingsManager.shared.transcriptStaleWithToolSeconds,
            SettingsDefaults.transcriptStaleWithToolSeconds
        )
        XCTAssertEqual(SettingsDefaults.transcriptStaleWithToolSeconds, 90)
    }

    // MARK: - Persistence

    func testSubagentCleanupPersistsAcrossRead() {
        SettingsManager.shared.subagentCleanupSeconds = 15
        XCTAssertEqual(SettingsManager.shared.subagentCleanupSeconds, 15)
    }

    func testTranscriptStaleNoToolPersistsAcrossRead() {
        SettingsManager.shared.transcriptStaleNoToolSeconds = 120
        XCTAssertEqual(SettingsManager.shared.transcriptStaleNoToolSeconds, 120)
    }

    func testTranscriptStaleWithToolPersistsAcrossRead() {
        SettingsManager.shared.transcriptStaleWithToolSeconds = 300
        XCTAssertEqual(SettingsManager.shared.transcriptStaleWithToolSeconds, 300)
    }

    func testZeroDisablesAll() {
        SettingsManager.shared.subagentCleanupSeconds = 0
        SettingsManager.shared.transcriptStaleNoToolSeconds = 0
        SettingsManager.shared.transcriptStaleWithToolSeconds = 0
        XCTAssertEqual(SettingsManager.shared.subagentCleanupSeconds, 0)
        XCTAssertEqual(SettingsManager.shared.transcriptStaleNoToolSeconds, 0)
        XCTAssertEqual(SettingsManager.shared.transcriptStaleWithToolSeconds, 0)
    }

    // MARK: - Integration with cleanup helpers

    func testChangeTakesEffectImmediatelyInCleanup() throws {
        // Build a session with a subagent that's 60s old and idle
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "cursor"
        var oldSub = SubagentState(agentId: "old", agentType: "default")
        oldSub.status = .idle
        oldSub.lastActivity = Date(timeIntervalSinceNow: -60)
        session.subagents["old"] = oldSub
        appState.sessions["s1"] = session

        // Threshold 120s should NOT remove the 60s-old subagent
        SettingsManager.shared.subagentCleanupSeconds = 120
        SessionCleanup.performSubagentFastCleanup(
            sessions: &appState.sessions,
            threshold: TimeInterval(SettingsManager.shared.subagentCleanupSeconds)
        )
        XCTAssertNotNil(appState.sessions["s1"]?.subagents["old"], "60s-old subagent should survive 120s threshold")

        // Threshold 30s SHOULD remove it
        SettingsManager.shared.subagentCleanupSeconds = 30
        SessionCleanup.performSubagentFastCleanup(
            sessions: &appState.sessions,
            threshold: TimeInterval(SettingsManager.shared.subagentCleanupSeconds)
        )
        XCTAssertNil(appState.sessions["s1"]?.subagents["old"], "60s-old subagent should be removed by 30s threshold")
    }

    func testZeroDisablesCleanupPath() throws {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "cursor"
        var ancient = SubagentState(agentId: "ancient", agentType: "default")
        ancient.status = .idle
        ancient.lastActivity = Date(timeIntervalSinceNow: -3600)
        session.subagents["ancient"] = ancient
        appState.sessions["s1"] = session

        SettingsManager.shared.subagentCleanupSeconds = 0
        SessionCleanup.performSubagentFastCleanup(
            sessions: &appState.sessions,
            threshold: TimeInterval(SettingsManager.shared.subagentCleanupSeconds)
        )
        XCTAssertNotNil(appState.sessions["s1"]?.subagents["ancient"], "threshold 0 should disable phase entirely")
    }
}
