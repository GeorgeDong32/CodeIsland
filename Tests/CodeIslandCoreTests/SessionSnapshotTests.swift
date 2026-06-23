import XCTest
@testable import CodeIslandCore

final class SessionSnapshotTests: XCTestCase {
    // MARK: - mergeObservedPermissionMode

    func testObservedPermissionModeStoresFirstValue() {
        var snapshot = SessionSnapshot()
        snapshot.mergeObservedPermissionMode("auto")
        XCTAssertEqual(snapshot.observedPermissionMode, "auto")
    }

    func testObservedPermissionModeEscalatesAutoToBypass() {
        var snapshot = SessionSnapshot()
        snapshot.mergeObservedPermissionMode("auto")
        snapshot.mergeObservedPermissionMode("bypassPermissions")
        XCTAssertEqual(snapshot.observedPermissionMode, "bypassPermissions")
    }

    func testObservedPermissionModeDoesNotDowngradeBypassToAuto() {
        var snapshot = SessionSnapshot()
        snapshot.mergeObservedPermissionMode("bypassPermissions")
        snapshot.mergeObservedPermissionMode("auto")
        XCTAssertEqual(snapshot.observedPermissionMode, "bypassPermissions")
    }

    func testObservedPermissionModeIgnoresUnrecognizedValue() {
        var snapshot = SessionSnapshot()
        snapshot.mergeObservedPermissionMode("auto")
        snapshot.mergeObservedPermissionMode("plan")
        XCTAssertEqual(snapshot.observedPermissionMode, "auto")
    }

    func testObservedPermissionModeDefaultsToNil() {
        let snapshot = SessionSnapshot()
        XCTAssertNil(snapshot.observedPermissionMode)
    }

    // MARK: - truncatedForDisplay

    /// Short strings are returned unchanged. Caps in this helper exist to
    /// prevent a single long assistant reply from pinning tens to hundreds
    /// of KB on a single session, which is a major contributor to the
    /// v1.2.8 idle-memory regression.
    func testTruncatedForDisplayReturnsShortStringsUnchanged() {
        let short = "hello world"
        XCTAssertEqual(SessionSnapshot.truncatedForDisplay(short), short)
    }

    func testTruncatedForDisplayCapsLongStringsWithSuffix() {
        let long = String(repeating: "a", count: SessionSnapshot.maxDisplayStringBytes * 2)
        let truncated = SessionSnapshot.truncatedForDisplay(long)
        XCTAssertLessThanOrEqual(truncated.utf8.count, SessionSnapshot.maxDisplayStringBytes)
        XCTAssertTrue(truncated.hasSuffix("…[truncated, see transcript]"),
                      "truncated string must carry the marker suffix")
    }

    func testTruncatedForDisplayPreservesExactCap() {
        let exact = String(repeating: "x", count: SessionSnapshot.maxDisplayStringBytes)
        XCTAssertEqual(SessionSnapshot.truncatedForDisplay(exact), exact)
    }

    // MARK: - addRecentMessage text cap

    /// `addRecentMessage` MUST truncate the text of each `ChatMessage` it
    /// appends, so a single very long assistant reply (or user prompt)
    /// cannot pin `maxCount * uncapped` bytes per retained session. This is
    /// the second line of defense after the direct `lastUserPrompt` /
    /// `lastAssistantMessage` cap applied in the reducer.
    func testAddRecentMessageTruncatesText() {
        var snapshot = SessionSnapshot()
        let longText = String(repeating: "z", count: SessionSnapshot.maxDisplayStringBytes * 3)
        snapshot.addRecentMessage(ChatMessage(isUser: false, text: longText))
        XCTAssertEqual(snapshot.recentMessages.count, 1)
        let stored = snapshot.recentMessages[0].text
        XCTAssertLessThanOrEqual(stored.utf8.count, SessionSnapshot.maxDisplayStringBytes)
        XCTAssertTrue(stored.hasSuffix("…[truncated, see transcript]"))
    }

    func testInsertRecentMessageTruncatesText() {
        var snapshot = SessionSnapshot()
        let longText = String(repeating: "q", count: SessionSnapshot.maxDisplayStringBytes * 3)
        snapshot.insertRecentMessage(ChatMessage(isUser: true, text: longText), at: 0)
        XCTAssertEqual(snapshot.recentMessages.count, 1)
        XCTAssertLessThanOrEqual(snapshot.recentMessages[0].text.utf8.count, SessionSnapshot.maxDisplayStringBytes)
    }
}
