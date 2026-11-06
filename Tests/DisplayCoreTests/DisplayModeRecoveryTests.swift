import XCTest
@testable import DisplayCore

final class DisplayModeRecoveryTests: XCTestCase {
    private let original = SavedDisplayMode(width: 2560, height: 1440, pixelWidth: 5120,
                                           pixelHeight: 2880, refreshRate: 60, ioFlags: 3, id: 42)

    func testSelectionRejectsReusedIDsAndPreservesHiDPIScalingAndRefreshRate() {
        let lowResolution = SavedDisplayMode(width: 1920, height: 1080, pixelWidth: 1920,
                                            pixelHeight: 1080, refreshRate: 60, ioFlags: 3, id: 42)
        let wrongScale = SavedDisplayMode(width: 2560, height: 1440, pixelWidth: 2560,
                                         pixelHeight: 1440, refreshRate: 60, ioFlags: 3, id: 43)
        let wrongRefresh = SavedDisplayMode(width: 2560, height: 1440, pixelWidth: 5120,
                                           pixelHeight: 2880, refreshRate: 30, ioFlags: 3, id: 44)
        let remapped = SavedDisplayMode(width: 2560, height: 1440, pixelWidth: 5120,
                                       pixelHeight: 2880, refreshRate: 59.94, ioFlags: 3, id: 45)
        XCTAssertEqual(original.select(from: [lowResolution, wrongScale, wrongRefresh, remapped]), remapped)
        XCTAssertNil(original.select(from: [lowResolution, wrongScale, wrongRefresh]))
        XCTAssertFalse(original.matches(lowResolution))
        XCTAssertFalse(original.matches(wrongScale))
    }

    func testSelectionPrefersOriginalIDButNeverChangesInterlacingOrStretching() {
        let equivalent = SavedDisplayMode(width: 2560, height: 1440, pixelWidth: 5120,
                                         pixelHeight: 2880, refreshRate: 60, ioFlags: 3, id: 100)
        let interlaced = SavedDisplayMode(width: 2560, height: 1440, pixelWidth: 5120,
                                         pixelHeight: 2880, refreshRate: 60, ioFlags: 0x43, id: 42)
        let stretched = SavedDisplayMode(width: 2560, height: 1440, pixelWidth: 5120,
                                        pixelHeight: 2880, refreshRate: 60, ioFlags: 0x803, id: 42)
        XCTAssertEqual(original.select(from: [equivalent, original]), original)
        XCTAssertNil(original.select(from: [interlaced, stretched]))
    }

    func testLegacyJournalWithoutModeCanStillBeRead() throws {
        let raw = Data("""
        {"displays":[{"id":1,"uuid":"physical","x":0,"y":0,"builtin":true}],"disabled":[]}
        """.utf8)
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: raw)
        XCTAssertNil(record.displays.first?.mode)
        XCTAssertNil(record.bootSessionID)
        XCTAssertEqual(try JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testRecoveryJournalRetainsPhysicalDisplayMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = StateFiles(directory: directory)
        try files.prepare()
        let mode: [String: Any] = ["width": 2560, "height": 1440, "pixelWidth": 5120,
                                  "pixelHeight": 2880, "refreshRate": 60.0, "ioFlags": 3, "id": 42]
        let display: [String: Any] = ["id": 1, "uuid": "physical", "x": 0, "y": 0,
                                     "builtin": false, "mode": mode]
        let raw = try JSONSerialization.data(withJSONObject: ["displays": [display], "disabled": [display]])
        try raw.write(to: files.recoveryURL)
        let record = try XCTUnwrap(files.readRecovery())
        try files.writeRecovery(record)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files.recoveryURL)) as? [String: Any])
        for key in ["displays", "disabled"] {
            let displays = try XCTUnwrap(result[key] as? [[String: Any]])
            let savedMode = try XCTUnwrap(displays.first?["mode"] as? [String: Any], "Recovery journal dropped the original 2K/HiDPI mode")
            XCTAssertEqual(savedMode["width"] as? Int, 2560)
            XCTAssertEqual(savedMode["height"] as? Int, 1440)
            XCTAssertEqual(savedMode["pixelWidth"] as? Int, 5120)
            XCTAssertEqual(savedMode["pixelHeight"] as? Int, 2880)
            XCTAssertEqual(savedMode["refreshRate"] as? Double, 60)
        }
    }
}
