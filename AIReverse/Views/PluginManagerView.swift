import SwiftUI
import UniformTypeIdentifiers

struct PluginRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var fileName: String
    var filePath: String
    var enabled: Bool
    var importedAt: Date
}

struct PluginManagerView: View {
    @State private var plugins: [PluginRecord] = []
    @State private var showImporter = false
    @State private var message: String?

    private let allowedExtensions: Set<String> = ["json", "txt", "js", "lua", "plugin"]

    var body: some View {
        List {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("导入插件文件", systemImage: "square.and.arrow.down")
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("插件文件只保存到 AIReverse 沙盒内，用于本 App 自身的配置、提示词或扩展脚本管理。")
            }

            Section("已导入插件") {
                if plugins.isEmpty {
                    Text("还没有导入插件。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach($plugins) { $plugin in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plugin.fileName)
                                        .font(.body)
                                    Text(plugin.importedAt, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $plugin.enabled)
                                    .labelsHidden()
                                    .onChange(of: plugin.enabled) { _ in savePlugins() }
                            }

                            Text(plugin.filePath)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("插件管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadPlugins)
        .sheet(isPresented: $showImporter) {
            DocumentPicker(allowedContentTypes: [.item], onPick: { url in
                importPlugin(url)
            })
        }
    }

    private func importPlugin(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            message = "仅支持 json、txt、js、lua、plugin 文件"
            return
        }

        do {
            let destination = try copyPluginFile(url)
            let record = PluginRecord(
                id: UUID(),
                fileName: destination.lastPathComponent,
                filePath: destination.path,
                enabled: true,
                importedAt: Date()
            )
            plugins.insert(record, at: 0)
            savePlugins()
            message = "插件已导入到 AIReverse 沙盒"
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    private func copyPluginFile(_ url: URL) throws -> URL {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let pluginDir = docs.appendingPathComponent("Plugins", isDirectory: true)
        try fileManager.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let base = url.deletingPathExtension().lastPathComponent
        let safeBase = base.isEmpty ? "plugin" : base
        let destination = pluginDir
            .appendingPathComponent("\(safeBase)-\(timestamp)")
            .appendingPathExtension(url.pathExtension)
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private func loadPlugins() {
        guard let url = indexURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PluginRecord].self, from: data) else {
            return
        }
        plugins = decoded
    }

    private func savePlugins() {
        guard let url = indexURL(), let data = try? JSONEncoder().encode(plugins) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func indexURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("plugins.json")
    }
}
