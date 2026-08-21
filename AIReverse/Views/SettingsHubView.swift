import SwiftUI
import UIKit

struct SettingsHubView: View {
    let agent: CodingAgent

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

                NavigationLink {
                    RuntimeLogsView()
                } label: {
                    featureRow(
                        icon: "doc.text.magnifyingglass",
                        color: .green,
                        title: "运行日志",
                        subtitle: "查看、复制与清空应用运行日志"
                    )
                }

                NavigationLink {
                    LocalWorkspaceView(workspace: agent.workspace)
                } label: {
                    featureRow(
                        icon: "folder.badge.gearshape",
                        color: .orange,
                        title: "本地文件",
                        subtitle: "浏览、上传、下载工作区文件"
                    )
                }

                NavigationLink {
                    RepoManagerView(agent: agent)
                } label: {
                    featureRow(
                        icon: "folder.fill",
                        color: .brown,
                        title: "仓库管理",
                        subtitle: "GitHub/Gitee 仓库导入、本地工作区管理"
                    )
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
