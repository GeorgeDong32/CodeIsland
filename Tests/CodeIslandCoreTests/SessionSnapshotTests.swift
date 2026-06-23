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
}
