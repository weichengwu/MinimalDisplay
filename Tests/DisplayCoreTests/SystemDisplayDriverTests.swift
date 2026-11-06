import XCTest
@testable import DisplayCore

final class SystemDisplayDriverTests: XCTestCase {
    func testRecoveryAcceptsAlreadyRestoredPhysicalLayoutWithoutMutatingDisplays() throws {
        // Synthetic identities never resolve through the real CoreGraphics transaction path.
        let display = SavedDisplay(id: UInt32.max, uuid: "physical-fixture", x: 0, y: 0, builtin: true,
            mode: SavedDisplayMode(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880,
                                   refreshRate: 60, ioFlags: 3, id: 56))
        var record = RecoveryRecord(displays: [display], disabled: [display])
        record.bootSessionID = nil
        var observed = display
        let driver = SystemDisplayDriver(onlineDisplays: { [display.id] }, activeDisplays: { [display.id] },
                                         readDisplay: { _ in observed })
        XCTAssertNoThrow(try driver.restore(record))
        XCTAssertNoThrow(try driver.restoreModes(record))

        observed = SavedDisplay(id: display.id, uuid: display.uuid, x: 1, y: 0, builtin: true, mode: display.mode)
        XCTAssertThrowsError(try driver.restore(record), "A changed arrangement still needs recovery")
        observed = SavedDisplay(id: display.id, uuid: display.uuid, x: 0, y: 0, builtin: true,
            mode: SavedDisplayMode(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080,
                                   refreshRate: 60, ioFlags: 3, id: 56))
        XCTAssertThrowsError(try driver.restore(record), "A lower resolution must not clear the saved 2K mode")
    }
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
