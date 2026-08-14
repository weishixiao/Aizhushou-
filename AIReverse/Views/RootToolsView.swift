import SwiftUI

struct RootToolsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    RootTerminalView()
                } label: {
                    rootFeatureRow(
                        icon: "terminal.fill",
                        color: .orange,
                        title: "Root 终端",
                        subtitle: "连接自有设备的授权 root shell"
                    )
                }

                NavigationLink {
                    RootFSManagerView()
                } label: {
                    rootFeatureRow(
                        icon: "externaldrive.fill",
                        color: .purple,
                        title: "RootFS 管理",
                        subtitle: "记录挂载点、路径和授权操作范围"
                    )
                }
            } header: {
                Text("授权工具")
            } footer: {
                Text("仅用于你拥有或已获得明确授权的设备环境。应用不会提供提权、绕过保护或注入能力。")
            }
        }
        .navigationTitle("Root 工具")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rootFeatureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RootTerminalView: View {
    @AppStorage("root_terminal_host") private var host = "127.0.0.1"
    @AppStorage("root_terminal_port") private var port = "22"
    @AppStorage("root_terminal_user") private var user = "root"
    @AppStorage("root_terminal_workdir") private var workdir = "/var/root"
    @AppStorage("root_terminal_history") private var historyText = ""

    @State private var command = ""
    @State private var showBlockedAlert = false

    private let blockedKeywords = ["exploit", "inject", "frida", "bypass", "crack", "hook"]

    var body: some View {
        Form {
            Section {
                TextField("主机", text: $host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("端口", text: $port)
                    .keyboardType(.numberPad)
                TextField("用户", text: $user)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("工作目录", text: $workdir)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("连接配置")
            } footer: {
                Text("用于记录已授权 root shell 的连接信息。当前版本不在 App 内保存密码或私钥。")
            }

            Section {
                HStack {
                    TextField("输入授权环境中的命令", text: $command)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("记录") {
                        recordCommand()
                    }
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("命令记录")
            } footer: {
                Text("这里用于整理待执行命令和审计记录，执行前请在你自己的授权终端确认风险。")
            }

            Section {
                if historyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("暂无命令记录")
                        .foregroundColor(.secondary)
                } else {
                    Text(historyText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("会话记录")
            }
        }
        .navigationTitle("Root 终端")
        .navigationBarTitleDisplayMode(.inline)
        .alert("命令已拦截", isPresented: $showBlockedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("该命令包含高风险关键词，请改用安全自检或合规排障方式。")
        }
    }

    private func recordCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if blockedKeywords.contains(where: { trimmed.lowercased().contains($0) }) {
            showBlockedAlert = true
            return
        }
        let prompt = "\(user)@\(host):\(workdir)# \(trimmed)"
        historyText = historyText.isEmpty ? prompt : historyText + "\n" + prompt
        command = ""
    }
}

struct RootFSManagerView: View {
    @AppStorage("rootfs_mount_point") private var mountPoint = "/"
    @AppStorage("rootfs_allowed_paths") private var allowedPaths = "/var/mobile\n/var/root\n/Applications"
    @AppStorage("rootfs_readonly_mode") private var readonlyMode = true
    @AppStorage("rootfs_notes") private var notes = ""

    var body: some View {
        Form {
            Section {
                Toggle("只读模式", isOn: $readonlyMode)
                TextField("RootFS 挂载点", text: $mountPoint)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("访问策略")
            } footer: {
                Text("建议保持只读模式，用于安全检查、路径盘点和配置审计。")
            }

            Section {
                TextEditor(text: $allowedPaths)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .autocorrectionDisabled()
            } header: {
                Text("授权路径")
            } footer: {
                Text("每行一个允许查看或整理的路径。")
            }

            Section {
                TextEditor(text: $notes)
                    .frame(minHeight: 140)
                    .autocorrectionDisabled()
            } header: {
                Text("审计备注")
            } footer: {
                Text("可记录文件归属、配置风险、备份计划和回滚说明。")
            }
        }
        .navigationTitle("RootFS 管理")
        .navigationBarTitleDisplayMode(.inline)
    }
}
