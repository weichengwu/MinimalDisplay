import XCTest
@testable import DisplayCore

private final class FakeScreen: VirtualScreen {
    let id: UInt32
    let settingsApplied: Bool
    let released: () -> Void
    init(id: UInt32, settingsApplied: Bool, released: @escaping () -> Void) {
        self.id = id; self.settingsApplied = settingsApplied; self.released = released
    }
    deinit { released() }
}

private final class FakeDriver: DisplayDriver {
    var virtualAPIAvailable = true
    var disableAPIAvailable = true
    var events: [String] = []
    let builtin = SavedDisplay(id: 1, uuid: "builtin", x: 0, y: 0, builtin: true)
    let external = SavedDisplay(id: 2, uuid: "external", x: 1920, y: 0, builtin: false)
    var active: Set<UInt32> = [1, 2]
    var nextID: UInt32 = 100
    var exactMode = true
    var applySettings = true
    var comesOnline = true
    var failMain = false
    var failDisable = false
    var failRestore = false
    var stallMain = false
    var beforeDisable: (() throws -> Void)?
    var afterMain: (() -> Void)?
    func snapshot() throws -> [SavedDisplay] { events.append("snapshot"); return [builtin, external] }
    func create(_ profile: DisplayProfile) throws -> VirtualScreen {
        let id = nextID; nextID += 1
        events.append("create:\(id)")
        if comesOnline { active.insert(id) }
        return FakeScreen(id: id, settingsApplied: applySettings) { [weak self] in
            self?.events.append("release:\(id)"); self?.active.remove(id)
        }
    }
    func isActive(_ id: UInt32) -> Bool { active.contains(id) }
    func matches(_ id: UInt32, profile: DisplayProfile) -> Bool { events.append("mode:\(id)"); return exactMode }
    func makeMain(_ id: UInt32) throws {
        events.append("main:\(id)")
        if failMain || stallMain { throw DisplayFailure("main failed", stalled: stallMain) }
        afterMain?()
    }
    func disable(_ displays: [SavedDisplay]) throws {
        try beforeDisable?()
        events.append("disable:\(displays.map { String($0.id) }.joined(separator: ","))")
        displays.forEach { active.remove($0.id) }
        if failDisable { throw DisplayFailure("partial disable failed") }
    }
    func restore(_ record: RecoveryRecord) throws {
        events.append("restore")
        if failRestore { throw DisplayFailure("restore failed") }
        record.displays.forEach { active.insert($0.id) }
    }
}

