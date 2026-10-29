import AppKit
import SwiftUI
import DisplayCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: DisplayProfile?
    @State private var showingSystemStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("虚拟屏").font(.headline)
                Spacer()
                Button("添加虚拟屏") {
                    editing = DisplayProfile(name: "", width: 1920, height: 1080, hiDPI: true)
                }
                .disabled(!model.canEdit)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if model.profiles.isEmpty {
                ContentUnavailableView("还没有虚拟屏", systemImage: "display",
                                       description: Text("添加名称和分辨率，然后从菜单栏手动切换。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.profiles) { profile in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name)
                                        .fontWeight(.medium)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 14) {
                                        Text("\(profile.width) × \(profile.height)")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                        Toggle("高清", isOn: Binding(
                                            get: { profile.hiDPI },
                                            set: { setHiDPI($0, for: profile) }
                                        ))
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                        .fixedSize()
                                        .disabled(!model.canEdit)
                                        .help("开启按 2 倍像素渲染，关闭按 1 倍像素渲染；点切换应用")
                                        .accessibilityLabel("\(profile.name)的高清显示")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if model.active?.id == profile.id {
                                    Text(model.active == profile ? "使用中" : "待切换")
                                        .foregroundStyle(.secondary).fixedSize()
                                }
                                Button("切换") { model.activate(profile) }
                                    .disabled(!model.canActivate)
                                    .fixedSize()
                                Menu {
                                    profileActions(for: profile)
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("编辑、排序或删除虚拟屏")
                                .accessibilityLabel("\(profile.name)的更多操作")
                            }
                            .padding(.vertical, 12)
                            .contextMenu {
                                Button("切换到此虚拟屏") { model.activate(profile) }.disabled(!model.canActivate)
                                Divider()
                                profileActions(for: profile)
                            }
                            if profile.id != model.profiles.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider().padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.busy || model.recoveryRequired ? model.status : (model.active == nil ? "使用物理屏" : "仅使用虚拟屏"))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("切换后关闭全部物理屏").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("恢复物理屏") { model.restore() }.disabled(model.busy)
                }
                HStack(alignment: .firstTextBaseline) {
                    Button("系统状态…") { showingSystemStatus = true }.buttonStyle(.link)
                    Spacer()
                    Text("⌃⌥⌘9 恢复物理屏").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .font(.body)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 480, idealWidth: 540, minHeight: 280, idealHeight: 280)
        .sheet(item: $editing) { profile in ProfileEditor(profile: profile, model: model) }
        .sheet(isPresented: $showingSystemStatus) { SystemStatusView(model: model) }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil },
                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("关闭提示", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder
    private func profileActions(for profile: DisplayProfile) -> some View {
        Button("编辑配置") { editing = profile }.disabled(!model.canEdit)
        Divider()
        Button("上移") { model.move(profile, by: -1) }
            .disabled(!model.canEdit || model.profiles.first?.id == profile.id)
        Button("下移") { model.move(profile, by: 1) }
            .disabled(!model.canEdit || model.profiles.last?.id == profile.id)
        Divider()
        Button("删除配置", role: .destructive) { model.delete(profile) }
            .disabled(!model.canEdit || model.active?.id == profile.id)
    }

    private func setHiDPI(_ enabled: Bool, for profile: DisplayProfile) {
        var updated = profile
        updated.hiDPI = enabled
        _ = model.save(updated)
    }
}

private struct SystemStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("系统状态").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text("显示控制").foregroundStyle(.secondary)
                    Text(model.APIsAvailable ? "可用" : "当前系统不支持所需接口")
                }
                GridRow {
                    Text("恢复进程").foregroundStyle(.secondary)
                    Text(model.guardReady ? "已就绪" : "未就绪，暂不可切换")
                }
            }
            Text("无需辅助功能或屏幕录制权限。")
                .foregroundStyle(.secondary)
            HStack {
                Button("显示器设置") { openSettings("x-apple.systempreferences:com.apple.Displays-Settings.extension") }
                Button("隐私与安全性") { openSettings("x-apple.systempreferences:com.apple.preference.security") }
                Button("配置文件夹") { NSWorkspace.shared.open(model.files.directory) }
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func openSettings(_ value: String) {
        if let url = URL(string: value) { NSWorkspace.shared.open(url) }
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var name: String
    @State private var width: String
    @State private var height: String
    @State private var hiDPI: Bool
    @State private var validation: String?
    private let profile: DisplayProfile

    init(profile: DisplayProfile, model: AppModel) {
        self.profile = profile; self.model = model
        _name = State(initialValue: profile.name)
        _width = State(initialValue: String(profile.width)); _height = State(initialValue: String(profile.height))
        _hiDPI = State(initialValue: profile.hiDPI)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(profile.name.isEmpty ? "添加虚拟屏" : "编辑虚拟屏").font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                LabeledContent("界面分辨率") {
                    HStack {
                        TextField("宽", text: $width).frame(minWidth: 80).accessibilityLabel("界面分辨率宽度")
                        Text("×").foregroundStyle(.secondary)
                        TextField("高", text: $height).frame(minWidth: 80).accessibilityLabel("界面分辨率高度")
                    }
                    .labelsHidden()
                }
                Toggle("高清显示", isOn: $hiDPI)
                    .toggleStyle(.switch)
            }
            Text(hiDPI ? "按你想要的界面大小填写，App 自动以 2 倍像素渲染。" : "按你想要的界面大小填写，以 1 倍像素渲染。")
                .foregroundStyle(.secondary)
            if let preview {
                Text("实际像素：\(preview.pixelWidth) × \(preview.pixelHeight)")
                    .foregroundStyle(.secondary)
            }
            if let validation { Text(validation).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消编辑") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存配置", action: save).keyboardShortcut(.defaultAction).disabled(!model.canEdit)
            }
        }
        .padding(24).frame(width: 440)
    }
    private var preview: DisplayProfile? {
        guard let w = Int(width.trimmingCharacters(in: .whitespaces)), let h = Int(height.trimmingCharacters(in: .whitespaces)) else { return nil }
        return try? DisplayProfile(name: "预览", width: w, height: h, hiDPI: hiDPI).validated()
    }
    private func save() {
        guard let w = Int(width.trimmingCharacters(in: .whitespaces)), let h = Int(height.trimmingCharacters(in: .whitespaces)) else {
            validation = "宽和高需填写整数。"; return
        }
        do {
            let value = try DisplayProfile(id: profile.id, name: name, width: w, height: h, hiDPI: hiDPI).validated()
            if model.save(value) { dismiss() } else { validation = model.errorMessage; model.errorMessage = nil }
        } catch { validation = error.localizedDescription }
    }
}
