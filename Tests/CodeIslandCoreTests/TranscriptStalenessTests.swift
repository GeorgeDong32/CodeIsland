import XCTest
@testable import CodeIslandCore

/// Verifies `AppState.performTranscriptStalenessDetection` — the pure helper
/// extracted from `cleanupIdleSessions` for testability. Flips `.running` /
/// `.processing` sessions to `.idle` + `interrupted = true` when both their
/// transcript file's `mtime` and the session's `lastActivity` are older than
/// the applicable threshold. Threshold `0` disables the phase.
final class TranscriptStalenessTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptStalenessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - File mtime + lastActivity both stale → flip

    func testProcessingWithStaleMtimeAndLastActivityFlipsToIdle() throws {
        let transcriptPath = try writeTranscriptFile()
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -120))

        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .processing
        session.lastActivity = Date(timeIntervalSinceNow: -120)
        session.transcriptPath = transcriptPath
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        XCTAssertEqual(sessions["s1"]?.status, .idle)
        XCTAssertTrue(sessions["s1"]?.interrupted == true)
    }

    func testRunningWithStaleMtimeAndLastActivityFlipsToIdle() throws {
        let transcriptPath = try writeTranscriptFile()
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -180))

        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .running
        session.currentTool = "Bash"
        session.lastActivity = Date(timeIntervalSinceNow: -180)
        session.transcriptPath = transcriptPath
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        XCTAssertEqual(sessions["s1"]?.status, .idle)
        XCTAssertTrue(sessions["s1"]?.interrupted == true)
        XCTAssertNil(sessions["s1"]?.currentTool)
    }

    // MARK: - One condition not stale → no flip

    func testRecentMtimeKeepsSessionActive() throws {
        let transcriptPath = try writeTranscriptFile()
        // mtime is fresh (5s ago), even though lastActivity is stale
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -5))

        var session = SessionSnapshot()
        session.status = .processing
        session.lastActivity = Date(timeIntervalSinceNow: -120)
        session.transcriptPath = transcriptPath
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        XCTAssertEqual(sessions["s1"]?.status, .processing)
        XCTAssertFalse(sessions["s1"]?.interrupted == true)
    }

    func testRecentLastActivityKeepsSessionActive() throws {
        let transcriptPath = try writeTranscriptFile()
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -120))

        var session = SessionSnapshot()
        session.status = .processing
        session.lastActivity = Date(timeIntervalSinceNow: -5)  // fresh
        session.transcriptPath = transcriptPath
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        XCTAssertEqual(sessions["s1"]?.status, .processing)
    }

    // MARK: - Disabled by threshold 0

    func testBothThresholdsZeroIsDisabled() throws {
        let transcriptPath = try writeTranscriptFile()
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -3600))

        var session = SessionSnapshot()
        session.status = .processing
        session.lastActivity = Date(timeIntervalSinceNow: -3600)
        session.transcriptPath = transcriptPath
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 0,
            noToolThreshold: 0
        )

        XCTAssertEqual(sessions["s1"]?.status, .processing)
        XCTAssertFalse(sessions["s1"]?.interrupted == true)
    }

    func testNoToolThresholdZeroFallsBackToWithTool() throws {
        let transcriptPath = try writeTranscriptFile()
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -120))

        var session = SessionSnapshot()
        session.status = .processing
        session.lastActivity = Date(timeIntervalSinceNow: -120)
        session.transcriptPath = transcriptPath
        var sessions = ["s1": session]

        // Only withTool threshold set; processing should use withTool fallback
        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 0
        )

        XCTAssertEqual(sessions["s1"]?.status, .idle)
    }

    // MARK: - Sessions without transcriptPath are skipped

    func testSessionWithoutTranscriptPathIsSkipped() {
        var session = SessionSnapshot()
        session.status = .processing
        session.lastActivity = Date(timeIntervalSinceNow: -3600)
        session.transcriptPath = nil  // explicit nil
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        XCTAssertEqual(sessions["s1"]?.status, .processing)
    }

    // MARK: - Missing transcript file is treated as infinitely stale

    func testMissingTranscriptFileTreatedAsInfinitelyStale() {
        let ghostPath = tempDir.appendingPathComponent("does-not-exist.jsonl").path

        var session = SessionSnapshot()
        session.status = .processing
        session.lastActivity = Date(timeIntervalSinceNow: -120)
        session.transcriptPath = ghostPath
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        XCTAssertEqual(sessions["s1"]?.status, .idle, "missing file should be treated as infinitely stale")
        XCTAssertTrue(sessions["s1"]?.interrupted == true)
    }

    // MARK: - Remote sessions are skipped

    func testRemoteSessionIsSkipped() throws {
        let transcriptPath = try writeTranscriptFile()
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -3600))

        var session = SessionSnapshot()
        session.status = .processing
        session.lastActivity = Date(timeIntervalSinceNow: -3600)
        session.transcriptPath = transcriptPath
        session.remoteHostId = "remote-host-1"
        var sessions = ["remote-s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        XCTAssertEqual(sessions["remote-s1"]?.status, .processing)
    }

    // MARK: - Status gating

    func testIdleSessionIsSkipped() throws {
        let transcriptPath = try writeTranscriptFile()
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -3600))

        var session = SessionSnapshot()
        session.status = .idle  // already idle
        session.lastActivity = Date(timeIntervalSinceNow: -3600)
        session.transcriptPath = transcriptPath
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        // Should not change already-idle sessions
        XCTAssertEqual(sessions["s1"]?.status, .idle)
        XCTAssertFalse(sessions["s1"]?.interrupted == true)
    }

    func testWaitingApprovalSessionIsSkipped() throws {
        let transcriptPath = try writeTranscriptFile()
        try setFileModificationDate(transcriptPath, to: Date(timeIntervalSinceNow: -3600))

        var session = SessionSnapshot()
        session.status = .waitingApproval
        session.lastActivity = Date(timeIntervalSinceNow: -3600)
        session.transcriptPath = transcriptPath
        var sessions = ["s1": session]

        SessionCleanup.performTranscriptStalenessDetection(
            sessions: &sessions,
            withToolThreshold: 90,
            noToolThreshold: 60
        )

        XCTAssertEqual(sessions["s1"]?.status, .waitingApproval)
    }

    // MARK: - Helpers

    private func writeTranscriptFile() throws -> String {
        let url = tempDir.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try "{\"type\":\"user\"}\n".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func setFileModificationDate(_ path: String, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }
}
