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
}
