import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
import DisplayCore

let arguments = CommandLine.arguments
if arguments.count == 5, arguments[1] == "--runtime-fixture-owner" {
    exit(RecoveryRuntimeVerification.runOwner(directory: URL(fileURLWithPath: arguments[2]),
                                             helper: URL(fileURLWithPath: arguments[3]), held: arguments[4] == "held"))
}
if arguments.count == 5, arguments[1] == "--runtime-fixture-held-helper", let owner = Int32(arguments[3]) {
    exit(RecoveryRuntimeVerification.runHeldHelper(directory: URL(fileURLWithPath: arguments[2]), owner: owner, token: arguments[4]))
}
if arguments.contains("--verify-recovery-runtime") {
    do {
        guard let executable = Bundle.main.executableURL else { throw DisplayFailure("Missing executable") }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("MinimalDisplayRecovery")
        try RecoveryRuntimeVerification.run(executable: executable, helper: helper).forEach { print($0) }
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if arguments.count == 5, arguments[1] == "--watchdog", let owner = Int32(arguments[3]), owner > 1 {
    exit(RecoveryGuard.run(directory: URL(fileURLWithPath: arguments[2]), owner: owner, token: arguments[4]))
}
if arguments.contains("--diagnose") {
    let driver = SystemDisplayDriver()
    print("MinimalDisplay 1.0.7")
    print("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("CGVirtualDisplay: \(driver.virtualAPIAvailable)")
    print("CGSConfigureDisplayEnabled: \(driver.disableAPIAvailable)")
    print("Privacy permissions required: none (manual display control)")
    do {
        for display in try driver.snapshot() {
            print("display=\(display.id), builtin=\(display.builtin), origin=\(display.x),\(display.y), uuid=\(display.uuid)")
        }
        if let record = try StateFiles().readRecovery() {
            print("Recovery targets: \(record.disabled.map { String($0.id) }.joined(separator: ",")), bootScope=\(record.bootSessionID ?? "unavailable")")
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
if arguments.contains("--restore") {
    let files = StateFiles()
    do {
        try files.prepare()
        let lock = try InstanceLock(url: files.directory.appendingPathComponent("app.lock"))
        let guardLock = try InstanceLock(url: files.directory.appendingPathComponent("guard.lock"))
        try withExtendedLifetime((lock, guardLock)) {
            if let record = try files.readRecovery() {
                try SystemDisplayDriver().restore(record)
                try files.clearRecovery()
                print("原屏幕已恢复。")
            } else { print("没有待恢复的屏幕记录。") }
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var item: NSStatusItem!
    private var settings: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var appLock: InstanceLock?
    private var hotkey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var quitting = false
    private var exitReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opening the app again should show the existing instance, not contend with its helper.
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            existing.activate(options: [.activateAllWindows])
            exitReady = true; NSApp.terminate(nil); return
        }
        let startupRecoveryLock: InstanceLock
        do {
            try model.files.prepare()
            appLock = try InstanceLock(url: model.files.directory.appendingPathComponent("app.lock"))
            startupRecoveryLock = try StartupRecoveryLease.acquire(files: model.files)
        } catch {
            let alert = NSAlert(); alert.messageText = "无法启动屏幕切换"
            alert.informativeText = error.localizedDescription; alert.runModal()
            exitReady = true; NSApp.terminate(nil); return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "屏幕切换")
        item.button?.image?.isTemplate = true
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        installHotkey()
        model.start(recoveryLock: startupRecoveryLock)
        refresh()
        if model.profiles.isEmpty || model.errorMessage != nil { openSettings() }
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    private func refresh() {
        guard let menu = item?.menu else { return }
        menu.removeAllItems()
        menu.addItem(makeItem(model.status, nil, enabled: false))
        menu.addItem(.separator())
        if model.profiles.isEmpty { menu.addItem(makeItem("还没有虚拟屏", nil, enabled: false)) }
        for profile in model.profiles {
            let row = makeItem("\(profile.name)  \(profile.label)", #selector(selectScreen(_:)), enabled: model.canActivate)
            row.representedObject = profile.id.uuidString
            row.state = model.active == profile ? .on : .off
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let restore = makeItem("恢复物理屏并关闭虚拟屏", #selector(restoreScreen), enabled: !model.busy)
        restore.keyEquivalent = "9"; restore.keyEquivalentModifierMask = [.command, .control, .option]
        menu.addItem(restore)
        menu.addItem(makeItem("管理虚拟屏…", #selector(openSettings)))
        if !model.guardReady { menu.addItem(makeItem("恢复进程未就绪", nil, enabled: false)) }
        menu.addItem(.separator())
        menu.addItem(makeItem("退出", #selector(quit)))
        item.button?.toolTip = model.status
        if model.errorMessage != nil, settings?.isVisible != true { openSettings() }
    }
    private func makeItem(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self; row.isEnabled = enabled
        return row
    }
    @objc private func selectScreen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = model.profiles.first(where: { $0.id.uuidString == id }) else { return }
        model.activate(profile)
    }
    @objc private func restoreScreen() { model.restore() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "屏幕切换"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 480, height: 280)
            let visibleRows = min(max(model.profiles.count, 1), 5)
            window.setContentSize(NSSize(width: 540, height: CGFloat(max(280, 220 + visibleRows * 58))))
            window.center()
            settings = window
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        // Do not automatically focus an arbitrary control on mouse-driven opening.
        // Tab navigation still gives focused controls their native focus indicator.
        settings?.makeFirstResponder(nil)
    }
    private func installHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.model.restore() }
            return noErr
        }, 1, &spec, context, &eventHandler)
        let identifier = EventHotKeyID(signature: OSType(0x4D445350), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_9), UInt32(cmdKey | controlKey | optionKey), identifier,
                                        GetApplicationEventTarget(), 0, &hotkey)
        if status != noErr || handlerStatus != noErr {
            model.errorMessage = "恢复快捷键 ⌃⌥⌘9 注册失败，可能被其他 App 占用。菜单恢复和独立恢复进程仍可使用。"
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if exitReady || quitting { return .terminateNow }
        quitting = true
        let finish = { [weak self] in
            guard let self else { return }
            guard !self.exitReady else { return }
            self.exitReady = true
            NSApp.terminate(nil)
        }
        model.shutdown { _ in finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: finish)
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
