import XCTest
@testable import CodeIslandCore

/// Verifies `AppState.performSubagentFastCleanup` — the pure helper extracted
/// from `cleanupIdleSessions` for testability. Removes non-running subagent
/// entries whose `lastActivity` is older than the threshold. `threshold == 0`
/// disables the phase entirely.
final class SubagentFastCleanupTests: XCTestCase {

    // MARK: - Basic behavior

    func testSubagentIdleOver30sIsRemoved() {
        var session = SessionSnapshot()
        session.source = "cursor"
        var oldSub = SubagentState(agentId: "old", agentType: "default")
        oldSub.status = .idle
        oldSub.lastActivity = Date(timeIntervalSinceNow: -60)
        session.subagents["old"] = oldSub
        var sessions = ["s1": session]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: 30)

        XCTAssertNil(sessions["s1"]?.subagents["old"], "stale idle subagent should be removed")
    }

    func testSubagentIdleUnder30sIsKept() {
        var session = SessionSnapshot()
        session.source = "cursor"
        var freshSub = SubagentState(agentId: "fresh", agentType: "default")
        freshSub.status = .idle
        freshSub.lastActivity = Date(timeIntervalSinceNow: -10)
        session.subagents["fresh"] = freshSub
        var sessions = ["s1": session]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: 30)

        XCTAssertNotNil(sessions["s1"]?.subagents["fresh"], "fresh idle subagent should be kept")
    }

    func testSubagentRunningIsNotRemoved() {
        var session = SessionSnapshot()
        session.source = "cursor"
        var runningSub = SubagentState(agentId: "running", agentType: "default")
        runningSub.status = .running
        runningSub.lastActivity = Date(timeIntervalSinceNow: -120)
        session.subagents["running"] = runningSub
        var sessions = ["s1": session]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: 30)

        XCTAssertNotNil(sessions["s1"]?.subagents["running"], "running subagent should not be removed")
    }

    func testSubagentProcessingIsRemovedWhenStale() {
        var session = SessionSnapshot()
        session.source = "cursor"
        var processingSub = SubagentState(agentId: "p", agentType: "default")
        processingSub.status = .processing
        processingSub.lastActivity = Date(timeIntervalSinceNow: -120)
        session.subagents["p"] = processingSub
        var sessions = ["s1": session]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: 30)

        XCTAssertNil(sessions["s1"]?.subagents["p"], "stale processing subagent should be removed")
    }

    // MARK: - Disabled by threshold 0

    func testThresholdZeroIsDisabled() {
        var session = SessionSnapshot()
        var ancientSub = SubagentState(agentId: "ancient", agentType: "default")
        ancientSub.status = .idle
        ancientSub.lastActivity = Date(timeIntervalSinceNow: -3600)  // 1 hour
        session.subagents["ancient"] = ancientSub
        var sessions = ["s1": session]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: 0)

        XCTAssertNotNil(sessions["s1"]?.subagents["ancient"], "threshold 0 should be no-op")
    }

    func testThresholdNegativeIsDisabled() {
        var session = SessionSnapshot()
        var staleSub = SubagentState(agentId: "s", agentType: "default")
        staleSub.status = .idle
        staleSub.lastActivity = Date(timeIntervalSinceNow: -3600)
        session.subagents["s"] = staleSub
        var sessions = ["s1": session]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: -1)

        XCTAssertNotNil(sessions["s1"]?.subagents["s"], "negative threshold should be no-op")
    }

    // MARK: - Multi-session

    func testMultipleSessionsCleanupOnlyStaleOnes() {
        var s1 = SessionSnapshot()
        var stale = SubagentState(agentId: "stale", agentType: "default")
        stale.status = .idle
        stale.lastActivity = Date(timeIntervalSinceNow: -90)
        s1.subagents["stale"] = stale

        var s2 = SessionSnapshot()
        var fresh = SubagentState(agentId: "fresh", agentType: "default")
        fresh.status = .idle
        fresh.lastActivity = Date(timeIntervalSinceNow: -5)
        s2.subagents["fresh"] = fresh

        var sessions = ["s1": s1, "s2": s2]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: 30)

        XCTAssertNil(sessions["s1"]?.subagents["stale"], "s1 stale should be removed")
        XCTAssertNotNil(sessions["s2"]?.subagents["fresh"], "s2 fresh should be preserved")
    }

    func testAutoCwdPrefixDoesNotInterfere() {
        var session = SessionSnapshot()
        session.source = "cursor"
        var autoCwd = SubagentState(agentId: "auto-cwd-cursor-ppid-1234", agentType: "default")
        autoCwd.status = .idle
        autoCwd.lastActivity = Date(timeIntervalSinceNow: -120)
        session.subagents["auto-cwd-cursor-ppid-1234"] = autoCwd
        var sessions = ["s1": session]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: 30)

        XCTAssertNil(sessions["s1"]?.subagents["auto-cwd-cursor-ppid-1234"],
                     "auto-cwd-prefixed synthesized subagent should also be cleaned up")
    }

    func testMixedSubagentsPerSession() {
        var session = SessionSnapshot()
        var idleStale = SubagentState(agentId: "a", agentType: "default")
        idleStale.status = .idle
        idleStale.lastActivity = Date(timeIntervalSinceNow: -120)
        var idleFresh = SubagentState(agentId: "b", agentType: "default")
        idleFresh.status = .idle
        idleFresh.lastActivity = Date(timeIntervalSinceNow: -5)
        var runningStale = SubagentState(agentId: "c", agentType: "default")
        runningStale.status = .running
        runningStale.lastActivity = Date(timeIntervalSinceNow: -120)
        session.subagents["a"] = idleStale
        session.subagents["b"] = idleFresh
        session.subagents["c"] = runningStale
        var sessions = ["s1": session]

        SessionCleanup.performSubagentFastCleanup(sessions: &sessions, threshold: 30)

        XCTAssertNil(sessions["s1"]?.subagents["a"])
        XCTAssertNotNil(sessions["s1"]?.subagents["b"])
        XCTAssertNotNil(sessions["s1"]?.subagents["c"])
    }
}
