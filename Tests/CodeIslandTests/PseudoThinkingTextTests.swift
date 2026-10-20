import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// mcode's "Claude-compatible" transcript serializes thinking blocks as raw
/// JSON strings inside ordinary text blocks. Both the backfill reader and the
/// live-tail extractor must skip them, or cards show `{"type":"thinking",…}`
/// as the assistant message (observed on the minimax source).
final class PseudoThinkingTextTests: XCTestCase {

    func testIsPseudoThinkingText() {
        XCTAssertTrue(JSONLTailer.isPseudoThinkingText(
            #"{"type":"thinking","thinking":"The user wants me to…"}"#))
        XCTAssertTrue(JSONLTailer.isPseudoThinkingText(
            #"  {"type": "thinking", "thinking": "spaced variant"}  "#))
        // Real assistant prose that merely mentions JSON must survive.
        XCTAssertFalse(JSONLTailer.isPseudoThinkingText(
            #"Here is the JSON: {"type":"thinking"} as an example"#))
        XCTAssertFalse(JSONLTailer.isPseudoThinkingText("普通回复"))
        XCTAssertFalse(JSONLTailer.isPseudoThinkingText(""))
    }

    func testExtractTextSkipsPseudoThinkingBlocks() {
        let content: [[String: Any]] = [
            ["type": "thinking", "text": #"{"type":"thinking","thinking":"internal"}"#],
            ["type": "text", "text": "我来看一下这个仓库里权限请求是怎么触发的。"],
        ]
        XCTAssertEqual(
            JSONLTailer.extractText(from: content),
            "我来看一下这个仓库里权限请求是怎么触发的。")
    }

    func testExtractTextAllPseudoReturnsNil() {
        let content: [[String: Any]] = [
            ["type": "text", "text": #"{"type":"thinking","thinking":"only thinking"}"#],
        ]
        XCTAssertNil(JSONLTailer.extractText(from: content))
    }

    func testReadRecentFromTranscriptSkipsPseudoThinking() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let path = dir.appendingPathComponent("mcode.jsonl").path
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"帮我触发一个权限请求"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"{\"type\":\"thinking\",\"thinking\":\"内部思考不该展示\"}"},{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"我来看一下这个仓库里权限请求是怎么触发的。"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = AppState.readRecentFromTranscript(path: path).1
        XCTAssertEqual(messages.map(\.isUser), [true, false])
        XCTAssertEqual(messages.last?.text, "我来看一下这个仓库里权限请求是怎么触发的。")
        XCTAssertFalse(messages.contains { $0.text.contains("type\":\"thinking") })
    }
}
