import Foundation
import Darwin

public struct GuardHeartbeat: Codable {
    public let token: String
    public let pid: Int32
    public let uptime: TimeInterval
    public init(token: String, pid: Int32, uptime: TimeInterval) {
        self.token = token; self.pid = pid; self.uptime = uptime
    }
    /// Awake time avoids treating system sleep as an unresponsive application.
    public static var now: TimeInterval { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }
    public func healthy(token: String, pid: Int32, at now: TimeInterval, maxAge: TimeInterval) -> Bool {
        self.token == token && self.pid == pid && now >= uptime && now - uptime < maxAge
    }
}

public final class RecoveryGuardClient {
    private let files: StateFiles
    private let token = UUID().uuidString
    private var process: Process?
    public init(files: StateFiles = StateFiles()) { self.files = files }
    private var heartbeatURL: URL { files.directory.appendingPathComponent("heartbeat.json") }
    private var readyURL: URL { files.directory.appendingPathComponent("guard-ready.json") }
    private var revokedURL: URL { files.directory.appendingPathComponent("revoked-\(token)") }

    public func start(executable: URL) throws {
        if process?.isRunning == true { return }
        try files.prepare()
        try beat()
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--watchdog", files.directory.path, String(getpid()), token]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
    }
    public func beat() throws {
        let heartbeat = GuardHeartbeat(token: token, pid: getpid(), uptime: GuardHeartbeat.now)
        try JSONEncoder().encode(heartbeat).write(to: heartbeatURL, options: .atomic)
    }
    public var ready: Bool {
        guard !FileManager.default.fileExists(atPath: revokedURL.path), process?.isRunning == true,
              let data = try? Data(contentsOf: readyURL), let beat = try? JSONDecoder().decode(GuardHeartbeat.self, from: data) else { return false }
        return beat.healthy(token: token, pid: process!.processIdentifier, at: GuardHeartbeat.now, maxAge: 5)
    }
    /// Called only after recovery succeeds. A failed recovery leaves the helper alive.
    public func stop() {
        try? FileManager.default.removeItem(at: heartbeatURL)
    }
}

public enum RecoveryGuardAction: Equatable { case monitor, finish, stopOwnerThenRecover, recover }
public enum RecoveryGuardPolicy {
    public static func action(ownerExists: Bool, heartbeatHealthy: Bool, recoveryPending: Bool) -> RecoveryGuardAction {
        if !ownerExists { return .recover }
        if heartbeatHealthy { return .monitor }
        // Missing heartbeat without a pending display mutation is a clean stop, not a reason to kill.
        return recoveryPending ? .stopOwnerThenRecover : .finish
    }
}

public enum RecoveryGuard {
    /// Runs as a child executable, with no AppKit or persistent login/background registration.
    public static func run(directory: URL, owner: Int32, token: String,
                           driver: DisplayDriver = SystemDisplayDriver()) -> Int32 {
        let files = StateFiles(directory: directory)
        do {
            try files.prepare()
            let lock = try InstanceLock(url: directory.appendingPathComponent("guard.lock"))
            return withExtendedLifetime(lock) {
                let readyURL = directory.appendingPathComponent("guard-ready.json")
                let heartbeatURL = directory.appendingPathComponent("heartbeat.json")
                guard getppid() == owner,
                      let initialData = try? Data(contentsOf: heartbeatURL),
                      let initial = try? JSONDecoder().decode(GuardHeartbeat.self, from: initialData),
                      initial.healthy(token: token, pid: owner, at: GuardHeartbeat.now, maxAge: 12) else {
                    files.log("Recovery helper rejected an unauthenticated parent")
                    return 1
                }
                var parentGone = false
                while true {
                    let ownBeat = GuardHeartbeat(token: token, pid: getpid(), uptime: GuardHeartbeat.now)
                    try? JSONEncoder().encode(ownBeat).write(to: readyURL, options: .atomic)
                    let heartbeat = (try? Data(contentsOf: heartbeatURL)).flatMap { try? JSONDecoder().decode(GuardHeartbeat.self, from: $0) }
                    let ownerExists = kill(owner, 0) == 0 && getppid() == owner
                    let healthy = ownerExists && heartbeat?.healthy(token: token, pid: owner, at: GuardHeartbeat.now, maxAge: 12) == true
                    let action = RecoveryGuardPolicy.action(ownerExists: ownerExists, heartbeatHealthy: healthy,
                                                            recoveryPending: FileManager.default.fileExists(atPath: files.recoveryURL.path))
                    if action == .finish {
                        try? FileManager.default.removeItem(at: readyURL)
                        return 0
                    }
                    if action == .recover || action == .stopOwnerThenRecover {
                        // Revocation prevents a recovered session from silently disabling displays again.
                        try? Data().write(to: directory.appendingPathComponent("revoked-\(token)"), options: .atomic)
                        if action == .stopOwnerThenRecover {
                            // Stop the exact parent before recovery so two processes never configure concurrently.
                            guard kill(owner, SIGKILL) == 0 || errno == ESRCH else {
                                files.log("Could not stop unresponsive parent; deferring recovery")
                                Thread.sleep(forTimeInterval: 1)
                                continue
                            }
                            // SIGKILL delivery is asynchronous. Wait for actual parent departure.
                            while getppid() == owner { Thread.sleep(forTimeInterval: 0.05) }
                        }
                        parentGone = true
                    }
                    if parentGone {
                        do {
                            if let record = try files.readRecovery() {
                                try driver.restore(record)
                                try files.clearRecovery()
                                files.log("Recovery helper restored original displays")
                            }
                            // Do not erase a newer helper's readiness marker.
                            if let data = try? Data(contentsOf: readyURL),
                               (try? JSONDecoder().decode(GuardHeartbeat.self, from: data))?.token == token {
                                try? FileManager.default.removeItem(at: readyURL)
                            }
                            try? FileManager.default.removeItem(at: directory.appendingPathComponent("revoked-\(token)"))
                            return 0
                        } catch {
                            files.log("Recovery helper will retry: \(error.localizedDescription)")
                        }
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        } catch {
            files.log("Recovery helper unavailable: \(error.localizedDescription)")
            return 1
        }
    }
}
