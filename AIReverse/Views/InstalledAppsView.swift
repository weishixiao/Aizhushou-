import SwiftUI
import UIKit

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

    /// 供「进程」模式把目标应用 + 指令回传到主聊天视图
    var onSendToChat: ((_ app: InstalledApp, _ instruction: String) -> Void)?

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
            // 进程模式：把目标应用发给 AI
            let instructionProposal = analyzeInstruction(for: app)
            onSendToChat?(app, instructionProposal)
            dismiss()
        }
    }

    /// 进程模式默认推送的逆向指令
    private func analyzeInstruction(for app: InstalledApp) -> String {
        return """
        请对本机应用「\(app.displayName)」进行逆向破解分析：
        - bundleID：\(app.bundleID)
        - 路径：\(app.bundlePath)
        - 版本：\(app.version)

        请先用 list_installed_apps 确认应用，然后：
        1. 分析目标 app 的二进制与配置，找出可破解点（广告/付费/校验/时长等）
        2. 根据我的后续指令生成注入插件（inject_plugin）或修改本地数据（modify_app_data）
        3. 只输出方案；执行前先向我确认。
        """
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
    @State private var isInjecting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)
    private let rt = JailbreakRuntime.shared

    var body: some View {
        NavigationView {
            Form {
                Section {
                    LabeledContent("目标应用", value: app.displayName)
                    LabeledContent("bundleID", value: app.bundleID)
                }
                Section {
                    TextField("插件名称（如 MyTweak）", text: $tweakName)
                        .autocapitalization(.none)
                    TextField("要注入的行为描述", text: $hookSpec, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.callout)
                } header: {
                    Text("插件设置")
                } footer: {
                    Text("例如：屏蔽广告、跳过登录校验、解锁付费内容、增加金币等")
                }
                Section {
                    LabeledContent("当前权限", value: rt.isRoot ? "Root ✓" : "非 Root")
                    LabeledContent("越狱环境", value: rt.isJailbroken ? "已识别" : "未识别")
                } footer: {
                    Text("需在越狱 / TrollStore 下以最高权限运行才能完成注入。")
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
                    .disabled(tweakName.trimmingCharacters(in: .whitespaces).isEmpty || isInjecting)
                }
            }
        }
        .onAppear {
            // 默认插件名
            if tweakName.isEmpty {
                let base = app.bundleID
                    .replacingOccurrences(of: ".", with: "_")
                    .replacingOccurrences(of: "-", with: "_")
                tweakName = "\(base)_Tweak"
            }
        }
    }

    private func startInject() {
        let name = tweakName.trimmingCharacters(in: .whitespaces)
        let spec = hookSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isInjecting = true
        resultMessage = nil
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let msg = try InjectionManager.shared.inject(tweakNamed: name, into: app, hookSpec: spec)
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
}