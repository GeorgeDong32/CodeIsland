import XCTest
@testable import CodeIslandCore

/// Homebrew install shapes must be recognized by the source path matcher:
/// cask cursor-cli execs a bundled node whose executable path carries the
/// keg directory, not the `cursor-agent` name (MacBook field report,
/// task 10-16-cli-zombie-sessions).
final class CliSourcePathMatchingTests: XCTestCase {
    private let caskNode = "/opt/homebrew/Caskroom/cursor-cli/2026.10.14-0f9edde/dist-package/node"

    func testCursorCliMatchesCaskroomKegPath() {
        XCTAssertTrue(
            CLIProcessResolver.sourceMatchesExecutablePath(caskNode, source: "cursor-cli"),
            "cask cursor-cli runs a bundled node from the keg — no /cursor-agent component in the path"
        )
    }

    func testCursorCliStillMatchesManagedInstallPath() {
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "/Users/u/.local/share/cursor-agent/versions/0.52.0/cursor-agent", source: "cursor-cli"))
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "/nvm/node_modules/cursor-agent/index.js", source: "cursor-cli"),
            "argv-referenced npm entry keeps matching")
    }

    func testCliVariantOverridePromotesCaskCursorAgentToCli() {
        // The IDE-declared source must be promoted when the cask keg shows up
        // anywhere in the hook process ancestry — otherwise the card renders
        // as a desktop IDE session with wrong terminal routing.
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (100, "/bin/zsh"),
            (101, caskNode),
            (102, "/Users/gd32/.codeisland/codeisland-bridge"),
        ]
        XCTAssertEqual(CLIProcessResolver.cliVariantOverride(declaredSource: "cursor", ancestry: ancestry), "cursor-cli")
    }

    func testCliVariantOverrideDoesNotPromoteIdePaths() {
        // Anti-regression: a real IDE host in the ancestry must NOT be
        // promoted to the CLI variant.
        let ancestry: [(pid: Int32, executablePath: String?)] = [
            (100, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        ]
        XCTAssertNil(CLIProcessResolver.cliVariantOverride(declaredSource: "cursor", ancestry: ancestry))
    }
}
