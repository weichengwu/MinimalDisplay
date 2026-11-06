import Foundation
import CoreFoundation
import Carbon.HIToolbox

/// No AppKit or keyboard monitoring. All registration lifecycle calls belong on the main thread.
protocol RestoreShortcutRegistrar: AnyObject {
    var secureInputEnabled: Bool { get }
    func install(_ receive: @escaping (UInt32) -> Void) -> OSStatus
    func register(keyCode: UInt32, identifier: UInt32) -> OSStatus
    func clear()
}

public final class RestoreShortcut {
    static let keys: [(id: UInt32, code: UInt32, name: String)] = [
        (1, UInt32(kVK_ANSI_9), "主键区 9"),
        (2, UInt32(kVK_ANSI_Keypad9), "小键盘 9"),
    ]
    private let registrar: RestoreShortcutRegistrar
    private let enqueue: (@escaping () -> Void) -> Void
    private let action: () -> Void
    private let log: (String) -> Void
    private var generation: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var enabledIDs = Set<UInt32>()
    private var pending = false

    public convenience init(action: @escaping () -> Void, log: @escaping (String) -> Void) {
        self.init(registrar: CarbonRestoreShortcutRegistrar(), enqueue: Self.enqueueOnMainRunLoop,
                  action: action, log: log)
    }
    init(registrar: RestoreShortcutRegistrar, enqueue: @escaping (@escaping () -> Void) -> Void,
         action: @escaping () -> Void, log: @escaping (String) -> Void) {
        self.registrar = registrar; self.enqueue = enqueue; self.action = action; self.log = log
    }

    /// Recreate both handler and registrations; old refs can survive a session/server transition.
    @discardableResult
    public func refresh(reason: String) -> String? {
        generation &+= 1
        let currentGeneration = generation
        enabledIDs.removeAll()
        registrar.clear()
        let status = registrar.install { [weak self] id in
            guard let self, self.generation == currentGeneration, self.enabledIDs.contains(id) else { return }
            // This log precedes scheduling: delivery and execution failures remain distinguishable.
            self.log("Hotkey received: id=\(id), secureInput=\(self.registrar.secureInputEnabled)")
            guard !self.pending else { return }
            self.pending = true
            let cancellationGeneration = self.cancellationGeneration
            self.enqueue { [weak self] in
                guard let self else { return }
                self.pending = false
                // A valid, already-received press must survive a registration refresh.
                guard self.cancellationGeneration == cancellationGeneration else { return }
                self.action()
            }
        }
        log("Hotkey handler refreshed: reason=\(reason), status=\(status), secureInput=\(registrar.secureInputEnabled)")
        guard status == noErr else {
            registrar.clear()
            return "恢复快捷键处理器安装失败（系统错误码 \(status)）。请从菜单恢复物理屏。"
        }
        var failures: [String] = []
        for key in Self.keys {
            let result = registrar.register(keyCode: key.code, identifier: key.id)
            log("Hotkey registered: reason=\(reason), key=\(key.name), status=\(result), exclusive=true")
            if result == noErr { enabledIDs.insert(key.id) }
            else { failures.append("\(key.name)（系统错误码 \(result)）") }
        }
        guard !failures.isEmpty else { return nil }
        return "恢复快捷键 ⌃⌥⌘9 注册失败：\(failures.joined(separator: "，"))。可能被其他 App 占用，可从菜单恢复物理屏。"
    }

    public func stop() {
        generation &+= 1
        cancellationGeneration &+= 1
        enabledIDs.removeAll()
        registrar.clear()
    }

    static func enqueueOnMainRunLoop(_ action: @escaping () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, action)
        CFRunLoopWakeUp(loop)
    }
    deinit { registrar.clear() }
}

private final class CarbonRestoreShortcutRegistrar: RestoreShortcutRegistrar {
    private var handler: EventHandlerRef?
    private var hotkeys: [EventHotKeyRef] = []
    private var receive: ((UInt32) -> Void)?
    private static let signature: OSType = 0x4D445350
    var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

    func install(_ receive: @escaping (UInt32) -> Void) -> OSStatus {
        self.receive = receive
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == CarbonRestoreShortcutRegistrar.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<CarbonRestoreShortcutRegistrar>.fromOpaque(context).takeUnretainedValue()
            owner.receive?(id.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(keyCode: UInt32, identifier: UInt32) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, UInt32(cmdKey | controlKey | optionKey),
            EventHotKeyID(signature: Self.signature, id: identifier), GetEventDispatcherTarget(),
            UInt32(kEventHotKeyExclusive), &reference)
        if status == noErr, let reference { hotkeys.append(reference) }
        return status == noErr && reference == nil ? OSStatus(eventInternalErr) : status
    }
    func clear() {
        hotkeys.forEach { UnregisterEventHotKey($0) }
        hotkeys.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        receive = nil
    }
}
