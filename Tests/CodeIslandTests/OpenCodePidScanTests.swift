import XCTest
@testable import CodeIsland

/// The opencode pid whitelist must cover Homebrew cellar and npm package
/// install shapes, or `tryMonitorSession`'s CWD scan finds nothing for
/// `_untracked_process` (v2 shared-service) events and session cleanup
/// degrades to blind timeouts (task 10-16-cli-zombie-sessions).
///
/// Spawns real fixture processes (a copy of /bin/sleep) under install-shaped
/// directories and runs the production scanner against them.
@MainActor
final class OpenCodePidScanTests: XCTestCase {
    private var processes: [Process] = []

    override func tearDown() {
        for process in processes where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
        super.tearDown()
    }

    /// Copy /bin/sleep to `path` under `root` and run `<path> 120`, so the
    /// fixture's executablePath IS the install-shaped path we need matched.
    /// `root` (and everything under it) is removed when the test ends.
    private func spawnSleepCopy(at path: String) throws -> Process {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/bin/sleep", toPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["120"]
        try process.run()
        processes.append(process)
        return process
    }

    private func withFixtureRoot(_ body: (String) throws -> Void) throws {
        let root = NSTemporaryDirectory() + "ci-opencode-scan-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }

    /// proc_pidpath can lag a just-spawned exec by a moment — poll briefly.
    private func waitUntilScanned(pid: pid_t, expectMatch: Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let matched = AppState.findOpenCodePids(candidatePids: [pid]).contains(pid)
            if matched == expectMatch { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func testHomebrewCellarKegIsScanned() throws {
        try withFixtureRoot { root in
            let binary = root + "/homebrew/Cellar/opencode-v2/2.0.24/bin/opencode"
            let process = try spawnSleepCopy(at: binary)
            waitUntilScanned(pid: process.processIdentifier, expectMatch: true)
            XCTAssertTrue(
                AppState.findOpenCodePids(candidatePids: [process.processIdentifier]).contains(process.processIdentifier),
                "homebrew installs run from Cellar/opencode-v2/<ver>/bin — the CWD-scan fallback needs this shape"
            )
        }
    }

    func testNpmGlobalPackagePathIsScanned() throws {
        try withFixtureRoot { root in
            // npm installs put the executable inside the package tree
            // (lib/node_modules/opencode-ai/…), executed via node.
            let binary = root + "/npm/lib/node_modules/opencode-ai/bin/opencode"
            let process = try spawnSleepCopy(at: binary)
            waitUntilScanned(pid: process.processIdentifier, expectMatch: true)
            XCTAssertTrue(
                AppState.findOpenCodePids(candidatePids: [process.processIdentifier]).contains(process.processIdentifier),
                "npm-global installs reference /opencode-ai/ in both path and argv"
            )
        }
    }

    func testUnrelatedSleepIsNotScanned() throws {
        try withFixtureRoot { root in
            let binary = root + "/plain/sleep-copy"
            let process = try spawnSleepCopy(at: binary)
            waitUntilScanned(pid: process.processIdentifier, expectMatch: false)
            XCTAssertFalse(
                AppState.findOpenCodePids(candidatePids: [process.processIdentifier]).contains(process.processIdentifier),
                "whitelist must stay narrow: a generic binary outside opencode install roots is not opencode"
            )
        }
    }
}
