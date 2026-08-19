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
    @State private var fridaStatus: ProcessManager.FridaStatus?
    @State private var showFridaGuide = false

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
            if intent == .addressToAI {
                fridaGuideCard
            }
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
        .onAppear {
            loadApps()
            if intent == .addressToAI {
                fridaStatus = ProcessManager.shared.checkFridaStatus()
            }
        }
        .sheet(isPresented: $showFridaGuide) {
            FridaInstallGuideView(status: fridaStatus)
                .preferredColorScheme(.dark)
        }
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

    // MARK: - Frida 安装引导卡片

    @ViewBuilder
    private var fridaGuideCard: some View {
        if let status = fridaStatus, !status.isRunning {
            Button {
                showFridaGuide = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: status.isInstalled ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundColor(status.isInstalled ? .orange : .blue)
                        .font(.system(size: 18))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.isInstalled ? "Frida 已安装但未启动" : "使用内存修改需先安装 Frida")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        Text(status.summary)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(status.isInstalled ? Color.orange.opacity(0.08) : Color.blue.opacity(0.08))
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
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
    @State private var rootPassword = ""
    @State private var diagnosticResult: String?
    @State private var showNoSuAlert = false

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
                    Text("自动检测不到时，可手动开启越狱模式以执行注入。需在 Relaxin / 越狱环境下。")
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

                // 权限诊断 + root 密码
                Section {
                    HStack {
                        Text("root 密码")
                        Spacer()
                        TextField("alpine", text: $rootPassword)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.callout, design: .monospaced))
                    }
                    Button {
                        runDiagnostic()
                    } label: {
                        HStack {
                            Image(systemName: "stethoscope")
                            Text(diagnosticResult == nil ? "诊断权限" : "重新诊断")
                        }
                    }
                    .disabled(isInjecting)
                } footer: {
                    Text("默认密码为 alpine。诊断会测试 su 提权与 RootService 连通性。")
                }

                if let diagnosticResult {
                    Section {
                        Text(diagnosticResult)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    } header: {
                        Text("诊断结果")
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
            DocumentPicker(allowedContentTypes: injectableContentTypes) { url in
                importDylib(url)
            }
        }
        .alert("缺少 su 二进制", isPresented: $showNoSuAlert) {
            Button("复制安装命令") {
                UIPasteboard.general.string = "apt update && apt install sudo"
            }
            Button("关闭", role: .cancel) {}
        } message: {
            Text("未检测到 su/sudo，无法提权到 root。\n\n请在 Sileo 中安装 Sudo 包，或在 NewTerm 中执行：\n\napt update && apt install sudo")
        }
    }

    /// 插件注入允许的文件类型：deb 插件包 / dylib 动态库
    private var injectableContentTypes: [UTType] {
        [
            UTType(filenameExtension: "deb") ?? .data,
            UTType(filenameExtension: "dylib") ?? .data
        ]
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

    /// 尝试从 .deb 包中提取 .dylib 文件。
    /// 优先纯 Swift 解压（不依赖外部命令），失败时回退 dpkg-deb。
    private func extractDylibFromDeb(_ debURL: URL) {
        let rt = JailbreakRuntime.shared
        let jbPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin"
        let extractDir = debURL.deletingLastPathComponent().appendingPathComponent("extracted_\(debURL.lastPathComponent)")

        // 1. 纯 Swift 解压（Relaxin / 精简越狱环境最可靠）
        var swiftErrorDetail: String?
        do {
            let dylibs = try DebExtractor.extractDylibs(from: debURL, into: extractDir)
            if let first = dylibs.first {
                RuntimeLogger.shared.info("deb", "纯 Swift 解压成功，提取 dylib：\(first)")
                dylibURL = URL(fileURLWithPath: first)
                return
            }
            RuntimeLogger.shared.warning("deb", "纯 Swift 解压完成但未找到 .dylib，尝试 dpkg-deb 回退")
        } catch {
            let detail = error.localizedDescription
            swiftErrorDetail = detail
            RuntimeLogger.shared.warning("deb", "纯 Swift 解压失败（\(detail)），尝试 dpkg-deb 回退")
        }

        // 2. dpkg-deb 回退（PATH 覆盖 /var/jb/usr/bin）
        try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let (dpkgCode, dpkgOut) = rt.executeCommand(
            "dpkg-deb -x '\(debURL.path)' '\(extractDir.path)' 2>&1",
            environment: ["PATH": jbPath]
        )
        if dpkgCode == 0, let found = findFirstDylib(in: extractDir.path) {
            RuntimeLogger.shared.info("deb", "dpkg-deb 解压成功，提取 dylib：\(found)")
            dylibURL = URL(fileURLWithPath: found)
            return
        }

        let dpkgDetail = dpkgOut.contains("posix_spawn") ? "（dpkg-deb 命令不存在，请安装 dpkg）" : dpkgOut
        RuntimeLogger.shared.error("deb", "deb 解压全部失败：\(dpkgDetail.isEmpty ? "未知错误" : dpkgDetail)")
        dylibURL = nil
        var message = "无法从 .deb 包中提取 dylib 文件。"
        if let swiftErrorDetail {
            message += "\n\nSwift 解压原因：\(swiftErrorDetail)"
        }
        if !dpkgDetail.isEmpty {
            message += "\n\ndpkg-deb 回退：\(dpkgDetail)"
        }
        message += "\n\n请确认 deb 为 gzip 压缩且包内含 .dylib 插件。"
        errorMessage = message
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

        // 保存 root 密码（用于 su 密码回退）
        let pwd = rootPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(pwd.isEmpty ? "alpine" : pwd, forKey: "root_password")

        isInjecting = true
        resultMessage = nil
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 直接注入到 App bundle，不再需要 targetDir 参数
                let msg = try InjectionManager.shared.injectDylib(at: dylibPath, into: app)
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

    /// 运行 root 提权诊断
    private func runDiagnostic() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = InjectionManager.shared.diagnoseRootAccess()
            DispatchQueue.main.async {
                diagnosticResult = result
                // 检查是否缺少 su（通过正则匹配诊断输出）
                if result.contains("❌ 未找到 su 二进制") {
                    showNoSuAlert = true
                }
            }
        }
    }
}

