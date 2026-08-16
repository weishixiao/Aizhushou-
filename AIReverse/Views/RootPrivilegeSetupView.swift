import SwiftUI

struct RootPrivilegeSetupView: View {
    @State private var log = ""
    @State private var commands: [String] = []
    @State private var isLoading = false
    @State private var statusInfo: (label: String, isRunning: Bool, details: [String]) = ("", false, [])
    @State private var envInfo = ""

    var body: some View {
        List {
            // 环境信息
            Section("环境检测") {
                HStack {
                    Text("环境类型")
                        .font(.body).foregroundColor(.primary)
                    Spacer()
                    Text(envInfo)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.green)
                }
                HStack {
                    Text("运行身份")
                        .font(.body).foregroundColor(.primary)
                    Spacer()
                    Text(RootPrivilegeManager.shared.appBinaryPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("root shell")
                        .font(.body).foregroundColor(.primary)
                    Spacer()
                    Text(RootPrivilegeManager.shared.rootShellPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }

            // 守护进程状态
            Section("LaunchDaemon 状态") {
                Button {
                    refreshStatus()
                } label: {
                    HStack {
                        Text("刷新状态")
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                    }
                }

                if !statusInfo.details.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(statusInfo.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(statusInfo.isRunning ? .green : .red)
                        ForEach(statusInfo.details, id: \.self) { detail in
                            Text(detail)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // 操作
            Section("操作") {
                Button(isLoading ? "操作中..." : "🚀 配置 LaunchDaemon（获取 root 权限）") {
                    setupDaemon()
                }
                .foregroundColor(.green)

                Button {
                    teardownDaemon()
                } label: {
                    Text("⛔ 停止并卸载守护进程")
                }
                .foregroundColor(.red)
            }

            // RootService 状态
            Section("RootService 后台服务") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("📡 双进程架构：主 App(mobile) ↔ RootService(root)")
                        .font(.caption).foregroundColor(.secondary)
                    Text("Socket: /var/mobile/Library/aireverse_service.sock")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    Text("编译: clang -arch arm64 root_service.c -o root_service")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.orange)
                }
                .padding(.vertical, 4)
            }

            // 命令列表（可单独复制）
            if !commands.isEmpty {
                Section("手动执行命令（点击复制到剪贴板）") {
                    ForEach(Array(commands.enumerated()), id: \.offset) { index, cmd in
                        Button {
                            UIPasteboard.general.string = cmd
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("命令 \(index + 1)")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                    Spacer()
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                                Text(cmd)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.green)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 日志
            Section("操作日志") {
                if log.isEmpty {
                    Text("点击上方按钮查看操作日志")
                        .foregroundColor(.secondary)
                } else {
                    Text(log)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
            }

            // 说明
            Section("说明") {
                Text("⚠️ 重要：iOS17 RootHide 环境下 LaunchDaemon 启动的进程无法渲染图形 UI。")
                    .font(.caption).foregroundColor(.red).bold()
                Text("✅ 推荐采用「双进程架构」：主 App（mobile）正常显示 UI，通过 UNIX Socket 与 root 权限后台服务通信。")
                    .font(.caption).foregroundColor(.green)
                Text("📋 编译 RootService 后部署到 /var/mobile/，在 NewTerm 中启动即可。")
                    .font(.caption).foregroundColor(.secondary)
                Text("📖 URL Scheme: aireverse://root（桌面图标点击可唤起 UI）")
                    .font(.caption).foregroundColor(.blue)
            }
        }
        .navigationTitle("权限设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            envInfo = RootPrivilegeManager.shared.environmentDescription
            refreshStatus()
        }
    }

    private func refreshStatus() {
        statusInfo = RootPrivilegeManager.shared.daemonStatus()
    }

    private func setupDaemon() {
        isLoading = true
        log = "正在配置 LaunchDaemon...\n\n"
        commands = []
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            let result = RootPrivilegeManager.shared.setupDaemon()
            isLoading = false
            log = result.log
            commands = result.commands
            refreshStatus()
        }
    }

    private func teardownDaemon() {
        isLoading = true
        log = "正在停止守护进程...\n\n"
        commands = []
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            let result = RootPrivilegeManager.shared.teardownDaemon()
            isLoading = false
            log = result.log
            commands = result.commands
            refreshStatus()
        }
    }
}