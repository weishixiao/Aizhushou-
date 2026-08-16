import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 底部功能键——「应用」与「进程」共用的已安装应用列表。
/// 仅展示用户应用（排除 com.apple.* 系统应用），带搜索。
///
/// - 应用模式：点击某应用 → 进入「注入插件」入口
/// - 进程模式：点击某应用 → 填入逆向破解指令，发送到聊天框让 AI 处理
struct InstalledAppsView: View {
    enum Intent {
        case injectPlugin
        case addressToAI
    }

    let intent: Intent

    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var injectingApp: InstalledApp?

    /// 供「进程」模式把目标应用回传到主聊天视图（停留在主界面，由用户发指令）
    var onSendToChat: ((_ app: InstalledApp) -> Void)?

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)

    private var filteredApps: [InstalledApp] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.lowercased().contains(kw) || $0.bundleID.lowercased().contains(kw)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .navigationTitle(intent == .injectPlugin ? "选择应用 · 注入插件" : "选择应用 · 发往 AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear(perform: loadApps)
        .sheet(item: $injectingApp) { app in
            if #available(iOS 16.0, *) {
                InjectPluginSheet(app: app)
                    .presentationDetents([.medium, .large])
            } else {
                InjectPluginSheet(app: app)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索应用名称或包名…", text: $searchText)
                .font(.system(size: 15))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在扫描本机应用…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundColor(.orange)
                Text(loadError)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("重试") { loadApps() }
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredApps.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "iphone.slash")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("没有找到用户应用\n（已排除系统应用）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(filteredApps) { app in
                        AppRow(app: app)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                handleTap(on: app)
                            }
                    }
                } footer: {
                    Text(intent == .injectPlugin
                         ? "点击应用对其注入插件（需越狱最高权限）"
                         : "点击应用即发送逆向破解指令给 AI")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func handleTap(on app: InstalledApp) {
        switch intent {
        case .injectPlugin:
            injectingApp = app
        case .addressToAI:
            // 进程模式：只把目标应用回传给主界面（停留在聊天，用户再发指令）
            onSendToChat?(app)
            dismiss()
        }
    }

    private func loadApps() {
        isLoading = true
        loadError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = InstalledApps.shared.userApps()
            DispatchQueue.main.async {
                self.apps = apps.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                if apps.isEmpty {
                    self.loadError = "未能枚举到已安装应用。越狱环境下需具备读取 /var/containers 的权限。"
                }
                self.isLoading = false
            }
        }
    }
}

/// 应用行
struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.icon {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .cornerRadius(9)
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(.systemGray5))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "app.fill")
                            .foregroundColor(.white)
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// 注入插件表单（应用模式点击后弹出）
struct InjectPluginSheet: View {
    let app: InstalledApp
    @Environment(\.dismiss) private var dismiss

    @State private var tweakName = ""
    @State private var hookSpec = ""
    @State private var dylibURL: URL?
    @State private var showFilePicker = false
    @State private var targetDir = "/var/jb/Library/MobileSubstrate/DynamicLibraries"
    @State private var isInjecting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    @State private var forceJailbreak = false

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)
    private let rt = JailbreakRuntime.shared

    private var dylibFileInfo: String? {
        guard let url = dylibURL else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(url.lastPathComponent)（\(sizeStr)）"
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    keyValueRow("目标应用", value: app.displayName)
                    keyValueRow("bundleID", value: app.bundleID)
                }
                Section {
                    if let info = dylibFileInfo {
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundColor(accent)
                            Text(info)
                                .font(.callout)
                            Spacer()
                            Button("更换") { showFilePicker = true }
                                .font(.caption)
                        }
                    } else {
                        Button(action: { showFilePicker = true }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("选择 .dylib 插件文件")
                            }
                            .foregroundColor(accent)
                        }
                    }
                } header: {
                    Text("上传插件")
                } footer: {
                    Text("选择一个已编译好的 .dylib 插件文件（由 Theos / 其他方式编译生成）")
                }
                Section {
                    TextField("注入目录路径", text: $targetDir)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: 8) {
                        Text("快速选择：")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Button("/var/jb/...") { targetDir = "/var/jb/Library/MobileSubstrate/DynamicLibraries" }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        Button("/Library/...") { targetDir = "/Library/MobileSubstrate/DynamicLibraries" }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                } header: {
                    Text("注入目录")
                } footer: {
                    Text("rootless(Dopamine) → /var/jb/Library/MobileSubstrate/DynamicLibraries\n传统越狱(unc0ver) → /Library/MobileSubstrate/DynamicLibraries\n⚠️ 请直接点击上方按钮选择，不要手动输入，避免路径错误")
                }
                Section {
                    keyValueRow("当前权限", value: rt.isRoot ? "Root ✓" : "非 Root")
                    keyValueRow("越狱环境", value: rt.isJailbroken ? "已识别" : "未识别")
                    Toggle("手动开启越狱模式", isOn: $forceJailbreak)
                        .font(.callout)
                } footer: {
                    Text("自动检测不到时，可手动开启越狱模式以执行注入。需在越狱 / TrollStore 环境下。")
                }

                if let resultMessage {
                    Section {
                        Text(resultMessage)
                            .font(.callout)
                            .foregroundColor(accent)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("注入插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isInjecting ? "注入中…" : "开始注入") {
                        startInject()
                    }
                    .disabled(dylibURL == nil || isInjecting)
                }
            }
        }
        .onAppear {
            if UserDefaults.standard.object(forKey: JailbreakRuntime.overrideKey) != nil {
                forceJailbreak = UserDefaults.standard.bool(forKey: JailbreakRuntime.overrideKey)
            }
        }
        .onChange(of: forceJailbreak) { enabled in
            rt.setJailbreakOverride(enabled ? true : nil)
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(allowedContentTypes: [.init(filenameExtension: "dylib") ?? .item]) { url in
                importDylib(url)
            }
        }
    }

    private func importDylib(_ url: URL) {
        // 复制到沙盒文档目录
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let uploads = docs.appendingPathComponent("Uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let dest = uploads.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.copyItem(at: url, to: dest)
        if FileManager.default.fileExists(atPath: dest.path) {
            dylibURL = dest
        }
    }

    private func startInject() {
        guard let dylibURL else { return }
        isInjecting = true
        resultMessage = nil
        errorMessage = nil

        let dylibPath = dylibURL.path
        let dir = targetDir.trimmingCharacters(in: .whitespaces)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let msg = try InjectionManager.shared.injectDylib(at: dylibPath, into: app, targetDir: dir)
                DispatchQueue.main.async {
                    isInjecting = false
                    resultMessage = msg
                }
            } catch {
                DispatchQueue.main.async {
                    isInjecting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// iOS15 兼容的「标题-值」行
    private func keyValueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}