// MARK: - Frida 安装引导页

/// Frida 安装与启动引导页面
struct FridaInstallGuideView: View {
    let status: ProcessManager.FridaStatus?
    @Environment(\.dismiss) private var dismiss

    @State private var isInstalling = false
    @State private var installLog = ""
    @State private var installDone = false

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 状态摘要
                    statusSection

                    Divider()

                    // 安装步骤
                    installStepsSection

                    if !installLog.isEmpty {
                        Divider()
                        logSection
                    }

                    if installDone && status?.isInstalled == true {
                        Divider()
                        startSection
                    }
                }
                .padding(16)
            }
            .navigationTitle("Frida 环境配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前状态")
                .font(.headline)
            if let status {
                Text(status.summary)
                    .font(.subheadline)
                    .foregroundColor(status.isRunning ? .green : .orange)
            } else {
                Text("正在检测…")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var installStepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安装步骤")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("1. 在 NewTerm 中执行以下命令：")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("apt update && apt install frida")
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
                    .onTapGesture {
                        UIPasteboard.general.string = "apt update && apt install frida"
                    }

                Text("（点击上方命令自动复制到剪贴板）")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if status?.isInstalled == true && !isInstalling {
                Button {
                    installFridaIfNeeded()
                } label: {
                    Label("一键安装（通过 App 内 root 执行）", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }

            if isInstalling {
                HStack {
                    ProgressView()
                    Text("正在安装…")
                        .font(.caption)
                }
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("安装日志")
                .font(.headline)
            Text(installLog)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(6)
        }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("启动 Frida")
                .font(.headline)
            Text("安装完成后，在 NewTerm 中执行：")
                .font(.subheadline)

            Text("su root -c '/var/jb/usr/bin/frida-server &'")
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(6)
                .onTapGesture {
                    UIPasteboard.general.string = "su root -c '/var/jb/usr/bin/frida-server &'"
                }

            Text("启动后即可返回 App 使用内存修改功能。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 一键安装

    private func installFridaIfNeeded() {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = ""

        DispatchQueue.global(qos: .userInitiated).async {
            var log = ""

            // 步骤 1: apt update
            log += "▸ apt update\n"
            DispatchQueue.main.async { self.installLog = log }
            let (updateCode, updateOut) = InjectionManager.shared.executeAsRoot("apt update 2>&1 | tail -5")
            log += updateOut + "\n"

            if updateCode != 0 {
                log += "⚠️ apt update 返回非零，继续尝试安装...\n"
            }

            DispatchQueue.main.async { self.installLog = log }

            // 步骤 2: apt install frida
            log += "▸ apt install frida -y\n"
            DispatchQueue.main.async { self.installLog = log }
            let (installCode, installOut) = InjectionManager.shared.executeAsRoot("apt install frida -y 2>&1 | tail -10")
            log += installOut + "\n"

            if installCode == 0 {
                log += "✅ Frida 安装成功\n"
            } else {
                log += "❌ 安装失败 (exit=\(installCode))\n"
            }

            DispatchQueue.main.async {
                self.installLog = log
                self.isInstalling = false
                self.installDone = true
            }
        }
    }
}