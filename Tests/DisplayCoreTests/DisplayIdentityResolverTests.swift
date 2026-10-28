import XCTest
@testable import DisplayCore

final class DisplayIdentityResolverTests: XCTestCase {
    private let saved = SavedDisplay(id: 1, uuid: "original", x: 0, y: 0, builtin: true)

    func testDisabledDisplayWithoutUUIDCanUseJournaledIDInSameBoot() throws {
        let resolver = DisplayIdentityResolver(uuidForID: { _ in nil }, idForUUID: { _ in nil }, isOnline: { _ in false })
        XCTAssertEqual(try resolver.resolve(saved, required: true, allowOfflineID: true), 1)
    }
    func testUnknownIdentityAcrossBootsRemainsRejected() {
        let resolver = DisplayIdentityResolver(uuidForID: { _ in nil }, idForUUID: { _ in nil }, isOnline: { _ in false })
        XCTAssertThrowsError(try resolver.resolve(saved, required: true, allowOfflineID: false))
    }
    func testReusedOrOnlineUnknownIDCannotBeReenabledByFallback() {
        let reused = DisplayIdentityResolver(uuidForID: { _ in "different" }, idForUUID: { _ in nil }, isOnline: { _ in false })
        XCTAssertThrowsError(try reused.resolve(saved, required: true, allowOfflineID: true))
        let online = DisplayIdentityResolver(uuidForID: { _ in nil }, idForUUID: { _ in nil }, isOnline: { _ in true })
        XCTAssertThrowsError(try online.resolve(saved, required: true, allowOfflineID: true))
    }
    func testUUIDCanResolveAChangedDisplayID() throws {
        let resolver = DisplayIdentityResolver(uuidForID: { $0 == 4 ? "original" : nil }, idForUUID: { _ in 4 }, isOnline: { _ in true })
        XCTAssertEqual(try resolver.resolve(saved, required: true, allowOfflineID: false), 4)
    }
    func testLegacyJournalCannotAcquireBootScopeIfCreatedBeforeBootOrMissingDates() {
        let boot = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(BootSession.legacyJournalIsFromCurrentBoot(created: boot + 1, modified: boot + 2, bootStarted: boot))
        XCTAssertFalse(BootSession.legacyJournalIsFromCurrentBoot(created: boot - 1, modified: boot + 2, bootStarted: boot))
        XCTAssertFalse(BootSession.legacyJournalIsFromCurrentBoot(created: boot + 1, modified: boot - 1, bootStarted: boot))
        XCTAssertFalse(BootSession.legacyJournalIsFromCurrentBoot(created: nil, modified: boot + 2, bootStarted: boot))
    }
    func testLegacyRecoveryRecordLoadsWithoutOverwritingOriginalFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = StateFiles(directory: directory)
        try files.prepare()
        var record = RecoveryRecord(displays: [saved], disabled: [saved])
        record.bootSessionID = nil
        let original = try JSONEncoder().encode(record)
        try original.write(to: files.recoveryURL, options: .atomic)
        let loaded = try XCTUnwrap(files.readRecovery())
        XCTAssertEqual(loaded.displays, record.displays)
        XCTAssertEqual(loaded.disabled, record.disabled)
        XCTAssertEqual(loaded.bootSessionID, BootSession.identifier)
        XCTAssertEqual(try Data(contentsOf: files.recoveryURL), original)
    }
}
