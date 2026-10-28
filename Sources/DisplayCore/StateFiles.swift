import Foundation
import Darwin

public struct SavedDisplay: Codable, Equatable {
    public let id: UInt32
    public let uuid: String
    public let x: Int32
    public let y: Int32
    public let builtin: Bool
    public init(id: UInt32, uuid: String, x: Int32, y: Int32, builtin: Bool) {
        self.id = id; self.uuid = uuid; self.x = x; self.y = y; self.builtin = builtin
    }
}

public struct RecoveryRecord: Codable, Equatable {
    public var displays: [SavedDisplay]
    public var disabled: [SavedDisplay]
    public var bootSessionID: String?
    public init(displays: [SavedDisplay], disabled: [SavedDisplay] = []) {
        self.displays = displays; self.disabled = disabled; self.bootSessionID = BootSession.identifier
    }
}

enum BootSession {
    static var identifier: String? {
        var length = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &length, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
    static var startedAt: Date? {
        var value = timeval(); var length = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &length, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }
    static func legacyJournalIsFromCurrentBoot(created: Date?, modified: Date?, bootStarted: Date?) -> Bool {
        guard let created, let modified, let bootStarted else { return false }
        return created >= bootStarted && modified >= bootStarted
    }
}

public struct StateFiles {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MinimalDisplay", isDirectory: true)
    }
    public let directory: URL
    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }
    public var recoveryURL: URL { directory.appendingPathComponent("recovery.json") }
    public func prepare() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    public func readRecovery() throws -> RecoveryRecord? {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return nil }
        var record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: recoveryURL))
        if record.bootSessionID == nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
            if BootSession.legacyJournalIsFromCurrentBoot(created: attributes[.creationDate] as? Date,
                                                         modified: attributes[.modificationDate] as? Date,
                                                         bootStarted: BootSession.startedAt) {
                record.bootSessionID = BootSession.identifier
            }
        }
        return record
    }
    public func writeRecovery(_ record: RecoveryRecord) throws {
        try prepare()
        try JSONEncoder().encode(record).write(to: recoveryURL, options: .atomic)
    }
    public func clearRecovery() throws {
        if FileManager.default.fileExists(atPath: recoveryURL.path) { try FileManager.default.removeItem(at: recoveryURL) }
    }
    public func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = directory.appendingPathComponent("events.log")
        try? prepare()
        // Bound log size; diagnostic history is local only.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_048_576 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd(); try? file.write(contentsOf: Data(line.utf8))
        }
    }
}

/// Held for the lifetime of a process. O_CLOEXEC prevents children retaining the app lock.
public enum InstanceLockFailure: LocalizedError {
    case occupied(URL)
    case system(URL, Int32)
    public var errorDescription: String? {
        switch self {
        case .occupied(let url): return "运行中的进程正在持有 \(url.lastPathComponent)。"
        case .system(let url, let code): return "无法访问进程锁 \(url.lastPathComponent)：\(String(cString: strerror(code)))（\(code)）。"
        }
    }
}

public final class InstanceLock {
    private var fd: Int32 = -1
    public init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw InstanceLockFailure.system(url, errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw InstanceLockFailure.occupied(url) }
            throw InstanceLockFailure.system(url, code)
        }
        // Take ownership only after success: throwing init must never close the same FD twice.
        fd = descriptor
    }
    deinit { if fd >= 0 { close(fd) } }
}
