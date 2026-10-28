import Foundation

/// Serial, synchronous transition logic. App calls this only on its dedicated worker queue.
/// Dependencies are injected so failure ordering is tested without changing real displays.
public final class DisplaySession {
    private let driver: DisplayDriver
    private let files: StateFiles
    private let guardReady: () -> Bool
    private let pause: (TimeInterval) -> Void
    private let now: () -> Date
    private var screens: [(screen: VirtualScreen, born: Date)] = []
    public private(set) var current: DisplayProfile?
    public private(set) var stalled = false
    public private(set) var recoveryRequired = false

    public init(driver: DisplayDriver = SystemDisplayDriver(), files: StateFiles = StateFiles(),
                guardReady: @escaping () -> Bool, pause: @escaping (TimeInterval) -> Void = Thread.sleep,
                now: @escaping () -> Date = Date.init) {
        self.driver = driver; self.files = files; self.guardReady = guardReady; self.pause = pause; self.now = now
    }

    public func activate(_ input: DisplayProfile) throws {
        let profile = try input.validated()
        guard !recoveryRequired else { throw DisplayFailure("上次恢复尚未完成，请先恢复物理屏，再切换虚拟屏。") }
        guard !stalled else { throw DisplayFailure("显示服务曾超时，已停止创建和移除虚拟屏。请恢复屏幕并注销或重启 Mac。") }
        guard driver.virtualAPIAvailable else { throw DisplayFailure("虚拟屏私有 API 不可用。") }
        guard driver.disableAPIAvailable else { throw DisplayFailure("屏幕启停私有 API 不可用，已取消切换。") }
        guard guardReady() else { throw DisplayFailure("独立恢复进程未就绪，未修改屏幕。请重新打开 App 后重试。") }
        if current == profile, let screen = screens.last?.screen,
           driver.isActive(screen.id), driver.matches(screen.id, profile: profile),
           let record = try files.readRecovery(), record.displays.allSatisfy({ !driver.isActive($0.id) }) { return }

        do {
            if try files.readRecovery() == nil {
                let original = try driver.snapshot()
                guard !original.isEmpty else { throw DisplayFailure("没有可恢复的原显示器，已取消切换。") }
                try files.writeRecovery(RecoveryRecord(displays: original))
            }
            let next = try driver.create(profile)
            screens.append((next, now())) // Retain before checking settings or online state.
            guard next.settingsApplied else { throw DisplayFailure("虚拟屏分辨率设置失败。") }
            try waitUntil("虚拟屏未能在 8 秒内上线。") { driver.isActive(next.id) }
            guard driver.matches(next.id, profile: profile) else { throw DisplayFailure("虚拟屏实际分辨率与配置不一致。") }
            pause(1)
            try driver.makeMain(next.id)
            pause(0.6)
            guard driver.isActive(next.id), guardReady() else { throw DisplayFailure("虚拟屏或恢复进程失去响应，未关闭物理屏。") }

            if var record = try files.readRecovery() {
                let physicalScreens = record.displays.filter { $0.id != next.id && driver.isActive($0.id) }
                if !physicalScreens.isEmpty {
                    // Durable intent must precede the private disable call, even for partial failures.
                    let disabledIDs = Set(record.disabled.map(\.id) + physicalScreens.map(\.id))
                    record.disabled = record.displays.filter { disabledIDs.contains($0.id) }
                    try files.writeRecovery(record)
                    try driver.disable(physicalScreens)
                    files.log("Disabled original displays: \(physicalScreens.map { String($0.id) }.joined(separator: ",")); kept virtual \(next.id)")
                    pause(1.5)
                }
            }
            // Create -> online -> exact mode -> main -> disable -> retire old display.
            try releaseScreens(except: next.id)
            current = profile
            files.log("Activated \(profile.name) \(profile.label), id=\(next.id)")
        } catch {
            recoveryRequired = true
            if (error as? DisplayFailure)?.configurationStalled == true { stalled = true }
            files.log("Activation failed: \(error.localizedDescription)")
            do { try restore() } catch let recoveryError {
                throw DisplayFailure("切换失败：\(error.localizedDescription) 恢复未完成：\(recoveryError.localizedDescription)", stalled: stalled)
            }
            throw error
        }
    }

    public func restore() throws {
        do {
            if let record = try files.readRecovery() {
                try driver.restore(record)
                pause(1.5)
            }
            current = nil
            // A stalled WindowServer must not receive further topology changes.
            if stalled, !screens.isEmpty {
                throw DisplayFailure("原屏幕已尝试恢复，但显示服务曾超时。为避免再次改变拓扑，虚拟屏对象已保留，请注销或重启 Mac。", stalled: true)
            }
            try releaseScreens(except: nil)
            try files.clearRecovery()
            recoveryRequired = false
            files.log("Original displays restored")
        } catch {
            recoveryRequired = true
            if (error as? DisplayFailure)?.configurationStalled == true { stalled = true }
            throw error
        }
    }

    private func releaseScreens(except keep: UInt32?) throws {
        let retiring = screens.filter { $0.screen.id != keep }.map { (id: $0.screen.id, born: $0.born) }
        guard !retiring.isEmpty else { return }
        try waitUntil("虚拟屏尚未稳定，暂时保留对象，请稍后恢复重试。") {
            retiring.allSatisfy { driver.isActive($0.id) && now().timeIntervalSince($0.born) >= 3 }
        }
        // No extra strong references survive this method. ARC removes them on the worker thread.
        screens.removeAll { $0.screen.id != keep }
        pause(1.5)
    }
    private func waitUntil(_ message: String, _ condition: () -> Bool) throws {
        let deadline = now().addingTimeInterval(8)
        while !condition() {
            guard now() < deadline else { throw DisplayFailure(message) }
            pause(0.2)
        }
    }
}
