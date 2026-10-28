import Foundation
import Darwin

struct RecoveryProcessIdentity: Equatable {
    var pid: Int32
    var parentPID: Int32
    var userID: UInt32
    var startedSeconds: UInt64
    var startedMicroseconds: UInt64
    var executable: String
    var bundleID: String?

    var isOurHelper: Bool {
        userID == getuid() && bundleID == "local.waynewu.minimaldisplay" &&
            URL(fileURLWithPath: executable).lastPathComponent == "MinimalDisplayRecovery"
    }
    var isOurMainApp: Bool {
        userID == getuid() && bundleID == "local.waynewu.minimaldisplay" &&
            URL(fileURLWithPath: executable).lastPathComponent == "MinimalDisplay"
    }
}

public enum RecoveryProcessControl {
    static func identity(_ pid: Int32) -> RecoveryProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        var bundleURL = URL(fileURLWithPath: executable).deletingLastPathComponent()
        while bundleURL.path != "/", bundleURL.pathExtension != "app" { bundleURL.deleteLastPathComponent() }
        let identifier = bundleURL.pathExtension == "app" ? Bundle(url: bundleURL)?.bundleIdentifier : nil
        return RecoveryProcessIdentity(pid: pid, parentPID: Int32(info.pbi_ppid), userID: info.pbi_uid,
                                       startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec,
                                       executable: executable, bundleID: identifier)
    }

    static func mayStop(helper: RecoveryProcessIdentity, owner: RecoveryProcessIdentity?,
                        ready: GuardHeartbeat, heartbeat: GuardHeartbeat) -> Bool {
        guard helper.isOurHelper, helper.pid == ready.pid, ready.token == heartbeat.token else { return false }
        // An owned helper with a live main app is never an orphan, even when its heartbeat is old.
        if let owner, owner.pid == heartbeat.pid, owner.isOurMainApp, helper.parentPID == owner.pid { return false }
        return true
    }

    /// Called only after the new app has acquired app.lock. No journal is removed or rewritten.
    @discardableResult
    public static func stopOrphanedHelper(files: StateFiles) throws -> Bool {
        let decoder = JSONDecoder()
        guard let readyData = try? Data(contentsOf: files.directory.appendingPathComponent("guard-ready.json")),
              let ready = try? decoder.decode(GuardHeartbeat.self, from: readyData),
              let heartbeatData = try? Data(contentsOf: files.directory.appendingPathComponent("heartbeat.json")),
              let heartbeat = try? decoder.decode(GuardHeartbeat.self, from: heartbeatData),
              let helper = identity(ready.pid),
              mayStop(helper: helper, owner: identity(heartbeat.pid), ready: ready, heartbeat: heartbeat),
              identity(helper.pid) == helper else { return false }
        guard kill(helper.pid, SIGTERM) == 0 || errno == ESRCH else {
            throw DisplayFailure("无法结束本 App 的残留恢复进程（errno \(errno)）。")
        }
        files.log("Stopped orphaned recovery helper pid=\(helper.pid), path=\(helper.executable)")
        return true
    }
}
