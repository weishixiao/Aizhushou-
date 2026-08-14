import SwiftUI
import UIKit

/// 系统文件浏览器：越狱 / TrollStore 环境下以 root + 无沙盒权限浏览完整文件系统，
/// 可查看已安装 App 包目录并直接分析 .app / .ipa / .tipa / Mach-O 二进制。
struct FileBrowserView: View {
    @EnvironmentObject var analysisStore: AnalysisStore
    @Environment(\.dismiss) private var dismiss

    @State private var pathStack: [String] = []
    @State private var entries: [FileEntry] = []
    @State private var isLoading = false
    @State private var toastText: String?
    @State private var isAnalyzing = false
    @State private var progressText = "准备就绪"

    private let analyzer = AppAnalyzer()

    struct FileEntry: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let isDirectory: Bool
        let isAnalyzeable: Bool
    }

    private let quickLinks: [(String, String)] = [
        ("根目录", "/"),
        ("已安装 App", "/var/containers/Bundle/Application"),
        ("系统 App", "/Applications"),
        ("数据沙盒", "/var/mobile/Containers/Data/Application")
    ]

    private var currentPath: String {
        pathStack.isEmpty ? "/" : "/" + pathStack.joined(separator: "/")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                quickLinkBar

                if isLoading {
                    Spacer()
                    ProgressView("加载中...")
                    Spacer()
                } else if entries.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("目录为空或无法访问")
                            .foregroundColor(.secondary)
                        Text("需要越狱 / TrollStore 环境的 root 权限")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List(entries) { entry in
                        row(entry)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(currentPath)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        goUp()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(pathStack.isEmpty)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = toastText {
                    Text(toast)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(8)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
            .overlay {
                if isAnalyzing {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text(progressText)
                                .font(.body)
                                .foregroundColor(.white)
                            Text("大型 App 可能耗时较长")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(24)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6)))
                    }
                }
            }
        }
        .onAppear { loadCurrentDir() }
    }

    // MARK: - 快捷入口

    private var quickLinkBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickLinks, id: \.1) { title, path in
                    Button {
                        jump(to: path)
                    } label: {
                        Text(title)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5))
                            .cornerRadius(14)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    private func jump(to path: String) {
        if path == "/" {
            pathStack = []
        } else {
            pathStack = path.split(separator: "/").map(String.init)
        }
        loadCurrentDir()
    }

    private func goUp() {
        guard !pathStack.isEmpty else { return }
        pathStack.removeLast()
        loadCurrentDir()
    }

    private func descend(_ name: String) {
        pathStack.append(name)
        loadCurrentDir()
    }

    // MARK: - 加载目录

    private func loadCurrentDir() {
        isLoading = true
        let url = URL(fileURLWithPath: currentPath, isDirectory: true)
        Task.detached(priority: .userInitiated) {
            let result = listDirectory(url)
            await MainActor.run {
                entries = result
                isLoading = false
            }
        }
    }

    private func listDirectory(_ url: URL) -> [FileEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }

        var list: [FileEntry] = []
        for name in names {
            let fileURL = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) else { continue }
            let directory = isDir.boolValue
            list.append(FileEntry(
                url: fileURL,
                name: name,
                isDirectory: directory,
                isAnalyzeable: isAnalyzeable(fileURL, directory: directory)
            ))
        }
        return list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func isAnalyzeable(_ url: URL, directory: Bool) -> Bool {
        if directory {
            return url.pathExtension.lowercased() == "app"
        }
        let ext = url.pathExtension.lowercased()
        if ["ipa", "tipa"].contains(ext) { return true }
        return isMachO(url)
    }

    private func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let b = [data[data.startIndex], data[data.startIndex + 1], data[data.startIndex + 2], data[data.startIndex + 3]]
        let magic: UInt32 = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        switch magic {
        case 0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA:
            return true
        default:
            return false
        }
    }

    // MARK: - 行视图

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: entry))
                .foregroundColor(entry.isAnalyzeable ? .blue : .secondary)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if entry.isAnalyzeable {
                Image(systemName: "scope")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory {
                if entry.url.pathExtension.lowercased() == "app" {
                    analyze(entry.url)
                } else {
                    descend(entry.name)
                }
            } else if entry.isAnalyzeable {
                analyze(entry.url)
            } else {
                showToast("无法分析此文件")
            }
        }
    }

    private func iconName(for entry: FileEntry) -> String {
        if entry.isDirectory {
            return entry.url.pathExtension.lowercased() == "app" ? "app.badge.fill" : "folder"
        }
        let ext = entry.url.pathExtension.lowercased()
        if ["ipa", "tipa"].contains(ext) { return "archivebox" }
        return "doc.text"
    }

    private func showToast(_ text: String) {
        withAnimation { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toastText = nil }
        }
    }

    // MARK: - 分析

    private func analyze(_ url: URL) {
        isAnalyzing = true
        progressText = "开始分析..."
        Task {
            let result = await analyzer.analyze(url: url) { msg in
                Task { @MainActor in
                    progressText = msg
                }
            }
            await MainActor.run {
                analysisStore.add(result)
                isAnalyzing = false
                dismiss()
            }
        }
    }
}