final class DisplaySessionTests: XCTestCase {
    private var directory: URL!
    private var files: StateFiles!
    private var clock: Date!
    private var driver: FakeDriver!
    private var guardReady = true
    private var session: DisplaySession!
    private let first = DisplayProfile(name: "平板", width: 2360, height: 1640, hiDPI: true)
    private let second = DisplayProfile(name: "桌面", width: 1920, height: 1080)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = StateFiles(directory: directory); try files.prepare()
        clock = Date(timeIntervalSince1970: 100)
        driver = FakeDriver(); guardReady = true
        session = DisplaySession(driver: driver, files: files,
                                 guardReady: { [unowned self] in self.guardReady },
                                 pause: { [unowned self] in self.clock += $0 },
                                 now: { [unowned self] in self.clock })
    }
    override func tearDownWithError() throws {
        session = nil; driver = nil
        try FileManager.default.removeItem(at: directory)
    }
    func testActivationVerifiesModeAndMainBeforeDisablingAllOriginalDisplays() throws {
        driver.beforeDisable = { [unowned self] in
            let record = try XCTUnwrap(self.files.readRecovery())
            XCTAssertEqual(record.disabled, [self.driver.builtin, self.driver.external], "Persist ALL recovery targets BEFORE disable")
        }
        try session.activate(first)
        XCTAssertEqual(driver.events, ["snapshot", "create:100", "mode:100", "main:100", "disable:1,2"])
        XCTAssertFalse(driver.active.contains(1))
        XCTAssertFalse(driver.active.contains(2), "External display must be disabled too")
        XCTAssertTrue(driver.active.contains(100), "Chosen virtual screen must remain active")
        XCTAssertEqual(session.current, first)
    }
    func testFastSwitchRetainsOldDisplayUntilReplacementIsMain() throws {
        try session.activate(first)
        try session.activate(second)
        let main = try XCTUnwrap(driver.events.firstIndex(of: "main:101"))
        let release = try XCTUnwrap(driver.events.firstIndex(of: "release:100"))
        XCTAssertLessThan(main, release)
        XCTAssertGreaterThanOrEqual(clock.timeIntervalSince1970, 103)
        XCTAssertEqual(driver.events.filter { $0 == "snapshot" }.count, 1)
        XCTAssertEqual(session.current, second)
    }
    func testSameProfileDoesNotRecreateDisplay() throws {
        try session.activate(first)
        let previous = driver.events
        try session.activate(first)
        XCTAssertEqual(driver.events, previous + ["mode:100"])
    }
    func testSelectingSameProfileDisablesReenabledExternalAgain() throws {
        try session.activate(first)
        driver.active.insert(2)
        try session.activate(first)
        XCTAssertFalse(driver.active.contains(2))
        XCTAssertTrue(driver.active.contains(101))
        XCTAssertEqual(driver.events.filter { $0.hasPrefix("disable:") }, ["disable:1,2", "disable:2"])
    }
    func testRestoreEnablesOriginalBeforeReleasingVirtualScreen() throws {
        try session.activate(first)
        try session.restore()
        XCTAssertEqual(Array(driver.events.suffix(2)), ["restore", "release:100"])
        XCTAssertNil(session.current)
        XCTAssertNil(try files.readRecovery())
        XCTAssertTrue(driver.active.contains(1))
        XCTAssertTrue(driver.active.contains(2))
    }
    func testMissingGuardPreventsAllMutations() {
        guardReady = false
        XCTAssertThrowsError(try session.activate(first))
        XCTAssertTrue(driver.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.recoveryURL.path))
    }
    func testGuardLostAfterMainDoesNotDisableBuiltin() {
        driver.afterMain = { [unowned self] in self.guardReady = false }
        XCTAssertThrowsError(try session.activate(first))
        XCTAssertFalse(driver.events.contains(where: { $0.hasPrefix("disable:") }))
        XCTAssertTrue(driver.active.contains(1))
        XCTAssertNil(session.current)
    }
    func testMissingPrivateAPILeavesCurrentDisplaysAlone() {
        driver.disableAPIAvailable = false
        XCTAssertThrowsError(try session.activate(first))
        XCTAssertTrue(driver.events.isEmpty)
    }
    func testWrongFramebufferSizeDoesNotDisableBuiltin() {
        driver.exactMode = false
        XCTAssertThrowsError(try session.activate(first))
        XCTAssertFalse(driver.events.contains("main:100"))
        XCTAssertFalse(driver.events.contains(where: { $0.hasPrefix("disable:") }))
        XCTAssertTrue(driver.events.contains("restore"))
        XCTAssertTrue(driver.active.contains(1))
    }
    func testPartialDisableFailureRollsBackUsingDurableRecord() throws {
        driver.failDisable = true
        XCTAssertThrowsError(try session.activate(first))
        XCTAssertTrue(driver.active.contains(1))
        XCTAssertEqual(Array(driver.events.suffix(2)), ["restore", "release:100"])
        XCTAssertNil(try files.readRecovery())
    }
    func testFailedRestoreKeepsRecoveryRecordAndVirtualScreen() throws {
        try session.activate(first)
        driver.failRestore = true
        XCTAssertThrowsError(try session.restore())
        XCTAssertNotNil(try files.readRecovery())
        XCTAssertFalse(driver.events.contains("release:100"))
        let previous = driver.events
        XCTAssertThrowsError(try session.activate(second))
        XCTAssertEqual(driver.events, previous, "Cannot create another display while recovery is unresolved")
        driver.failRestore = false
        try session.restore()
        XCTAssertFalse(session.recoveryRequired)
    }
    func testWindowServerTimeoutStopsFurtherTopologyChanges() throws {
        driver.stallMain = true
        XCTAssertThrowsError(try session.activate(first))
        XCTAssertTrue(session.stalled)
        XCTAssertFalse(driver.events.contains("release:100"))
        let previous = driver.events
        XCTAssertThrowsError(try session.activate(second))
        XCTAssertEqual(previous, driver.events)
        XCTAssertNotNil(try files.readRecovery())
    }
    func testNeverOnlineScreenIsRetainedAndOriginalIsRestored() throws {
        driver.comesOnline = false
        XCTAssertThrowsError(try session.activate(first))
        XCTAssertTrue(driver.active.contains(1))
        XCTAssertFalse(driver.events.contains(where: { $0.hasPrefix("disable:") }))
        XCTAssertFalse(driver.events.contains("release:100"))
        XCTAssertNotNil(try files.readRecovery())
    }
    func testFailedSettingsDoesNotReleaseAnImmatureScreen() {
        driver.applySettings = false
        XCTAssertThrowsError(try session.activate(first))
        XCTAssertGreaterThanOrEqual(clock.timeIntervalSince1970, 103)
        XCTAssertTrue(driver.events.contains("release:100"))
        XCTAssertFalse(driver.events.contains(where: { $0.hasPrefix("disable:") }))
    }
    func testStartupRecoveryDoesNotCreateVirtualScreen() throws {
        try files.writeRecovery(RecoveryRecord(displays: [driver.builtin, driver.external], disabled: [driver.builtin]))
        driver.active.remove(1)
        try session.restore()
        XCTAssertEqual(driver.events, ["restore"])
        XCTAssertTrue(driver.active.contains(1))
        XCTAssertNil(try files.readRecovery())
    }
}
