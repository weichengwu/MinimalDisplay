import Foundation

/// A new app owns this lease only until its own helper is launched.
public enum StartupRecoveryLease {
    public static func acquire(files: StateFiles, timeout: TimeInterval = 3) throws -> InstanceLock {
        let deadline = GuardHeartbeat.now + timeout
        var requestedCleanup = false
        while true {
            do { return try InstanceLock(url: files.directory.appendingPathComponent("guard.lock")) }
            catch InstanceLockFailure.occupied {
                if !requestedCleanup {
                    requestedCleanup = try RecoveryProcessControl.stopOrphanedHelper(files: files)
                }
                guard GuardHeartbeat.now < deadline else {
                    throw DisplayFailure("恢复进程尚未完成交接，请稍后重试。恢复记录已保留。")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
