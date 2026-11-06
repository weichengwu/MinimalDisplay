import Foundation
import CoreGraphics
import ColorSync
import DisplayBridge

public protocol VirtualScreen: AnyObject {
    var id: UInt32 { get }
    var settingsApplied: Bool { get }
}

public protocol DisplayDriver: AnyObject {
    var virtualAPIAvailable: Bool { get }
    var disableAPIAvailable: Bool { get }
    func snapshot() throws -> [SavedDisplay]
    func create(_ profile: DisplayProfile) throws -> VirtualScreen
    func isActive(_ id: UInt32) -> Bool
    func matches(_ id: UInt32, profile: DisplayProfile) -> Bool
    func makeMain(_ id: UInt32) throws
    func disable(_ displays: [SavedDisplay]) throws
    func restore(_ record: RecoveryRecord) throws
    func restoreModes(_ record: RecoveryRecord) throws
}

private final class ScreenHandle: VirtualScreen {
    let screen: MDVirtualScreen
    init(_ screen: MDVirtualScreen) { self.screen = screen }
    var id: UInt32 { screen.displayID }
    var settingsApplied: Bool { screen.settingsApplied }
}

/// All mutations run on DisplaySession's serial worker, never the AppKit main thread.
public final class SystemDisplayDriver: DisplayDriver {
    private let onlineQuery: () throws -> [UInt32]
    private let activeQuery: () throws -> [UInt32]
    private let readDisplay: (UInt32) throws -> SavedDisplay
    public convenience init(onlineDisplays: @escaping () throws -> [UInt32] = SystemDisplayDriver.online,
                            activeDisplays: @escaping () throws -> [UInt32] = SystemDisplayDriver.active) {
        self.init(onlineDisplays: onlineDisplays, activeDisplays: activeDisplays, readDisplay: Self.currentDisplay)
    }
    init(onlineDisplays: @escaping () throws -> [UInt32], activeDisplays: @escaping () throws -> [UInt32],
         readDisplay: @escaping (UInt32) throws -> SavedDisplay) {
        onlineQuery = onlineDisplays; activeQuery = activeDisplays
        self.readDisplay = readDisplay
    }
    public var virtualAPIAvailable: Bool { MDVirtualDisplayAvailable() }
    public var disableAPIAvailable: Bool { MDDisplayEnableAvailable() }

