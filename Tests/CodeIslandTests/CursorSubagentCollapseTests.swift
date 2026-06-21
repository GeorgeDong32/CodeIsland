import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Verifies `AppState.applyCursorSubagentMerge()` — the post-hoc reconciler
/// that groups Cursor/Trae/CodeBuddy sessions by (source, cwd, terminal_id)
/// and merges child sessions into the parent's `subagents` dictionary.
@MainActor
final class CursorSubagentCollapseTests: XCTestCase {

    // MARK: - Post-hoc merge

    func testPostHocMergeMovesChildIntoParentSubagents() {
        let appState = AppState()
        let now = Date()

        // Parent session
        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        parent.status = .running
        appState.sessions["parent"] = parent

        // Child session: same source, cwd, terminal, within 60s
        var child = SessionSnapshot(startTime: now.addingTimeInterval(-5))
        child.source = "cursor"
        child.cwd = "/Users/dev/project"
        child.termBundleId = "com.googlecode.iterm2"
        child.status = .running
        child.currentTool = "Bash"
        child.toolDescription = "git status"
        child.lastActivity = now
        appState.sessions["child"] = child

        let didMutate = appState.applyCursorSubagentMerge()

        XCTAssertTrue(didMutate)
        // Child removed from sessions
        XCTAssertNil(appState.sessions["child"])
        // Child's subagent entry exists in parent
        XCTAssertNotNil(appState.sessions["parent"]?.subagents["child"])
        XCTAssertEqual(appState.sessions["parent"]?.subagents["child"]?.status, .running)
        XCTAssertEqual(appState.sessions["parent"]?.subagents["child"]?.currentTool, "Bash")
        // Parent is running with currentTool = "Agent"
        XCTAssertEqual(appState.sessions["parent"]?.status, .running)
        XCTAssertEqual(appState.sessions["parent"]?.currentTool, "Agent")
    }

