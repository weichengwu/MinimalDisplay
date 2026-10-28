import XCTest
@testable import DisplayCore

final class RecoveryRuntimeTests: XCTestCase {
    func testOrphanCleanupProtectsLiveOwnerAndRejectsOtherAppsOrUsers() {
        let owner = RecoveryProcessIdentity(pid: 40, parentPID: 1, userID: getuid(), startedSeconds: 1, startedMicroseconds: 0,
                                            executable: "/App.app/Contents/MacOS/MinimalDisplay", bundleID: "local.waynewu.minimaldisplay")
        var helper = RecoveryProcessIdentity(pid: 41, parentPID: 40, userID: getuid(), startedSeconds: 2, startedMicroseconds: 0,
                                             executable: "/App.app/Contents/MacOS/MinimalDisplayRecovery", bundleID: "local.waynewu.minimaldisplay")
        let ready = GuardHeartbeat(token: "session", pid: 41, uptime: 1)
        let heartbeat = GuardHeartbeat(token: "session", pid: 40, uptime: 1)
        XCTAssertFalse(RecoveryProcessControl.mayStop(helper: helper, owner: owner, ready: ready, heartbeat: heartbeat))
        helper.parentPID = 1
        XCTAssertTrue(RecoveryProcessControl.mayStop(helper: helper, owner: nil, ready: ready, heartbeat: heartbeat))
        XCTAssertFalse(RecoveryProcessControl.mayStop(helper: helper, owner: nil, ready: ready,
                                                    heartbeat: GuardHeartbeat(token: "other", pid: 40, uptime: 1)))
        helper.userID = getuid() + 1
        XCTAssertFalse(RecoveryProcessControl.mayStop(helper: helper, owner: nil, ready: ready, heartbeat: heartbeat))
        helper.userID = getuid(); helper.bundleID = "other.app"
        XCTAssertFalse(RecoveryProcessControl.mayStop(helper: helper, owner: nil, ready: ready, heartbeat: heartbeat))
    }
    func testFileSystemFailureIsNotReportedAsAStaleHelper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = StateFiles(directory: directory)
        try files.prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("guard.lock"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try StartupRecoveryLease.acquire(files: files)) { error in
            guard case InstanceLockFailure.system = error else { return XCTFail("Wrong error: \(error)") }
        }
    }
    func testImmediateRestartWaitsForPreviousHelperToReleaseItsLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = StateFiles(directory: directory)
        try files.prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = Process()
        previous.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        previous.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX); print('ready', flush=True); time.sleep(0.6)", directory.appendingPathComponent("guard.lock").path]
        let output = Pipe(); previous.standardOutput = output
        previous.standardError = FileHandle.nullDevice
        try previous.run()
        defer { if previous.isRunning { previous.terminate() }; previous.waitUntilExit() }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 6), Data("ready\n".utf8))
        let lease = try StartupRecoveryLease.acquire(files: files, timeout: 2)
        withExtendedLifetime(lease) { XCTAssertFalse(previous.isRunning) }
    }
}
