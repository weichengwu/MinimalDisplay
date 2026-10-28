import XCTest
@testable import DisplayCore

final class SystemDisplayDriverTests: XCTestCase {
    func testRemovedDisplayIDsFollowAuthoritativeListsInsteadOfBooleanQueries() {
        let id: UInt32 = 0xFFFF_FFFE
        var online: [UInt32] = []
        var active: [UInt32] = []
        let driver = SystemDisplayDriver(onlineDisplays: { online }, activeDisplays: { active })
        XCTAssertFalse(driver.isActive(id), "A disabled ID is absent from display lists")
        online = [id]; active = [id]
        XCTAssertTrue(driver.isActive(id), "A restored ID must become active again")
        online = []; active = []
        XCTAssertFalse(driver.isActive(id), "Re-disabling it must not be mistaken for a truthy error value")
    }
    func testActivityLookupFailureDoesNotAuthorizeFurtherTopologyChanges() {
        let driver = SystemDisplayDriver(onlineDisplays: { throw DisplayFailure("unavailable") }, activeDisplays: { [1] })
        XCTAssertFalse(driver.isActive(1))
    }
}
