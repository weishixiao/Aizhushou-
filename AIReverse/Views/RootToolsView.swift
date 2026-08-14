import SwiftUI

// MARK: - Root 终端

/// 真实 root 终端：PTY 交互 shell
struct RootTerminalView: View {
    @StateObject private var shell = RootShellService()

    @State private var input = ""
    @State private var showBlockedAlert = false
    @State private var autoScroll = true

    private let blockedKeywords = ["exploit", "inject", "frida", "bypass", "crack", "hook"]

    private var outputText: String {
        if shell.isRunning || shell.output.isEmpty {
            if shell.output.isEmpty {
                if let error = shell.state.lastError, !error.isEmpty {
                    return error
                }
                return "尚未连接。点击「连接」启动本机授权 root shell。\n\n提示：本功能需要越狱或 TrollStore 环境（带 no-sandbox 权限）。\n输入 exit 可退出。"
            }
            return shell.output
        }
        if let error = shell.state.lastError, !error.isEmpty {
            return error
        }
        return shell.output
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            terminalOutput
            inputBar
        }
        .navigationTitle("Root 终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(shell.isRunning ? "断开" : "连接") {
                    if shell.isRunning {
                        shell.stop()
                    } else {
                        shell.start()
                    }
                }
            }
        }
        .alert("命令已拦截", isPresented: $showBlockedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("该命令包含高风险关键词，请改用安全自检或合规排障方式。")
        }
        .onDisappear {
            shell.stop()
        }
    }

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(shell.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer()
            if shell.isRunning {
                Button {
                    sendLine("pwd")
                } label: {
                    Text("pwd")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                Button {
                    sendLine("whoami")
                } label: {
                    Text("whoami")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
    }

    private var statusText: String {
        if shell.isRunning {
            return "root shell 已连接"
        }
        if let error = shell.state.lastError, !error.isEmpty {
            return error
        }
        return "未连接"
    }

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(outputText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Color(red: 0.82, green: 0.88, blue: 0.84))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("terminal-output")
                    .padding(12)
            }
            .background(Color(red: 0.07, green: 0.08, blue: 0.09))
            .onChange(of: shell.output) { _ in
                if autoScroll {
                    withAnimation { proxy.scrollTo("terminal-output", anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundColor(.secondary)
            TextField("输入命令，回车执行", text: $input)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit {
                    submitCommand()
                }
            Button {
                submitCommand()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(shell.isRunning ? .accentColor : .gray)
            }
            .buttonStyle(.plain)
            .disabled(!shell.isRunning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
    }

    private func submitCommand() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if blockedKeywords.contains(where: { trimmed.lowercased().contains($0) }) {
            showBlockedAlert = true
            input = ""
            return
        }
        sendLine(trimmed)
        input = ""
    }

    private func sendLine(_ line: String) {
        guard shell.isRunning else { return }
        shell.send(line)
    }
}

// MARK: - RootFS 管理

/// 真实文件浏览器：遍历设备文件系统
struct RootFSManagerView: View {
    @State private var service = RootFileService()
    @State private var currentPath = "/"
    @State private var entries: [RootFileEntry] = []
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var selectedEntry: RootFileEntry?

    private let allowedRoots = ["/", "/var", "/var/mobile", "/var/root", "/Applications", "/usr", "/private/var"]

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            content
        }
        .navigationTitle("RootFS 管理")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedEntry) { entry in
            NavigationView {
                RootFileDetailView(entry: entry)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { selectedEntry = nil }
                        }
                    }
            }
        }
        .onAppear {
            reload()
        }
    }

    private var pathBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .foregroundColor(.purple)
                Text(currentPath)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allowedRoots, id: \.self) { root in
                        Button {
                            currentPath = root
                            reload()
                        } label: {
                            Text(root)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(currentPath == root ? Color.purple.opacity(0.18) : Color.gray.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.97, green: 0.95, blue: 0.99))
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            VStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(errorText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    if currentPath != "/" {
                        Button {
                            goUp()
                        } label: {
                            Label("返回上级目录", systemImage: "arrow.up.circle")
                                .foregroundColor(.secondary)
                        }
                    }
                    ForEach(entries) { entry in
                        fileRow(entry)
                    }
                } header: {
                    Text("\(entries.count) 个项目")
                } footer: {
                    Text("仅浏览与查看文件属性。修改、删除等写操作请在确认授权的终端中自行执行。")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func fileRow(_ entry: RootFileEntry) -> some View {
        Button {
            if entry.isDirectory {
                currentPath = entry.url.path
                reload()
            } else {
                selectedEntry = entry
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: entry))
                    .font(.system(size: 18))
                    .foregroundColor(entry.isDirectory ? .purple : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if entry.isDirectory {
                        Text(entry.permissionText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Text(entry.displaySize)
                            Text(entry.permissionText)
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func iconName(for entry: RootFileEntry) -> String {
        if entry.isDirectory {
            return entry.isSymlink ? "folder.badge.plus" : "folder.fill"
        }
        if entry.isSymlink {
            return "link"
        }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "plist", "json", "xml", "md", "txt", "log", "conf", "strings":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "webp", "tiff":
            return "photo"
        case "dylib", "framework", "tweak", "deb":
            return "shippingbox"
        default:
            return "doc"
        }
    }

    private func goUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        guard parent != currentPath else { return }
        currentPath = parent
        reload()
    }

    private func reload() {
        isLoading = true
        errorText = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let items = try service.listDirectory(at: currentPath)
                DispatchQueue.main.async {
                    entries = items
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorText = error.localizedDescription
                    entries = []
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - 文件详情

struct RootFileDetailView: View {
    let entry: RootFileEntry
    @State private var contentPreview: FileContentPreview?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var showContentView = false

    var body: some View {
        List {
            Section("文件信息") {
                detailRow("名称", entry.name)
                detailRow("路径", entry.url.path)
                detailRow("类型", entry.isDirectory ? "目录" : (entry.isSymlink ? "符号链接" : "文件"))
                detailRow("大小", entry.displaySize)
                detailRow("权限", entry.permissionText)
                if let date = entry.modificationDate {
                    detailRow("修改时间", Self.dateFormatter.string(from: date))
                }
            }
            if !entry.isDirectory {
                Section {
                    Button {
                        loadContent()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(.accentColor)
                            Text("查看文件内容")
                                .foregroundColor(.accentColor)
                            Spacer()
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
            Section {
                if entry.isDirectory {
                    Text("目录已支持逐层浏览，点击列表项进入。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else if let error = loadError {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.orange)
                } else {
                    Text("支持文本解码预览与十六进制查看。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("文件详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showContentView) {
            NavigationView {
                contentPreviewView
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showContentView = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var contentPreviewView: some View {
        Group {
            if let preview = contentPreview {
                ScrollView {
                    Text(preview.content)
                        .font(.system(.footnote, design: preview.kind == .hex ? .monospaced : .default))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .overlay(alignment: .bottom) {
                    if preview.truncated {
                        Text("内容过长，仅显示前 1MB")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding(.bottom, 10)
                    }
                }
            } else if let error = loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadContent() {
        isLoading = true
        loadError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let service = RootFileService()
                let preview = try service.readFile(at: entry.url.path)
                DispatchQueue.main.async {
                    contentPreview = preview
                    isLoading = false
                    showContentView = true
                }
            } catch {
                DispatchQueue.main.async {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
