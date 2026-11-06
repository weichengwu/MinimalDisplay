import XCTest
import CoreFoundation
import Carbon.HIToolbox
@testable import DisplayCore

private final class FakeShortcutRegistrar: RestoreShortcutRegistrar {
    var secureInputEnabled = false
    var installStatus: OSStatus = noErr
    var conflicts = Set<UInt32>()
    var receive: ((UInt32) -> Void)?
    var registered: [UInt32: UInt32] = [:]
    var installations = 0
    func install(_ receive: @escaping (UInt32) -> Void) -> OSStatus {
        installations += 1
        if installStatus == noErr { self.receive = receive }
        return installStatus
    }
    func register(keyCode: UInt32, identifier: UInt32) -> OSStatus {
        guard !conflicts.contains(keyCode) else { return OSStatus(eventHotKeyExistsErr) }
        registered[keyCode] = identifier
        return noErr
    }
    func clear() { registered.removeAll(); receive = nil }
    func press(_ keyCode: Int) {
        if let id = registered[UInt32(keyCode)] { receive?(id) }
    }
}

final class RestoreShortcutTests: XCTestCase {
    func testBothPhysicalNineKeysTriggerRestoreAndStopUnregistersBoth() {
        let backend = FakeShortcutRegistrar()
        var restorations = 0
        let shortcut = RestoreShortcut(registrar: backend, enqueue: { $0() }, action: { restorations += 1 }, log: { _ in })
        XCTAssertNil(shortcut.refresh(reason: "launch"))
        XCTAssertEqual(restorations, 0, "Registration must never restore displays on its own")
        backend.press(kVK_ANSI_9)
        backend.press(kVK_ANSI_Keypad9)
        XCTAssertEqual(restorations, 2)
        shortcut.stop()
        backend.press(kVK_ANSI_9)
        XCTAssertTrue(backend.registered.isEmpty)
        XCTAssertEqual(restorations, 2)
    }

    func testWakeRefreshRestoresLostBindingsAndRejectsOldHandlerCallbacks() {
        let backend = FakeShortcutRegistrar()
        var restorations = 0
        let shortcut = RestoreShortcut(registrar: backend, enqueue: { $0() }, action: { restorations += 1 }, log: { _ in })
        XCTAssertNil(shortcut.refresh(reason: "launch"))
        let oldHandler = backend.receive
        backend.registered.removeAll() // Model WindowServer/session losing a previously successful registration.
        backend.press(kVK_ANSI_9)
        XCTAssertEqual(restorations, 0)
        XCTAssertNil(shortcut.refresh(reason: "wake"))
        oldHandler?(1)
        XCTAssertEqual(restorations, 0)
        backend.press(kVK_ANSI_9)
        XCTAssertEqual(restorations, 1)
        XCTAssertEqual(backend.installations, 2)
    }

    func testReceivedPressSurvivesRebindingFailureBeforeScheduledExecution() {
        let backend = FakeShortcutRegistrar()
        var queued: [() -> Void] = []
        var restorations = 0
        let shortcut = RestoreShortcut(registrar: backend, enqueue: { queued.append($0) },
                                       action: { restorations += 1 }, log: { _ in })
        XCTAssertNil(shortcut.refresh(reason: "launch"))
        backend.press(kVK_ANSI_9)
        backend.installStatus = OSStatus(eventInternalErr)
        XCTAssertNotNil(shortcut.refresh(reason: "display-configuration"))
        queued.forEach { $0() }
        XCTAssertEqual(restorations, 1, "An accepted recovery request must not be lost when a later rebind fails")
    }

    func testRepeatedPressesCoalesceAndTerminationCancelsPendingAction() {
        let backend = FakeShortcutRegistrar()
        var queued: [() -> Void] = []
        var restorations = 0
        var logs: [String] = []
        let shortcut = RestoreShortcut(registrar: backend, enqueue: { queued.append($0) },
                                       action: { restorations += 1 }, log: { logs.append($0) })
        XCTAssertNil(shortcut.refresh(reason: "launch"))
        backend.press(kVK_ANSI_9)
        backend.press(kVK_ANSI_9)
        backend.press(kVK_ANSI_Keypad9)
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(logs.contains { $0.hasPrefix("Hotkey received:") })
        XCTAssertEqual(restorations, 0)
        shortcut.stop()
        queued.forEach { $0() }
        XCTAssertEqual(restorations, 0)
    }

    func testKeypadConflictReportsErrorWhileMainKeyRemainsFunctional() {
        let backend = FakeShortcutRegistrar()
        backend.conflicts = [UInt32(kVK_ANSI_Keypad9)]
        var restorations = 0
        let shortcut = RestoreShortcut(registrar: backend, enqueue: { $0() }, action: { restorations += 1 }, log: { _ in })
        let failure = shortcut.refresh(reason: "launch")
        XCTAssertTrue(failure?.contains("小键盘 9") == true)
        backend.press(kVK_ANSI_9)
        backend.press(kVK_ANSI_Keypad9)
        XCTAssertEqual(restorations, 1)
    }

    func testHandlerFailureDoesNotLeaveOldRegistrationsActive() {
        let backend = FakeShortcutRegistrar()
        var restorations = 0
        let shortcut = RestoreShortcut(registrar: backend, enqueue: { $0() }, action: { restorations += 1 }, log: { _ in })
        XCTAssertNil(shortcut.refresh(reason: "launch"))
        backend.installStatus = OSStatus(eventInternalErr)
        XCTAssertNotNil(shortcut.refresh(reason: "session-active"))
        XCTAssertTrue(backend.registered.isEmpty)
        backend.press(kVK_ANSI_9)
        XCTAssertEqual(restorations, 0)
    }

    func testMainRunLoopDeliveryWorksInANonDefaultCommonMode() throws {
        guard Thread.isMainThread else { throw XCTSkip("Requires main thread run loop") }
        let loop = CFRunLoopGetMain()
        let mode = "MinimalDisplay.ShortcutTest.\(UUID().uuidString)" as CFString
        CFRunLoopAddCommonMode(loop, CFRunLoopMode(rawValue: mode))
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, timer, CFRunLoopMode(rawValue: mode))
        defer { CFRunLoopTimerInvalidate(timer) }
        var delivered = false
        RestoreShortcut.enqueueOnMainRunLoop { delivered = true; CFRunLoopStop(loop) }
        CFRunLoopRunInMode(CFRunLoopMode(rawValue: mode), 0.1, false)
        XCTAssertTrue(delivered, "A queued shortcut must run outside the default mode, without opening any UI")
    }
}
