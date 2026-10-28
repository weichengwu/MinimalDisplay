import XCTest
@testable import DisplayCore

final class ProfileAndGuardTests: XCTestCase {
    func testValidationRejectsUnsafeSizeButAllowsOddLogicalHiDPIAndPortrait() throws {
        XCTAssertThrowsError(try DisplayProfile(name: "屏幕", width: 0, height: 1080).validated())
        XCTAssertThrowsError(try DisplayProfile(name: "屏幕", width: 8193, height: 1080).validated())
        XCTAssertNoThrow(try DisplayProfile(name: "屏幕", width: 1921, height: 1080, hiDPI: true).validated())
        XCTAssertThrowsError(try DisplayProfile(name: "屏幕", width: 4097, height: 1080, hiDPI: true).validated())
        XCTAssertThrowsError(try DisplayProfile(name: "屏幕", width: Int.max, height: 1080, hiDPI: true).validated())
        XCTAssertThrowsError(try DisplayProfile(name: "\n", width: 1920, height: 1080).validated())
        XCTAssertThrowsError(try DisplayProfile(name: "横\n屏", width: 1920, height: 1080).validated())
        let portrait = try DisplayProfile(name: "  竖屏  ", width: 1080, height: 1920).validated()
        XCTAssertEqual(portrait.name, "竖屏")
    }
    func testHiDPIRendersDoublePixelsAndTogglePreservesInterfaceSize() throws {
        var profile = try DisplayProfile(name: "桌面", width: 1920, height: 1080, hiDPI: true).validated()
        XCTAssertEqual(profile.pixelWidth, 3840)
        XCTAssertEqual(profile.pixelHeight, 2160)
        profile.hiDPI = false
        XCTAssertEqual(profile.width, 1920)
        XCTAssertEqual(profile.height, 1080)
        XCTAssertEqual(profile.pixelWidth, 1920)
        XCTAssertEqual(profile.pixelHeight, 1080)
        let odd = try DisplayProfile(name: "竖屏", width: 1081, height: 1921, hiDPI: true).validated()
        XCTAssertEqual(odd.pixelWidth, 2162)
        XCTAssertEqual(odd.pixelHeight, 3842)
        let maximum = try DisplayProfile(name: "最大", width: 4096, height: 4096, hiDPI: true).validated()
        XCTAssertEqual(maximum.pixelWidth, 8192)
    }
    func testLegacyProfilesMigrateOnReadAndOnlyOnceOnSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let identifiers = [UUID(), UUID(), UUID()]
        let legacy: [[String: Any]] = [
            ["id": identifiers[0].uuidString, "name": "桌面", "width": 3840, "height": 2160, "hiDPI": true],
            ["id": identifiers[1].uuidString, "name": "平板", "width": 2360, "height": 1640, "hiDPI": true],
            ["id": identifiers[2].uuidString, "name": "普通", "width": 1920, "height": 1080, "hiDPI": false],
        ]
        let original = try JSONSerialization.data(withJSONObject: legacy)
        try original.write(to: store.url)
        let profiles = try store.load()
        XCTAssertEqual(profiles.map(\.id), identifiers)
        XCTAssertEqual(profiles.map(\.width), [1920, 1180, 1920])
        XCTAssertEqual(profiles.map(\.height), [1080, 820, 1080])
        XCTAssertEqual(profiles.map(\.pixelWidth), [3840, 2360, 1920])
        XCTAssertEqual(profiles.map(\.pixelHeight), [2160, 1640, 1080])
        XCTAssertEqual(try Data(contentsOf: store.url), original, "Read must preserve the original file")
        try store.save(profiles)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [[String: Any]])
        XCTAssertTrue(encoded.allSatisfy { $0["resolutionVersion"] as? Int == 2 })
        XCTAssertEqual(try store.load(), profiles, "New format must never be halved again")
        let minimum = legacy[0].merging(["width": 320, "height": 320]) { _, new in new }
        let migratedMinimum = try JSONDecoder().decode(DisplayProfile.self, from: JSONSerialization.data(withJSONObject: minimum))
        XCTAssertEqual(migratedMinimum.width, 160)
        XCTAssertEqual(migratedMinimum.pixelWidth, 320)
    }
    func testLegacyOddPixelSizesAndUnknownVersionsAreRejectedWithoutRounding() throws {
        let value: [String: Any] = ["id": UUID().uuidString, "name": "旧屏", "width": 1921, "height": 1080, "hiDPI": true]
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayProfile.self, from: JSONSerialization.data(withJSONObject: value)))
        let future = value.merging(["resolutionVersion": 3]) { _, new in new }
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayProfile.self, from: JSONSerialization.data(withJSONObject: future)))
        let current = value.merging(["resolutionVersion": 2]) { _, new in new }
        let profile = try JSONDecoder().decode(DisplayProfile.self, from: JSONSerialization.data(withJSONObject: current))
        XCTAssertEqual(profile.width, 1921)
        XCTAssertEqual(profile.pixelWidth, 3842)
    }
    func testProfilesRoundTripAndInvalidSavePreservesExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let profiles = [DisplayProfile(name: "我的平板", width: 2360, height: 1640, hiDPI: true)]
        try store.save(profiles)
        XCTAssertEqual(try store.load(), profiles)
        let original = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.save([DisplayProfile(name: "", width: 1920, height: 1080)]))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }
    func testCorruptProfilesAreReportedInsteadOfSilentlyOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }
    func testDuplicateProfileIDsCannotBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let profile = DisplayProfile(name: "屏幕", width: 1920, height: 1080)
        XCTAssertThrowsError(try store.save([profile, profile]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }
    func testHeartbeatRejectsStaleFutureWrongProcessAndWrongSession() {
        let beat = GuardHeartbeat(token: "session", pid: 42, uptime: 100)
        XCTAssertTrue(beat.healthy(token: "session", pid: 42, at: 105, maxAge: 12))
        XCTAssertFalse(beat.healthy(token: "session", pid: 42, at: 112, maxAge: 12))
        XCTAssertFalse(beat.healthy(token: "session", pid: 42, at: 99, maxAge: 12))
        XCTAssertFalse(beat.healthy(token: "old", pid: 42, at: 105, maxAge: 12))
        XCTAssertFalse(beat.healthy(token: "session", pid: 43, at: 105, maxAge: 12))
    }
    func testInstanceLockExcludesConcurrentAppAndAllowsReuseAfterRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("app.lock")
        do {
            let first = try InstanceLock(url: url)
            try withExtendedLifetime(first) { XCTAssertThrowsError(try InstanceLock(url: url)) }
        }
        XCTAssertNoThrow(try InstanceLock(url: url))
    }
    func testRecoveryPolicyNeverRestoresConcurrentlyWithAnUnresponsiveOwner() {
        XCTAssertEqual(RecoveryGuardPolicy.action(ownerExists: true, heartbeatHealthy: true, recoveryPending: true), .monitor)
        XCTAssertEqual(RecoveryGuardPolicy.action(ownerExists: true, heartbeatHealthy: false, recoveryPending: true), .stopOwnerThenRecover)
        XCTAssertEqual(RecoveryGuardPolicy.action(ownerExists: true, heartbeatHealthy: false, recoveryPending: false), .finish)
        XCTAssertEqual(RecoveryGuardPolicy.action(ownerExists: false, heartbeatHealthy: false, recoveryPending: true), .recover)
        XCTAssertEqual(RecoveryGuardPolicy.action(ownerExists: false, heartbeatHealthy: false, recoveryPending: false), .recover)
    }
}
