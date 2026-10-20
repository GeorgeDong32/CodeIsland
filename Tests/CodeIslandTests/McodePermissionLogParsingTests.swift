import XCTest
@testable import CodeIsland

/// Parses the exact mcode observability log lines captured live on 0.5.5
/// (runtime-2026102000.log). The watcher's whole value hangs on recognizing
/// these shapes, so the lines are verbatim.
final class McodePermissionLogParsingTests: XCTestCase {

    func testParsesAskLine() {
        let line = #"[00:15:26.825] INFO: [] permission.ask {"request_id":"perm_a0dec38739f04aa5889c9ab5a6e36041","session_id":"mvs_98aff8d0b5494b27b1d31355cb79f12a","tool_name":"bash","decision":"ask","rule_count":1}"#
        XCTAssertEqual(McodePermissionLogWatcher.parse(line: line), .ask(
            requestId: "perm_a0dec38739f04aa5889c9ab5a6e36041",
            sessionId: "mvs_98aff8d0b5494b27b1d31355cb79f12a",
            toolName: "bash"))
    }

    func testParsesResolvedLine() {
        let line = #"[00:16:22.451] INFO: [] permission.resolved {"request_id":"perm_a0dec38739f04aa5889c9ab5a6e36041","session_id":"mvs_98aff8d0b5494b27b1d31355cb79f12a","decision":"allowOnce"}"#
        XCTAssertEqual(McodePermissionLogWatcher.parse(line: line), .resolved(
            requestId: "perm_a0dec38739f04aa5889c9ab5a6e36041",
            sessionId: "mvs_98aff8d0b5494b27b1d31355cb79f12a"))
    }

    func testParsesProcessedLineAsResolved() {
        let line = #"[00:16:22.451] INFO: [] permission.processed {"request_id":"perm_a0dec38739f04aa5889c9ab5a6e36041","session_id":"mvs_98aff8d0b5494b27b1d31355cb79f12a","tool_name":"bash","decision":"allowOnce","decision_source":"user_reply","result":"processed"}"#
        XCTAssertEqual(McodePermissionLogWatcher.parse(line: line), .resolved(
            requestId: "perm_a0dec38739f04aa5889c9ab5a6e36041",
            sessionId: "mvs_98aff8d0b5494b27b1d31355cb79f12a"))
    }

    func testParsesCheckerDecisionCommand() {
        let line = #"[00:00:53.967] INFO: [] permission.checker.decision {"session_id":"mvs_98aff8d0b5494b27b1d31355cb79f12a","tool_name":"bash","permission_mode":"default","policy_owner":"core","checker_registered":true,"checker_behavior":"ask","command":"ls -la /Users/gd32/.minimax/bin/ 2>/dev/null"}"#
        XCTAssertEqual(McodePermissionLogWatcher.parse(line: line), .command(
            sessionId: "mvs_98aff8d0b5494b27b1d31355cb79f12a",
            command: "ls -la /Users/gd32/.minimax/bin/ 2>/dev/null"))
    }

    func testIgnoresUnrelatedLifecycleLines() {
        let lines = [
            #"[00:15:26.826] INFO: [] permission.lifecycle {"request_id":"perm_x","session_id":"mvs_y","lifecycle":"created","pending_count":1,"waiter_count":1,"origin":"local"}"#,
            #"[00:11:41.403] INFO: [session] permission.lifecycle {"request_id":"perm_x","session_id":"mvs_y","lifecycle":"rule_persist_start","rule_count":1}"#,
            #"[00:00:53.966] INFO: [] [permission] subcommand layer=soft-prescan mode=default verdict=ask {"permLayer":"soft-prescan"}"#,
            "[00:00:42.613] INFO: [session] something.else entirely",
        ]
        for line in lines {
            XCTAssertNil(McodePermissionLogWatcher.parse(line: line), "should ignore: \(line.prefix(60))")
        }
    }

    func testIgnoresNonMvsSessionIds() {
        let line = #"[00:15:26.825] INFO: [] permission.ask {"request_id":"perm_1","session_id":"other_prefix","tool_name":"bash"}"#
        XCTAssertNil(McodePermissionLogWatcher.parse(line: line))
    }
}
