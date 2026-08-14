import SwiftUI

struct MCPSettingsView: View {
    @StateObject private var store = MCPServerStore()
    @State private var showAdd = false
    @State private var editingServer: MCPServerConfig?
    @State private var showImporter = false
    @State private var importMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("添加服务器", systemImage: "plus.circle")
                }

                Button {
                    showImporter = true
                } label: {
                    Label("导入 JSON", systemImage: "doc.badge.plus")
                }

                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("配置")
            } footer: {
                Text("支持常见 mcpServers JSON，可导入 command、args、env、url、headers、enabled 等字段。")
            }

            Section {
                if store.servers.isEmpty {
                    Text("暂无 MCP 服务器")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.servers) { server in
                        Button {
                            editingServer = server
                        } label: {
                            serverRow(server)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("服务器")
            }
        }
        .navigationTitle("MCP 集成")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            MCPServerEditView(server: nil) { server in
                store.add(server)
            }
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditView(server: server) { updated in
                store.update(updated)
            } onDelete: {
                store.remove(server)
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(allowedContentTypes: [.item]) { url in
                importJSON(url)
            }
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: server.enabled ? "checkmark.circle.fill" : "pause.circle")
                .foregroundColor(server.enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(server.transport.title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(server.transport == .stdio ? server.command : server.url)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func importJSON(_ url: URL) {
        do {
            let count = try store.importServers(from: url)
            importMessage = "已导入 \(count) 个 MCP 服务器"
        } catch {
            importMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}

struct MCPServerEditView: View {
    let server: MCPServerConfig?
    let onSave: (MCPServerConfig) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var transport: MCPServerConfig.Transport = .stdio
    @State private var command = ""
    @State private var argsText = ""
    @State private var envText = ""
    @State private var url = ""
    @State private var headersText = ""
    @State private var enabled = true

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("服务器名称", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("启用", isOn: $enabled)
                    Picker("传输方式", selection: $transport) {
                        ForEach(MCPServerConfig.Transport.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                } header: {
                    Text("基础信息")
                }

                if transport == .stdio {
                    Section {
                        TextField("启动命令，例如 npx", text: $command)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextEditor(text: $argsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100)
                            .autocorrectionDisabled()
                    } header: {
                        Text("本地 stdio")
                    } footer: {
                        Text("参数每行一个，例如 -y 或 @modelcontextprotocol/server-filesystem。")
                    }
                } else {
                    Section {
                        TextField("服务器 URL", text: $url)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextEditor(text: $headersText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 90)
                            .autocorrectionDisabled()
                    } header: {
                        Text("远程连接")
                    } footer: {
                        Text("Header 每行一个 KEY=VALUE。请只保存当前 App 需要使用的凭证。")
                    }
                }

                Section {
                    TextEditor(text: $envText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .autocorrectionDisabled()
                } header: {
                    Text("环境变量")
                } footer: {
                    Text("每行一个 KEY=VALUE。")
                }

                if let onDelete {
                    Section {
                        Button("删除服务器", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(server == nil ? "添加 MCP" : "编辑 MCP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(buildServer())
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: loadServer)
        }
    }

    private func loadServer() {
        guard let server else { return }
        name = server.name
        transport = server.transport
        command = server.command
        argsText = server.args.joined(separator: "\n")
        envText = keyValueText(server.env)
        url = server.url
        headersText = keyValueText(server.headers)
        enabled = server.enabled
    }

    private func buildServer() -> MCPServerConfig {
        MCPServerConfig(
            id: server?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            transport: transport,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            args: lines(argsText),
            env: keyValueMap(envText),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            headers: keyValueMap(headersText),
            enabled: enabled
        )
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func keyValueMap(_ text: String) -> [String: String] {
        lines(text).reduce(into: [:]) { result, line in
            guard let index = line.firstIndex(of: "=") else { return }
            let key = String(line[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[String(key)] = String(value) }
        }
    }

    private func keyValueText(_ map: [String: String]) -> String {
        map.keys.sorted().map { "\($0)=\(map[$0] ?? "")" }.joined(separator: "\n")
    }
}