    public static func online() throws -> [UInt32] {
        try displays(CGGetOnlineDisplayList)
    }
    public static func active() throws -> [UInt32] {
        try displays(CGGetActiveDisplayList)
    }
    private static func displays(_ query: (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> CGError) throws -> [UInt32] {
        var count: UInt32 = 0
        try check(query(0, nil, &count), "读取显示器数量")
        guard count > 0 else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(count))
        try check(query(count, &ids, &count), "读取显示器列表")
        return Array(ids.prefix(Int(count)))
    }
    public func snapshot() throws -> [SavedDisplay] {
        let active = Set(try activeQuery())
        return try onlineQuery().filter { active.contains($0) }.map(readDisplay)
    }
    private static func currentDisplay(_ id: UInt32) throws -> SavedDisplay {
        guard let uuid = Self.uuid(id) else { throw DisplayFailure("显示器身份读取失败，未修改屏幕。") }
        guard let mode = CGDisplayCopyDisplayMode(id) else {
            throw DisplayFailure("无法读取物理屏原显示模式，未修改屏幕。请稍后重试。")
        }
        let origin = CGDisplayBounds(id).origin
        return SavedDisplay(id: id, uuid: uuid, x: Int32(origin.x), y: Int32(origin.y),
                            builtin: CGDisplayIsBuiltin(id) != 0, mode: SavedDisplayMode(mode))
    }
    public func create(_ profile: DisplayProfile) throws -> VirtualScreen {
        let profile = try profile.validated()
        guard virtualAPIAvailable else { throw DisplayFailure("当前系统缺少 CGVirtualDisplay 私有 API。") }
        guard let screen = autoreleasepool(invoking: {
            MDVirtualScreen(name: profile.name, width: UInt32(profile.pixelWidth), height: UInt32(profile.pixelHeight), hiDPI: profile.hiDPI)
        }) else { throw DisplayFailure("系统拒绝创建虚拟屏，原屏幕保持可用。") }
        return ScreenHandle(screen)
    }
    public func isActive(_ id: UInt32) -> Bool {
        guard let online = try? onlineQuery(), online.contains(id), let active = try? activeQuery() else { return false }
        return active.contains(id)
    }
    public func matches(_ id: UInt32, profile: DisplayProfile) -> Bool {
        guard let profile = try? profile.validated() else { return false }
        guard let mode = CGDisplayCopyDisplayMode(id) else { return false }
        return mode.pixelWidth == profile.pixelWidth && mode.pixelHeight == profile.pixelHeight &&
            mode.width == profile.width && mode.height == profile.height
    }
    public func makeMain(_ id: UInt32) throws {
        guard isActive(id) else { throw DisplayFailure("虚拟屏尚未上线，未关闭物理屏。") }
        let active = Set(try activeQuery())
        let ids = try onlineQuery().filter { active.contains($0) }
        let target = CGDisplayBounds(id).origin
        try transaction { config in
            for display in ids {
                let origin = CGDisplayBounds(display).origin
                try Self.check(CGConfigureDisplayOrigin(config, display, Int32(origin.x - target.x), Int32(origin.y - target.y)), "设置主屏位置")
            }
        }
        guard CGDisplayIsMain(id) != 0 else { throw DisplayFailure("系统未将虚拟屏设为主屏，未关闭物理屏。") }
    }
    public func disable(_ displays: [SavedDisplay]) throws {
        guard disableAPIAvailable else { throw DisplayFailure("物理屏关闭 API 不可用。") }
        try transaction { config in
            for display in displays {
                guard Self.uuid(display.id) == display.uuid else { throw DisplayFailure("物理屏身份变化，已取消关闭。") }
                try Self.check(MDConfigureDisplayEnabled(config, display.id, false), "关闭物理屏")
            }
        }
        // Disabled IDs disappear from the lists. Per-ID boolean APIs can return -1 for
        // a removed ID; treating that as true falsely rolls back a successful disable.
        let targets = Set(displays.map(\.id))
        let deadline = GuardHeartbeat.now + 3
        while true {
            let remaining = targets.intersection(try activeQuery())
            if remaining.isEmpty { break }
            guard GuardHeartbeat.now < deadline else {
                throw DisplayFailure("物理屏尚未全部停用，正在恢复（仍活动：\(remaining.sorted())）。")
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
    public func restore(_ record: RecoveryRecord) throws {
        // The OS may already have restored the displays before a retry or app restart.
        if originalConfigurationIsActive(record) { return }
        // Disabled IDs may disappear from online lists, so use saved UUIDs/IDs.
        if !record.disabled.isEmpty {
            let sameBoot = record.bootSessionID != nil && record.bootSessionID == BootSession.identifier
            let targets = try record.disabled.map { try resolve($0, required: true, allowOfflineID: sameBoot)! }
            let active = Set(try activeQuery())
            let inactive = targets.filter { !active.contains($0) }
            if !inactive.isEmpty {
                try transaction("启用物理屏") { config in
                    for id in inactive { try Self.check(MDConfigureDisplayEnabled(config, id, true), "恢复物理屏") }
                }
                let deadline = Date().addingTimeInterval(6)
                while !targets.allSatisfy(isActive), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
                guard targets.allSatisfy(isActive) else { throw DisplayFailure("物理屏尚未全部恢复，已保留恢复记录，请重试。") }
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
        if originalConfigurationIsActive(record) { return }
        try configureOriginalDisplays(resolveOriginalDisplays(record))
    }

    public func restoreModes(_ record: RecoveryRecord) throws {
        guard record.displays.contains(where: { $0.mode != nil }) else { return } // Legacy journals have no modes.
        if originalConfigurationIsActive(record) { return }
        let resolved = try resolveOriginalDisplays(record)
        if resolved.allSatisfy({ saved, id in
            guard let desired = saved.mode else { return true }
            return CGDisplayCopyDisplayMode(id).map { desired.matches(SavedDisplayMode($0)) } ?? false
        }) { return }
        // Removing the last virtual display can make WindowServer choose modes again.
        // Reapply modes and origins together, without disabling/enabling the physical screens again.
        try configureOriginalDisplays(resolved)
    }

    private func originalConfigurationIsActive(_ record: RecoveryRecord) -> Bool {
        guard !record.displays.isEmpty, let current = try? snapshot(), current.count == record.displays.count else { return false }
        let identities = Set(current.map(\.uuid))
        guard identities.count == current.count, identities == Set(record.displays.map(\.uuid)),
              record.disabled.allSatisfy({ identities.contains($0.uuid) }) else { return false }
        return record.displays.allSatisfy { saved in
            guard let observed = current.first(where: { $0.uuid == saved.uuid }),
                  observed.builtin == saved.builtin, observed.x == saved.x, observed.y == saved.y else { return false }
            guard let desired = saved.mode else { return true }
            return observed.mode.map { desired.matches($0) } ?? false
        }
    }

    private func resolveOriginalDisplays(_ record: RecoveryRecord) throws -> [(SavedDisplay, UInt32)] {
        let disabled = Set(record.disabled.map(\.uuid))
        let resolved = try record.displays.compactMap { saved -> (SavedDisplay, UInt32)? in
            let required = saved.builtin || disabled.contains(saved.uuid)
            guard let id = try resolve(saved, required: required), isActive(id) else {
                if required { throw DisplayFailure("原显示器尚未上线，已保留恢复记录，请重试。") }
                return nil
            }
            return (saved, id)
        }
        guard !resolved.isEmpty else { throw DisplayFailure("未找到可恢复的原显示器，保留虚拟屏和恢复记录。") }
        return resolved
    }

    private func configureOriginalDisplays(_ resolved: [(SavedDisplay, UInt32)]) throws {
        let planned = try resolved.map { saved, id -> (SavedDisplay, UInt32, CGDisplayMode?) in
            guard let desired = saved.mode else { return (saved, id, nil) }
            if let current = CGDisplayCopyDisplayMode(id), desired.matches(SavedDisplayMode(current)) {
                return (saved, id, current)
            }
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let available = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            guard let selected = desired.select(from: available.map { SavedDisplayMode($0) }),
                  let mode = available.first(where: { SavedDisplayMode($0) == selected }) else {
                throw DisplayFailure("物理屏原分辨率 \(desired.width) × \(desired.height)（\(desired.pixelWidth) × \(desired.pixelHeight) 像素，\(desired.refreshRate) Hz）暂不可用，恢复记录已保留，请重试。")
            }
            return (saved, id, mode)
        }
        let originals = Set(resolved.map { $0.1 })
        // Move our temporary displays away from (0,0) before restoring the original main display.
        let temporary = try onlineQuery().filter { !originals.contains($0) && CGDisplayVendorNumber($0) == 0x4D44 }
        let right = resolved.map { Int($0.0.x) + ($0.0.mode?.width ?? Int(CGDisplayBounds($0.1).width)) }.max() ?? 8192
        try transaction("恢复原分辨率和排列") { config in
            for (index, id) in temporary.enumerated() {
                try Self.check(CGConfigureDisplayOrigin(config, id, Int32(right + 100 + index * 9000), 0), "移动临时虚拟屏")
            }
            for (saved, id, mode) in planned {
                if let mode {
                    try Self.check(CGConfigureDisplayWithDisplayMode(config, id, mode, nil), "恢复物理屏分辨率")
                }
                try Self.check(CGConfigureDisplayOrigin(config, id, saved.x, saved.y), "恢复显示器排列")
            }
        }
        let deadline = GuardHeartbeat.now + 3
        while !resolved.allSatisfy({ saved, id in
            guard let desired = saved.mode else { return true }
            return CGDisplayCopyDisplayMode(id).map { desired.matches(SavedDisplayMode($0)) } ?? false
        }) {
            guard GuardHeartbeat.now < deadline else {
                throw DisplayFailure("物理屏已启用，但原分辨率或缩放尚未恢复，恢复记录已保留，请重试。")
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
    private static func uuid(_ id: UInt32) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }
    private func resolve(_ saved: SavedDisplay, required: Bool, allowOfflineID: Bool = false) throws -> UInt32? {
        try DisplayIdentityResolver(uuidForID: Self.uuid, idForUUID: { value in
            guard let uuid = CFUUIDCreateFromString(nil, value as CFString) else { return nil }
            let id = CGDisplayGetDisplayIDFromUUID(uuid)
            return id == kCGNullDirectDisplay ? nil : id
        }, isOnline: { id in (try? self.onlineQuery().contains(id)) ?? true })
            .resolve(saved, required: required, allowOfflineID: allowOfflineID)
    }
    private func transaction(_ operation: String = "显示配置", _ body: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try Self.check(CGBeginDisplayConfiguration(&config), "开始显示配置")
        guard let config else { throw DisplayFailure("系统没有返回显示配置事务。") }
        do { try body(config) } catch { CGCancelDisplayConfiguration(config); throw error }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success { CGCancelDisplayConfiguration(config) }
        try Self.check(result, "提交\(operation)")
    }
    private static func check(_ error: CGError, _ operation: String) throws {
        guard error == .success else {
            throw DisplayFailure("\(operation)失败（CGError \(error.rawValue)）。请恢复屏幕后重试。",
                                 stalled: error == .cannotComplete || error.rawValue == 1014)
        }
    }
}
