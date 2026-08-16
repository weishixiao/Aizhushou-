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
    @State private var isInjecting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    @State private var forceJailbreak = false

    /// 越狱类型，注入时直接映射为硬编码路径，避免字符串被截断
    @State private var jailbreakType: JBType = .rootless

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)
    private let rt = JailbreakRuntime.shared

    private enum JBType: String, CaseIterable, Identifiable {
        case rootless = "Dopamine / palera1n（rootless）"
        case legacy = "unc0ver / Taurine（传统越狱）"
        case roothide = "Relaxin（RootHide）"
        var id: Self { self }
    }

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
                    Text("选择一个已编译好的 .dylib 或 .deb 插件文件（由 Theos 或其他方式编译生成）")
                }
                Section {
                    Picker("越狱类型", selection: $jailbreakType) {
                        ForEach(JBType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    HStack {
                        Text("注入目录")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Spacer()
                        Text(jailbreakType == .rootless ? "/var/jb/Library/MobileSubstrate/DynamicLibraries" : jailbreakType == .legacy ? "/Library/MobileSubstrate/DynamicLibraries" : "jbroot 命令动态获取")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                } header: {
                    Text("注入目录")
                } footer: {
                    Text("根据你的越狱类型选择，路径自动确定")
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
            DocumentPicker(allowedContentTypes: [.init(filenameExtension: "dylib") ?? .item, .init(filenameExtension: "deb") ?? .item]) { url in
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
            if url.pathExtension.lowercased() == "deb" {
                // 尝试解压 deb 提取 dylib
                extractDylibFromDeb(dest)
            } else {
                dylibURL = dest
            }
        }
    }

    /// 尝试从 .deb 包中提取 .dylib 文件
    private func extractDylibFromDeb(_ debURL: URL) {
        let debPath = debURL.path
        let extractDir = debURL.deletingLastPathComponent().appendingPathComponent("extracted_\(debURL.lastPathComponent)")
        try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let extractPath = extractDir.path

        // deb 是 ar 归档，内部包含 data.tar.xz（或 .gz/.lzma），再解压得到文件
        // 用系统命令逐层解压
        let rt = JailbreakRuntime.shared
        // 1. 解包 deb（ar 格式）
        let arCmd = "ar x \(debPath) --output=\(extractPath)"
        let (arCode, _) = rt.executeCommand(arCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        guard arCode == 0 else {
            // ar 可能不可用，尝试用 dpkg-deb
            let dpkgCmd = "dpkg-deb -x \(debPath) \(extractPath)"
            let (dpkgCode, _) = rt.executeCommand(dpkgCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
            guard dpkgCode == 0 else {
                dylibURL = nil
                return
            }
            // 解压后找到第一个 .dylib
            if let found = findFirstDylib(in: extractPath) {
                dylibURL = URL(fileURLWithPath: found)
            }
            return
        }

        // 2. 找到 data.tar.*
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: extractPath) else { return }
        var dataTar: String?
        for f in files where f.hasPrefix("data.tar") {
            dataTar = (extractPath as NSString).appendingPathComponent(f)
        }
        guard let dataTar else {
            // 尝试直接找 dylib
            if let found = findFirstDylib(in: extractPath) {
                dylibURL = URL(fileURLWithPath: found)
            }
            return
        }

        // 3. 解压 data.tar（根据后缀选择解压方式）
        let dataTarName = (dataTar as NSString).lastPathComponent
        let dataDir = (extractPath as NSString).appendingPathComponent("data")
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

        let uncompressCmd: String
        if dataTarName.hasSuffix(".xz") {
            uncompressCmd = "tar -xJf \(dataTar) -C \(dataDir)"
        } else if dataTarName.hasSuffix(".gz") {
            uncompressCmd = "tar -xzf \(dataTar) -C \(dataDir)"
        } else if dataTarName.hasSuffix(".lzma") {
            uncompressCmd = "tar -xf \(dataTar) --lzma -C \(dataDir)"
        } else {
            uncompressCmd = "tar -xf \(dataTar) -C \(dataDir)"
        }
        let (tarCode, _) = rt.executeCommand(uncompressCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        guard tarCode == 0 else {
            if let found = findFirstDylib(in: extractPath) {
                dylibURL = URL(fileURLWithPath: found)
            }
            return
        }

        // 4. 从 data 目录找 .dylib
        if let found = findFirstDylib(in: dataDir) {
            dylibURL = URL(fileURLWithPath: found)
        }
    }

    /// 递归在目录中查找第一个 .dylib 文件
    private func findFirstDylib(in dir: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(atPath: dir) else { return nil }
        for case let path as String in enumerator where path.hasSuffix(".dylib") {
            return (dir as NSString).appendingPathComponent(path)
        }
        return nil
    }

    private func startInject() {
        guard let dylibURL else { return }
        let dylibPath = dylibURL.path
        let ext = dylibURL.pathExtension.lowercased()
        if ext == "deb" && !dylibPath.hasSuffix(".dylib") {
            errorMessage = "无法从 .deb 包中提取 dylib 文件，请确认 deb 内包含 .dylib 插件"
            return
        }
        // 构建注入目录路径
        let dir: String = {
            switch jailbreakType {
            case .rootless:
                // 字符拼接，防止编译器截断字符串常量
                var path = "/"
                path += "var"; path += "/"
                path += "jb"; path += "/"
                path += "Library"; path += "/"
                path += "MobileSubstrate"; path += "/"
                path += "DynamicLibraries"
                return path
            case .legacy:
                var path = "/"
                path += "Library"; path += "/"
                path += "MobileSubstrate"; path += "/"
                path += "DynamicLibraries"
                return path
            case .roothide:
                // 通过 jbroot 命令获取 RootHide 真实路径
                let (code, output) = rt.executeCommand("jbroot /Library/MobileSubstrate/DynamicLibraries", environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
                if code == 0 {
                    let jbPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !jbPath.isEmpty { return jbPath }
                }
                // 如果 jbroot 命令失败，提示用户
                errorMessage = "无法获取 RootHide 注入目录，请确认：\n1. TrollStore 中已开启 App 的所有权限\n2. 设备已越狱\n3. 可尝试选择其他越狱类型"
                return ""
            }
        }()
        if dir.isEmpty { return }

        isInjecting = true
        resultMessage = nil
        errorMessage = nil

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