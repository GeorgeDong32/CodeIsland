import XCTest
@testable import CodeIslandCore

final class CLIProcessResolverTests: XCTestCase {

    // MARK: - resolvedSessionPID

    /// #148 core repro: Cursor IDE spawns N sub-agent processes, each runs
    /// its own hook subprocess with a different immediate ppid. All those
    /// sub-agents share the same root Cursor binary in their ancestry, so
    /// `resolvedSessionPID` must collapse them onto the same PID.
    func testParallelSubAgentsCollapseToRootSourcePID() {
        // Sub-agent #1 ancestry: hook → sub-agent A (12345) → cursor-agent main (5000)
        let subA: [CLIProcessResolver.AncestryEntry] = [
            (pid: 12345, executablePath: "/Users/u/.cursor/agent/sub-agent", args: nil),
            (pid: 5000, executablePath: "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent", args: nil),
        ]
        // Sub-agent #2 ancestry: hook → sub-agent B (67890) → cursor-agent main (5000)
        let subB: [CLIProcessResolver.AncestryEntry] = [
            (pid: 67890, executablePath: "/Users/u/.cursor/agent/sub-agent", args: nil),
            (pid: 5000, executablePath: "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent", args: nil),
        ]

        let pidA = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: subA
        )
        let pidB = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 67890, source: "cursor-cli", ancestry: subB
        )

        XCTAssertEqual(pidA, 5000)
        XCTAssertEqual(pidB, 5000, "Different sub-agent ppids must resolve to the same root cursor-agent PID for session grouping (#148)")
    }

    /// When multiple binaries of the same source appear in the ancestry,
    /// pick the *root-most* (last) one. Distinguishes resolvedSessionPID
    /// from resolvedTrackedPID, which picks the nearest (first).
    func testResolvedSessionPIDPicksRootMostMatch() {
        let ancestry: [CLIProcessResolver.AncestryEntry] = [
            (pid: 1001, executablePath: "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent", args: nil),
            (pid: 2002, executablePath: "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent", args: nil),
            (pid: 3003, executablePath: "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent", args: nil),
        ]
        let session = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 1001, source: "cursor-cli", ancestry: ancestry
        )
        let tracked = CLIProcessResolver.resolvedTrackedPID(
            immediateParentPID: 1001, source: "cursor-cli", ancestry: ancestry
        )
        XCTAssertEqual(session, 3003, "session pid is the root-most matching binary")
        XCTAssertEqual(tracked, 1001, "tracked pid stays the nearest matching binary")
    }

    /// No binary in the ancestry matches the declared source — fall back
    /// to the immediate ppid (preserves prior behavior for everything but
    /// sub-agent CLIs).
    func testResolvedSessionPIDFallsBackToImmediateParentWhenNoMatch() {
        let ancestry: [CLIProcessResolver.AncestryEntry] = [
            (pid: 12345, executablePath: "/bin/sh", args: nil),
            (pid: 5000, executablePath: "/usr/bin/login", args: nil),
        ]
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: ancestry
        )
        XCTAssertEqual(pid, 12345)
    }

    /// Empty ancestry (e.g. proc lookup failed) — fall back to immediate ppid.
    func testResolvedSessionPIDFallsBackOnEmptyAncestry() {
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: "cursor-cli", ancestry: []
        )
        XCTAssertEqual(pid, 12345)
    }

    /// nil source — nothing to match against, so return immediate ppid.
    func testResolvedSessionPIDFallsBackOnNilSource() {
        let ancestry: [CLIProcessResolver.AncestryEntry] = [
            (pid: 12345, executablePath: "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent", args: nil),
        ]
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 12345, source: nil, ancestry: ancestry
        )
        XCTAssertEqual(pid, 12345)
    }

    /// Defensive: invalid (<= 0) immediate ppid is returned unchanged so
    /// callers can still encode it without contortion.
    func testResolvedSessionPIDReturnsImmediateParentWhenZeroOrNegative() {
        let ancestry: [CLIProcessResolver.AncestryEntry] = [
            (pid: 5000, executablePath: "/Users/u/.local/share/cursor-agent/versions/1.0/cursor-agent", args: nil),
        ]
        XCTAssertEqual(
            CLIProcessResolver.resolvedSessionPID(immediateParentPID: 0, source: "cursor-cli", ancestry: ancestry),
            0
        )
        XCTAssertEqual(
            CLIProcessResolver.resolvedSessionPID(immediateParentPID: -1, source: "cursor-cli", ancestry: ancestry),
            -1
        )
    }

    // MARK: - Node-based Codex detection (argv inspection)

    /// npm-installed Codex has `executablePath = /usr/local/bin/node` but argv
    /// contains `@openai/codex`. The resolver must match it as "codex" source.
    func testSourceMatchesNodeBasedCodexWithArgv() {
        let match = CLIProcessResolver.sourceMatchesProcess(
            "/usr/local/bin/node",
            args: ["/usr/local/bin/node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"],
            source: "codex"
        )
        XCTAssertTrue(match, "node + @openai/codex in argv must match codex source")
    }

    /// When argv contains `openai-codex` (Homebrew shim variant), still matches.
    func testSourceMatchesNodeBasedCodexOpenaiCodexVariant() {
        let match = CLIProcessResolver.sourceMatchesProcess(
            "/opt/homebrew/bin/node",
            args: ["/opt/homebrew/bin/node", "openai-codex"],
            source: "codex"
        )
        XCTAssertTrue(match, "node + openai-codex in argv must match codex source")
    }

    /// Plain `node` without Codex argv must NOT match codex source.
    func testSourceDoesNotMatchPlainNode() {
        let match = CLIProcessResolver.sourceMatchesProcess(
            "/usr/local/bin/node",
            args: ["/usr/local/bin/node", "/some/other/script.js"],
            source: "codex"
        )
        XCTAssertFalse(match, "node without codex argv must not match codex source")
    }

    /// Node with nil args (argv collection failed) must NOT match.
    func testSourceDoesNotMatchNodeWithNilArgs() {
        let match = CLIProcessResolver.sourceMatchesProcess(
            "/usr/local/bin/node",
            args: nil,
            source: "codex"
        )
        XCTAssertFalse(match, "node with nil args must not match codex source")
    }

    /// Native Codex binary (not node) still matches by path suffix.
    func testSourceMatchesNativeCodexBinary() {
        let match = CLIProcessResolver.sourceMatchesProcess(
            "/usr/local/bin/codex",
            args: nil,
            source: "codex"
        )
        XCTAssertTrue(match, "native codex binary must match by path suffix")
    }

    /// resolvedSessionPID must resolve to the correct PID when the ancestry
    /// contains node-based Codex with @openai/codex in argv.
    func testResolvedSessionPIDWithNodeBasedCodexAncestry() {
        let ancestry: [CLIProcessResolver.AncestryEntry] = [
            (pid: 100, executablePath: "/bin/sh", args: nil),
            (pid: 200, executablePath: "/usr/local/bin/node", args: ["/usr/local/bin/node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"]),
        ]
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 100, source: "codex", ancestry: ancestry
        )
        XCTAssertEqual(pid, 200, "node-based Codex must resolve to the node process PID")
    }

    /// inferSource must detect Codex from node + @openai/codex argv.
    func testInferSourceDetectsNodeBasedCodex() {
        let source = CLIProcessResolver.inferSource(ancestry: [
            (pid: 100, executablePath: "/bin/sh", args: nil),
            (pid: 200, executablePath: "/usr/local/bin/node", args: ["/usr/local/bin/node", "@openai/codex"]),
        ])
        XCTAssertEqual(source, "codex")
    }

    // MARK: - Backward compatibility (sourceMatchesExecutablePath)

    /// Old API without args still works for path-based matching.
    func testSourceMatchesExecutablePathBackwardCompat() {
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath("/usr/local/bin/codex", source: "codex"))
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath("/opt/homebrew/bin/coco", source: "traecli"))
        XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath("/usr/local/bin/node", source: "codex"))
    }

    // MARK: - Node-based Qoder CLI detection (argv inspection)

    /// npm-installed @qoder-ai/qodercli runs as node, must match via argv.
    func testSourceMatchesNodeBasedQoderCliWithArgv() {
        let match = CLIProcessResolver.sourceMatchesProcess(
            "/usr/local/bin/node",
            args: ["/usr/local/bin/node", "/usr/local/lib/node_modules/@qoder-ai/qodercli/dist/index.js"],
            source: "qoder-cli"
        )
        XCTAssertTrue(match, "node + @qoder-ai/qodercli in argv must match qoder-cli source")
    }

    /// Plain node without qoder argv must NOT match qoder-cli.
    func testSourceDoesNotMatchPlainNodeForQoderCli() {
        let match = CLIProcessResolver.sourceMatchesProcess(
            "/usr/local/bin/node",
            args: ["/usr/local/bin/node", "/some/other/script.js"],
            source: "qoder-cli"
        )
        XCTAssertFalse(match, "node without qoder argv must not match qoder-cli source")
    }

    /// resolvedSessionPID must find node-based Qoder in ancestry.
    func testResolvedSessionPIDWithNodeBasedQoderCliAncestry() {
        let ancestry: [CLIProcessResolver.AncestryEntry] = [
            (pid: 100, executablePath: "/bin/sh", args: nil),
            (pid: 200, executablePath: "/usr/local/bin/node", args: ["/usr/local/bin/node", "@qoder-ai/qodercli"]),
        ]
        let pid = CLIProcessResolver.resolvedSessionPID(
            immediateParentPID: 100, source: "qoder-cli", ancestry: ancestry
        )
        XCTAssertEqual(pid, 200, "node-based Qoder must resolve to the node process PID")
    }
}
