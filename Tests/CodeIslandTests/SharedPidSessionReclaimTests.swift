import XCTest
@testable import CodeIsland

/// Many-sessions-per-PID hosts (cursor-agent TUI, app servers, IDEs): every
/// card on the pid monitors the same long-lived process, so Sections 1/3/4 of
/// cleanupIdleSessions never fire and a missed Stop hook leaves old cards
/// "running" forever — the false multi-agent pile-up (task
/// 10-16-cli-zombie-sessions). Quiet old cards on a shared pid must be
/// reclaimable by activity age alone, keeping the host's freshest card.
final class SharedPidSessionReclaimTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let quiet: TimeInterval = 900 // 15 min, matches sharedPidQuietThreshold

    private func card(_ id: String, pid: pid_t, age: TimeInterval) -> AppState.SharedPidSessionCard {
        AppState.SharedPidSessionCard(
            sessionId: id, cliPid: pid, lastActivity: now.addingTimeInterval(-age)
        )
    }

    func testQuietOldCardOnSharedPidIsReclaimedAndFreshestKept() {
        let stale = AppState.staleSharedPidSessionIds(
            [
                card("old", pid: 67879, age: 3600),
                card("fresh", pid: 67879, age: 30),
            ],
            now: now, quietThreshold: quiet
        )
        XCTAssertEqual(stale, ["old"], "the pile-up shape: 5 cursor cards on one live TUI pid, only the current session stays")
    }

    func testRecentlyActiveOldCardSurvives() {
        let stale = AppState.staleSharedPidSessionIds(
            [
                card("switched-away", pid: 42, age: 300),
                card("current", pid: 42, age: 30),
            ],
            now: now, quietThreshold: quiet
        )
        XCTAssertTrue(stale.isEmpty, "a recently-used session the user may switch back to is not garbage yet")
    }

    func testSingleCardHostIsLeftToClassicLifecycle() {
        let stale = AppState.staleSharedPidSessionIds(
            [card("only", pid: 7, age: 7200)],
            now: now, quietThreshold: quiet
        )
        XCTAssertTrue(stale.isEmpty, "single-card hosts exit via process exit / Stop / Section 1 — no shared-pid semantics")
    }

    func testMultipleStaleCardsAllGo() {
        let stale = AppState.staleSharedPidSessionIds(
            [
                card("a", pid: 9, age: 7200),
                card("b", pid: 9, age: 3600),
                card("current", pid: 9, age: 60),
            ],
            now: now, quietThreshold: quiet
        )
        XCTAssertEqual(stale, ["a", "b"])
    }

    func testUntrackedCardsAreNotConsidered() {
        let stale = AppState.staleSharedPidSessionIds(
            [
                card("no-pid-1", pid: 0, age: 7200),
                card("no-pid-2", pid: 0, age: 3600),
            ],
            now: now, quietThreshold: quiet
        )
        XCTAssertTrue(stale.isEmpty, "pid-less cards have no shared host to reason about — Section 1 already covers them")
    }
}
