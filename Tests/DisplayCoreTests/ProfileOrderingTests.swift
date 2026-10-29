import XCTest
@testable import DisplayCore

final class ProfileOrderingTests: XCTestCase {
    func testMovesPersistInBothDirectionsWithoutChangingProfiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let first = DisplayProfile(name: "桌面", width: 1920, height: 1080, hiDPI: true)
        let second = DisplayProfile(name: "平板", width: 1080, height: 810, hiDPI: true)
        let third = DisplayProfile(name: "手机", width: 1255, height: 578, hiDPI: false)
        try store.save([first, second, third])

        let movedUp = try store.move(id: third.id, by: -1, in: store.load())
        XCTAssertEqual(movedUp, [first, third, second])
        XCTAssertEqual(try ProfileStore(directory: directory).load(), movedUp)

        let movedDown = try store.move(id: first.id, by: 1, in: movedUp)
        XCTAssertEqual(movedDown, [third, first, second])
        XCTAssertEqual(try ProfileStore(directory: directory).load(), movedDown)
    }

    func testBoundaryAndStaleMovesLeaveSavedFileUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let first = DisplayProfile(name: "桌面", width: 1920, height: 1080)
        let second = DisplayProfile(name: "平板", width: 1080, height: 810)
        let profiles = [first, second]
        try store.save(profiles)
        let bytes = try Data(contentsOf: store.url)
        XCTAssertEqual(try store.move(id: first.id, by: -1, in: profiles), profiles)
        XCTAssertEqual(try store.move(id: second.id, by: 1, in: profiles), profiles)
        XCTAssertEqual(try store.move(id: UUID(), by: 1, in: profiles), profiles)
        XCTAssertEqual(try store.move(id: first.id, by: Int.max, in: profiles), profiles)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)

        let emptyStore = ProfileStore(directory: directory.appendingPathComponent("empty"))
        XCTAssertEqual(try emptyStore.move(id: UUID(), by: 1, in: []), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyStore.url.path))
    }

    func testFailedSaveDoesNotPublishANewOrderOrReplaceExistingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("not-a-directory")
        let bytes = Data("preserve this file".utf8)
        try bytes.write(to: blocked)
        let store = ProfileStore(directory: blocked)
        let first = DisplayProfile(name: "桌面", width: 1920, height: 1080)
        let second = DisplayProfile(name: "平板", width: 1080, height: 810)
        let original = [first, second]
        var visibleOrder = original
        XCTAssertThrowsError(visibleOrder = try store.move(id: second.id, by: -1, in: visibleOrder))
        XCTAssertEqual(visibleOrder, original)
        XCTAssertEqual(try Data(contentsOf: blocked), bytes)
    }
}
