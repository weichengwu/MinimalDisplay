import Foundation
import Darwin

/// Process-level verification in a fresh temporary directory. Never creates a display or
/// invokes restore: normal fixtures have no journal; held-helper fixtures do no display work.
public enum RecoveryRuntimeVerification {
    private static func fixtureAllowed(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime-fixture").path)
    }

    public static func runHeldHelper(directory: URL, owner: Int32, token: String) -> Int32 {
        guard fixtureAllowed(directory), getppid() == owner else { return 2 }
        do {
            let lock = try InstanceLock(url: directory.appendingPathComponent("guard.lock"))
            return withExtendedLifetime(lock) {
                while true {
                    let ready = GuardHeartbeat(token: token, pid: getpid(), uptime: GuardHeartbeat.now)
                    try? JSONEncoder().encode(ready).write(to: directory.appendingPathComponent("guard-ready.json"), options: .atomic)
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        } catch { return 3 }
    }

    public static func runOwner(directory: URL, helper: URL, held: Bool) -> Int32 {
        guard fixtureAllowed(directory) else { return 2 }
        do {
            let files = StateFiles(directory: directory)
            let appLock = try InstanceLock(url: directory.appendingPathComponent("app.lock"))
            return try withExtendedLifetime(appLock) {
                let token = UUID().uuidString
                func beat() throws {
                    let heartbeat = GuardHeartbeat(token: token, pid: getpid(), uptime: GuardHeartbeat.now)
                    try JSONEncoder().encode(heartbeat).write(to: directory.appendingPathComponent("heartbeat.json"), options: .atomic)
                }
                try beat()
                let process = Process()
                process.executableURL = helper
                process.arguments = [held ? "--runtime-fixture-held-helper" : "--watchdog", directory.path, String(getpid()), token]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = GuardHeartbeat.now + 5
                while true {
                    try beat()
                    if let data = try? Data(contentsOf: directory.appendingPathComponent("guard-ready.json")),
                       let ready = try? JSONDecoder().decode(GuardHeartbeat.self, from: data), ready.pid == process.processIdentifier,
                       ready.token == token { break }
                    guard process.isRunning, GuardHeartbeat.now < deadline else { throw DisplayFailure("Fixture helper not ready") }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                try Data().write(to: directory.appendingPathComponent("owner-ready"))
                while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop-owner").path) {
                    try beat(); Thread.sleep(forTimeInterval: 0.05)
                }
                if held { process.terminate() }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("heartbeat.json"))
                files.log("Fixture owner exited")
                return 0
            }
        } catch { return 3 }
    }

    public static func run(executable: URL, helper: URL) throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MinimalDisplay-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [String] = []

        func prepare(_ name: String) throws -> StateFiles {
            let files = StateFiles(directory: root.appendingPathComponent(name))
            try files.prepare()
            try Data().write(to: files.directory.appendingPathComponent("runtime-fixture"))
            return files
        }
        func wait(_ description: String, timeout: TimeInterval = 5, until predicate: () -> Bool) throws {
            let deadline = GuardHeartbeat.now + timeout
            while !predicate() {
                guard GuardHeartbeat.now < deadline else { throw DisplayFailure("Runtime verification timed out: \(description)") }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        for index in 0..<3 {
            let files = try prepare("normal-\(index)")
            let appLock = try InstanceLock(url: files.directory.appendingPathComponent("app.lock"))
            try withExtendedLifetime(appLock) {
                var startup: InstanceLock? = try StartupRecoveryLease.acquire(files: files)
                withExtendedLifetime(startup) {}
                startup = nil
                let client = RecoveryGuardClient(files: files)
                try client.start(executable: helper)
                defer { client.stop() }
                try wait("helper ready") { try? client.beat(); return client.ready }
                do {
                    _ = try InstanceLock(url: files.directory.appendingPathComponent("app.lock"))
                    throw DisplayFailure("Runtime verification: child startup released the app lock")
                } catch InstanceLockFailure.occupied { /* Correct: duplicate launch is excluded. */ }
                client.stop()
                let next = try StartupRecoveryLease.acquire(files: files)
                try wait("helper stopped") { !client.ready }
                withExtendedLifetime(next) {}
            }
        }
        results.append("PASS: actual helper handshake, app-lock lifetime, graceful stop and immediate restart ×3")

        for held in [false, true] {
            let files = try prepare(held ? "stuck-orphan" : "live-owner")
            let owner = Process(); owner.executableURL = executable
            owner.arguments = ["--runtime-fixture-owner", files.directory.path, helper.path, held ? "held" : "normal"]
            owner.standardInput = FileHandle.nullDevice
            owner.standardOutput = FileHandle.nullDevice
            owner.standardError = FileHandle.nullDevice
            try owner.run()
            defer { if owner.isRunning { owner.terminate() }; owner.waitUntilExit() }
            try wait("owner ready") { FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("owner-ready").path) }
            let ready = try JSONDecoder().decode(GuardHeartbeat.self, from: Data(contentsOf: files.directory.appendingPathComponent("guard-ready.json")))
            let helperIdentity = RecoveryProcessControl.identity(ready.pid)
            defer {
                // Also clean up a fixture child if a later assertion fails.
                if let helperIdentity, helperIdentity.isOurHelper, RecoveryProcessControl.identity(ready.pid) == helperIdentity {
                    kill(ready.pid, SIGTERM)
                }
            }
            if !held {
                do {
                    _ = try StartupRecoveryLease.acquire(files: files, timeout: 0.2)
                    throw DisplayFailure("Runtime verification stole a live helper lease")
                } catch let failure as DisplayFailure {
                    guard failure.message.contains("交接") else { throw failure }
                }
                guard owner.isRunning, RecoveryProcessControl.identity(ready.pid) != nil else { throw DisplayFailure("Live owner/helper was terminated") }
                try Data().write(to: files.directory.appendingPathComponent("stop-owner"))
                try wait("graceful owner exit") { !owner.isRunning }
                let lease = try StartupRecoveryLease.acquire(files: files)
                withExtendedLifetime(lease) {}
                results.append("PASS: live owner/helper protected; graceful owner exit automatically hands over")
            } else {
                let journal = Data("fixture-journal-must-stay".utf8)
                try journal.write(to: files.recoveryURL)
                owner.terminate()
                try wait("crashed owner exit") { !owner.isRunning }
                let appLock = try InstanceLock(url: files.directory.appendingPathComponent("app.lock"))
                try withExtendedLifetime(appLock) {
                    let lease = try StartupRecoveryLease.acquire(files: files)
                    try wait("verified orphan helper exit") { RecoveryProcessControl.identity(ready.pid) == nil }
                    guard try Data(contentsOf: files.recoveryURL) == journal else { throw DisplayFailure("Runtime verification lost the recovery journal") }
                    withExtendedLifetime(lease) {}
                }
                results.append("PASS: stuck orphan helper automatically terminated; recovery journal preserved")
            }
        }
        results.append("PASS: temporary state only; no display creation, disable or restore was executed")
        return results
    }
}
