import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 本地工作区：浏览文件、上传文件、下载/分享文件
struct LocalWorkspaceView: View {
    @ObservedObject var workspace: WorkspaceManager

    @State private var currentPath = ""
    @State private var entries: [WorkspaceEntry] = []
    @State private var loadError: String?
    @State private var showUploadPicker = false
    @State private var showCreateFolderDialog = false
    @State private var newFolderName = ""
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    var body: some View {
        List {
            Section("当前位置") {
                HStack {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundColor(.blue)
                    Text(currentPathDisplay)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            }

            Section {
                if entries.isEmpty {
                    Text("（空目录）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                    .onDelete { indexSet in
                        deleteEntries(at: indexSet)
                    }
                }
            }
        }
        .navigationTitle("本地工作区")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                if !currentPath.isEmpty {
                    Button {
                        goUp()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    newFolderName = ""
                    showCreateFolderDialog = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                Button {
                    showUploadPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            reload()
        }
        .sheet(isPresented: $showUploadPicker) {
            DocumentPicker(allowedContentTypes: [.item, .folder]) { url in
                uploadFile(from: url)
            }
        }
        .alert("新建文件夹", isPresented: $showCreateFolderDialog) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { createFolder() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在 \(currentPathDisplay) 下创建")
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: shareItems)
        }
    }

    private var currentPathDisplay: String {
        let rootName = workspace.workspaceRoot?.lastPathComponent ?? "Workspace"
        return currentPath.isEmpty ? "/" : "\(rootName)/\(currentPath)"
    }

    // MARK: - 文件行

    private func entryRow(_ entry: WorkspaceEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 18))
                .foregroundColor(entry.isDirectory ? .blue : .gray)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                HStack(spacing: 6) {
                    if !entry.isDirectory {
                        Text(formatSize(entry.size))
                    }
                    Text(entry.modifiedAt.formatted(date: .numeric, time: .shortened))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                shareEntry(entry)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory {
                enter(entry)
            }
        }
    }

    // MARK: - 导航

    private func enter(_ entry: WorkspaceEntry) {
        currentPath = entry.path
        reload()
    }

    private func goUp() {
        guard !currentPath.isEmpty else { return }
        let parts = currentPath.split(separator: "/")
        currentPath = parts.dropLast().joined(separator: "/")
        reload()
    }

    private func reload() {
        loadError = nil
        do {
            entries = try workspace.listFiles(relativeTo: currentPath)
        } catch {
            loadError = error.localizedDescription
            entries = []
        }
    }

    // MARK: - 上传

    private func uploadFile(from url: URL) {
        do {
            let name = url.lastPathComponent
            let dest = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
            try workspace.importFile(from: url, to: dest)
            reload()
        } catch {
            loadError = "上传失败：\(error.localizedDescription)"
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let dest = currentPath.isEmpty ? name : "\(currentPath)/\(name)"
            try workspace.createDirectory(dest)
            reload()
        } catch {
            loadError = "创建失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 下载/分享

    private func shareEntry(_ entry: WorkspaceEntry) {
        guard !entry.isDirectory else { return }
        do {
            let data = try workspace.readData(entry.path)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(entry.name)
            try data.write(to: tmp)
            shareItems = [tmp]
            showShareSheet = true
        } catch {
            loadError = "下载失败：\(error.localizedDescription)"
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            let entry = entries[index]
            do {
                try workspace.deleteItem(entry.path)
            } catch {
                loadError = "删除失败：\(error.localizedDescription)"
            }
        }
        reload()
    }

    private func formatSize(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b >= 1024 * 1024 * 1024 { return String(format: "%.2f GB", b / (1024 * 1024 * 1024)) }
        if b >= 1024 * 1024 { return String(format: "%.2f MB", b / (1024 * 1024)) }
        if b >= 1024 { return String(format: "%.1f KB", b / 1024) }
        return "\(bytes) B"
    }
}

/// 通用系统分享面板（UIActivityViewController）
struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