    func testPostHocMergeSkipsWhenGapExceeds60s() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-120))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        // Child created 120s after parent — outside 60s window
        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.cwd = "/Users/dev/project"
        child.termBundleId = "com.googlecode.iterm2"
        appState.sessions["child"] = child

        let didMutate = appState.applyCursorSubagentMerge()

        XCTAssertFalse(didMutate)
        // Both remain independent
        XCTAssertNotNil(appState.sessions["parent"])
        XCTAssertNotNil(appState.sessions["child"])
        XCTAssertTrue(appState.sessions["parent"]?.subagents.isEmpty == true)
    }

    func testPostHocMergeSkipsClaudeCode() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "claude"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        var child = SessionSnapshot(startTime: now)
        child.source = "claude"
        child.cwd = "/Users/dev/project"
        child.termBundleId = "com.googlecode.iterm2"
        appState.sessions["child"] = child

        let didMutate = appState.applyCursorSubagentMerge()

        XCTAssertFalse(didMutate)
        XCTAssertNotNil(appState.sessions["parent"])
        XCTAssertNotNil(appState.sessions["child"])
    }

    func testPostHocMergeRequiresTerminalIdMatch() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        // Same cwd but different terminal — no match
        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.cwd = "/Users/dev/project"
        child.termBundleId = "com.apple.Terminal"
        appState.sessions["child"] = child

        let didMutate = appState.applyCursorSubagentMerge()

        XCTAssertFalse(didMutate)
        XCTAssertNotNil(appState.sessions["parent"])
        XCTAssertNotNil(appState.sessions["child"])
    }

    func testPostHocMergeKeepsChildStatusInSubagentState() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        parent.status = .processing
        appState.sessions["parent"] = parent

        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.cwd = "/Users/dev/project"
        child.termBundleId = "com.googlecode.iterm2"
        child.status = .running
        child.currentTool = "Edit"
        child.toolDescription = "main.ts"
        appState.sessions["child"] = child

        _ = appState.applyCursorSubagentMerge()

        let subagent = appState.sessions["parent"]?.subagents["child"]
        XCTAssertEqual(subagent?.status, .running)
        XCTAssertEqual(subagent?.currentTool, "Edit")
        XCTAssertEqual(subagent?.toolDescription, "main.ts")
    }

    func testPostHocMergeWithTtyMatch() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.ttyPath = "/dev/ttys000"
        appState.sessions["parent"] = parent

        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.cwd = "/Users/dev/project"
        child.ttyPath = "/dev/ttys000"
        appState.sessions["child"] = child

        let didMutate = appState.applyCursorSubagentMerge()

        XCTAssertTrue(didMutate)
        XCTAssertNil(appState.sessions["child"])
        XCTAssertNotNil(appState.sessions["parent"]?.subagents["child"])
    }

    func testPostHocMergeWithCmuxSurfaceIdMatch() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor-cli"
        parent.cwd = "/Users/dev/project"
        parent.cmuxSurfaceId = "abc-123"
        appState.sessions["parent"] = parent

        var child = SessionSnapshot(startTime: now)
        child.source = "cursor-cli"
        child.cwd = "/Users/dev/project"
        child.cmuxSurfaceId = "abc-123"
        appState.sessions["child"] = child

        let didMutate = appState.applyCursorSubagentMerge()

        XCTAssertTrue(didMutate)
        XCTAssertNil(appState.sessions["child"])
        XCTAssertNotNil(appState.sessions["parent"]?.subagents["child"])
    }

    func testPostHocMergeThreeChildrenIntoOneParent() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-15))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        for i in 1...3 {
            var child = SessionSnapshot(startTime: now.addingTimeInterval(TimeInterval(-i)))
            child.source = "cursor"
            child.cwd = "/Users/dev/project"
            child.termBundleId = "com.googlecode.iterm2"
            child.status = .running
            appState.sessions["sub-\(i)"] = child
        }

        let didMutate = appState.applyCursorSubagentMerge()

        XCTAssertTrue(didMutate)
        XCTAssertNil(appState.sessions["sub-1"])
        XCTAssertNil(appState.sessions["sub-2"])
        XCTAssertNil(appState.sessions["sub-3"])
        XCTAssertEqual(appState.sessions["parent"]?.subagents.count, 3)
    }

    func testPostHocMergeSkipsWhenNoCwd() {
        let appState = AppState()
        let now = Date()

        // Parent has no cwd — should be skipped
        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.termBundleId = "com.googlecode.iterm2"
        appState.sessions["child"] = child

        let didMutate = appState.applyCursorSubagentMerge()

        // No merge — both have nil cwd
        XCTAssertFalse(didMutate)
        XCTAssertNotNil(appState.sessions["parent"])
        XCTAssertNotNil(appState.sessions["child"])
    }

    func testPostHocMergeSkipsDifferentCwd() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project-a"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.cwd = "/Users/dev/project-b"
        child.termBundleId = "com.googlecode.iterm2"
        appState.sessions["child"] = child

        let didMutate = appState.applyCursorSubagentMerge()

        XCTAssertFalse(didMutate)
        XCTAssertNotNil(appState.sessions["parent"])
        XCTAssertNotNil(appState.sessions["child"])
    }

    func testPostHocMergeIdempotent() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.cwd = "/Users/dev/project"
        child.termBundleId = "com.googlecode.iterm2"
        appState.sessions["child"] = child

        _ = appState.applyCursorSubagentMerge()
        let didMutateSecond = appState.applyCursorSubagentMerge()

        // Second call is a no-op — child already removed
        XCTAssertFalse(didMutateSecond)
    }

    // MARK: - mergedSessionIds cache

    func testMergedSessionIdsCacheIsPopulatedAfterMerge() {
        let appState = AppState()
        let now = Date()

        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.cwd = "/Users/dev/project"
        child.termBundleId = "com.googlecode.iterm2"
        appState.sessions["child"] = child

        _ = appState.applyCursorSubagentMerge()

        // After merge, the cache should contain child -> parent mapping
        XCTAssertEqual(appState.mergedSessionIds["child"], "parent")
        // Child should be removed from sessions
        XCTAssertNil(appState.sessions["child"])
        // Parent should have the child as a subagent
        XCTAssertNotNil(appState.sessions["parent"]?.subagents["child"])
    }

    func testMergedSessionIdsCacheRedirectsSubsequentEvents() {
        let appState = AppState()
        let now = Date()

        // Set up parent
        var parent = SessionSnapshot(startTime: now.addingTimeInterval(-10))
        parent.source = "cursor"
        parent.cwd = "/Users/dev/project"
        parent.termBundleId = "com.googlecode.iterm2"
        appState.sessions["parent"] = parent

        // Set up child
        var child = SessionSnapshot(startTime: now)
        child.source = "cursor"
        child.cwd = "/Users/dev/project"
        child.termBundleId = "com.googlecode.iterm2"
        appState.sessions["child"] = child

        // First merge
        _ = appState.applyCursorSubagentMerge()
        XCTAssertNil(appState.sessions["child"])
        XCTAssertEqual(appState.mergedSessionIds["child"], "parent")

        // Now simulate a subsequent event for the merged child session.
        // The cache should redirect it to the parent instead of creating
        // a new standalone session. We test the cache logic directly.
        let cachedParentId = appState.mergedSessionIds["child"]
        XCTAssertEqual(cachedParentId, "parent")
        XCTAssertNotNil(appState.sessions[cachedParentId!])
    }
}
