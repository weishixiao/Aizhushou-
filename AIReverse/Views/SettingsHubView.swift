import SwiftUI

struct SettingsHubView: View {
    @AppStorage(RootExecutionEnvironment.forceShowToolsKey) private var forceShowSystemTools = false

    var body: some View {
        List {
            Section("功能区") {
                NavigationLink {
                    ModelSettingsView()
                } label: {
                    featureRow(
                        icon: "cpu.fill",
                        color: .blue,
                        title: "模型设置",
                        subtitle: "配置 API、模型名称与连接测试"
                    )
                }

                NavigationLink {
                    MCPSettingsView()
                } label: {
                    featureRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        color: .purple,
                        title: "MCP 集成",
                        subtitle: "添加服务器、导入 mcpServers JSON"
                    )
                }
            }

            Section {
                Toggle("显示系统工具入口", isOn: $forceShowSystemTools)
                    .tint(.orange)
                Text(RootExecutionEnvironment.diagnosticText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("系统工具显示")
            } footer: {
                Text("越狱或 TrollStore 环境检测可能受沙盒、rootless 路径和权限影响。检测失误时可手动打开入口。")
            }

            if RootExecutionEnvironment.shouldShowTools {
                Section {
                    NavigationLink {
                        RootTerminalView()
                    } label: {
                        featureRow(
                            icon: "terminal.fill",
                            color: .orange,
                            title: "系统终端",
                            subtitle: "连接已授权的 shell 执行命令"
                        )
                    }

                    NavigationLink {
                        RootFSManagerView()
                    } label: {
                        featureRow(
                            icon: "externaldrive.fill",
                            color: .indigo,
                            title: "系统文件管理",
                            subtitle: "浏览设备文件系统、查看文件属性"
                        )
                    }
                } header: {
                    Text("授权工具")
                } footer: {
                    Text("仅在已授权的越狱或系统执行环境中显示。应用不会提供提权、绕过保护或注入能力。")
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
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
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
