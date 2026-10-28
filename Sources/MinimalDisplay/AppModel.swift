import AppKit
import Combine
import DisplayCore

final class AppModel: ObservableObject {
    @Published private(set) var profiles: [DisplayProfile] = []
    @Published private(set) var active: DisplayProfile?
    @Published private(set) var busy = true
    @Published private(set) var guardReady = false
    @Published private(set) var status = "正在检查系统并恢复上次状态…"
    @Published var errorMessage: String?
    @Published private(set) var recoveryRequired = false
    private(set) var configurationReadable = true
    let files = StateFiles()
    let store = ProfileStore()
    let driver = SystemDisplayDriver()
    private let worker = DispatchQueue(label: "local.minimaldisplay.transitions", qos: .userInitiated)
    private let recoveryGuard = RecoveryGuardClient()
    private lazy var session = DisplaySession(driver: driver, files: files, guardReady: { [weak self] in self?.recoveryGuard.ready == true })
    private var heartbeatTimer: Timer?
    private var terminating = false
    private var startupRecoveryLock: InstanceLock?

    var APIsAvailable: Bool { driver.virtualAPIAvailable && driver.disableAPIAvailable }
    var canActivate: Bool { !busy && !terminating && !recoveryRequired && guardReady && APIsAvailable }
    var canEdit: Bool { !busy && !terminating && configurationReadable }

    func start(recoveryLock: InstanceLock) {
        startupRecoveryLock = recoveryLock
        do { profiles = try store.load() } catch {
            configurationReadable = false
            errorMessage = "无法读取虚拟屏配置，已保留原文件：\(error.localizedDescription)\n\(store.url.path)"
        }
        perform("正在恢复上次的显示状态…", reportFailure: true) { try self.session.restore() } completion: { [weak self] success in
            guard let self else { return }
            self.startupRecoveryLock = nil
            guard success else { return }
            do {
                let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MinimalDisplayRecovery")
                guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DisplayFailure("找不到独立恢复程序，请使用打包后的完整 App。") }
                try self.recoveryGuard.start(executable: executable)
                self.status = "使用原屏幕"
            } catch { self.errorMessage = "恢复进程启动失败：\(error.localizedDescription)" }
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            do { try self.recoveryGuard.beat() } catch {
                self.errorMessage = "恢复心跳写入失败：\(error.localizedDescription)"
            }
            let ready = self.recoveryGuard.ready
            if self.guardReady != ready { self.guardReady = ready }
            if !ready, self.active != nil, !self.busy, !self.terminating { self.restore() }
        }
        // Tracking an NSMenu or a modal sheet must not look like a hung main thread.
        if let heartbeatTimer { RunLoop.main.add(heartbeatTimer, forMode: .common) }
    }

    func activate(_ profile: DisplayProfile) {
        guard canActivate else { return }
        perform("正在切换到 \(profile.name)…") { try self.session.activate(profile) } completion: { [weak self] success in
            guard let self, success, !self.busy, !self.terminating else { return }
            self.status = "\(profile.name)  \(profile.label)"
        }
    }
    func restore(reportFailure: Bool = true, completion: ((Bool) -> Void)? = nil) {
        // Emergency restoration is allowed while another transition is in progress; serial queue orders it.
        perform("正在恢复物理屏…", reportFailure: reportFailure) { try self.session.restore() } completion: { [weak self] success in
            if success { self?.status = "使用原屏幕" }
            completion?(success)
        }
    }
    func save(_ input: DisplayProfile) -> Bool {
        guard canEdit else { return false }
        do {
            let profile = try input.validated()
            var updated = profiles
            if let i = updated.firstIndex(where: { $0.id == profile.id }) { updated[i] = profile } else { updated.append(profile) }
            try store.save(updated)
            profiles = updated
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func delete(_ profile: DisplayProfile) {
        guard canEdit else { return }
        guard active?.id != profile.id else { errorMessage = "请先恢复物理屏，再删除正在使用的配置。"; return }
        do {
            let updated = profiles.filter { $0.id != profile.id }
            try store.save(updated); profiles = updated
        } catch { errorMessage = error.localizedDescription }
    }

    private var operations = 0
    private func perform(_ message: String, reportFailure: Bool = true, _ work: @escaping () throws -> Void,
                         completion: ((Bool) -> Void)? = nil) {
        operations += 1; busy = true; status = message
        worker.async {
            let result = Result { try work() }
            let active = self.session.current
            let recoveryRequired = self.session.recoveryRequired || self.session.stalled
            DispatchQueue.main.async {
                self.operations -= 1; self.busy = self.operations > 0; self.active = active
                self.recoveryRequired = recoveryRequired
                if case .failure(let error) = result {
                    self.status = "恢复或切换未完成"
                    self.files.log(error.localizedDescription)
                    if reportFailure { self.errorMessage = error.localizedDescription }
                }
                if case .success = result { completion?(true) } else { completion?(false) }
            }
        }
    }

    /// Best-effort cleanup. The caller exits on either result and enforces an 8-second limit.
    func shutdown(completion: @escaping (Bool) -> Void) {
        terminating = true
        restore(reportFailure: false) { [weak self] success in
            guard let self else { return }
            if success {
                self.recoveryGuard.stop()
                self.heartbeatTimer?.invalidate()
                completion(true)
            } else {
                completion(false)
            }
        }
    }
}
