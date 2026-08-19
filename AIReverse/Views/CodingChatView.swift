import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// CatPaw 风格编程助手聊天界面
///
/// 视觉设计：
/// - 深色主题（#1C1C1E 类 dark mode）
/// - 气泡式对话（右侧用户消息 / 左侧 AI 文本）
/// - 工具调用以内联执行卡片形式呈现
/// - 顶部状态栏以细点 + 文字展示当前阶段
/// - 底部胶囊式浮动输入框
struct CodingChatView: View {
    @EnvironmentObject var modelStore: ModelStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var agent: CodingAgent

    @State private var inputText = ""
    @State private var showModelSettings = false
    @State private var showWorkspaceView = false
    @State private var showUploadPicker = false
    @State private var uploadedFileName: String?
    @State private var uploadedFileURL: URL?
    @State private var uploadError: String?
    @State private var sendTask: Task<Void, Never>?

    @State private var showPhotoPicker = false
    @State private var hasPhotoAttachment = false
    @State private var showProcessSheet = false
    @State private var targetApp: InstalledApp?

    // MARK: - 视觉常量

    /// accent: CatPaw 绿 (调和自旧版 MonkeyCode 绿，适配深色背景更亮)
    private let accent = Color(red: 0.36, green: 0.80, blue: 0.48)
    private let background = Color(red: 0.10, green: 0.10, blue: 0.11)      // #1A1A1C
    private let surface = Color(red: 0.15, green: 0.15, blue: 0.16)          // #262629
    private let surfaceElevated = Color(red: 0.20, green: 0.20, blue: 0.22)
    private let userBubble = Color(red: 0.25, green: 0.55, blue: 0.35)       // 暗色绿
    private let textPrimary = Color(white: 0.96)
    private let textSecondary = Color(white: 0.62)
    private let cardBorder = Color(white: 0.18)
    private let packageExtensions: Set<String> = ["ipa", "tipa", "deb", "dylib", "apk"]

    init(workspace: WorkspaceManager) {
        _agent = StateObject(wrappedValue: CodingAgent(workspace: workspace))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            messageList
            uploadStatusBar
            quickActionsBar
            inputBar
        }
        .background(background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showModelSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(accent)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // 快速切换模型
                Menu {
                    ForEach(modelStore.models) { model in
                        Button {
                            modelStore.select(model.id)
                        } label: {
                            Label(
                                model.name,
                                systemImage: modelStore.selectedModel?.id == model.id ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                    Divider()
                    Button {
                        showModelSettings = true
                    } label: {
                        Label("管理模型", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(accent)
                }
                .disabled(modelStore.models.isEmpty)

                // 文件管理
                Button {
                    showWorkspaceView = true
                } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(accent)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(navigationTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)
                    Text(navigationSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .sheet(isPresented: $showModelSettings) {
            NavigationView {
                SettingsHubView(agent: agent)
                    .preferredColorScheme(.dark)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showModelSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showWorkspaceView) {
            NavigationView {
                LocalWorkspaceView(workspace: agent.workspace)
                    .preferredColorScheme(.dark)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showWorkspaceView = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showUploadPicker) {
            DocumentPicker(allowedContentTypes: [.item], onPick: { url in
                importPackageFile(url)
            })
        }
        .sheet(isPresented: $showProcessSheet) {
            NavigationView {
                InstalledAppsView { app in
                    selectTargetApp(app)
                }
                .preferredColorScheme(.dark)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(maxSelection: 1) { images in
                handlePhotoPicked(images)
            }
        }
        .onAppear {
            if agent.messages.isEmpty { seedWelcome() }
        }
        .onChange(of: scenePhase) { _ in
            // 暂留逻辑原样保留
        }
    }

    // MARK: - 顶部状态栏：CatPaw 风格 — 细点 + 当前阶段文字

    @ViewBuilder
    private var statusBar: some View {
        if agent.isWorking {
            HStack(spacing: 8) {
                // 脉冲圆点
                PulseDot(color: accent)
                Text(agent.stageText ?? "处理中")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textSecondary)
                    .lineLimit(1)
                    .animation(.easeInOut(duration: 0.2), value: agent.stageText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(surface.overlay(accent.opacity(0.05)))
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(agent.messages.enumerated()), id: \.element.id) { index, msg in
                        BubbleMessageRow(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: agent.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    if let last = agent.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - 输入区

    private var inputBar: some View {
        VStack(spacing: 4) {
            // 目标进程徽标（带删除按钮）
            if targetApp != nil {
                HStack {
                    targetAppBadge
                    Spacer()
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 10) {
                // 浮动胶囊输入框
                capsuleInputField

                // 发送 / 停止按钮
                actionButton
            }
        }
        .padding(.vertical, 8)
        .background(background)
        .overlay(
            Rectangle()
                .fill(surfaceElevated)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var capsuleInputField: some View {
        HStack(alignment: .bottom, spacing: 4) {
            // 附件按钮
            Button {
                showUploadPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
            }
            .buttonStyle(.plain)

            // 输入框
            if #available(iOS 16.0, *) {
                TextField("发送消息…", text: $inputText, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundColor(textPrimary)
                    .padding(.vertical, 10)
            } else {
                TextField("发送消息…", text: $inputText)
                    .font(.system(size: 15))
                    .foregroundColor(textPrimary)
                    .padding(.vertical, 10)
            }

        }
        .padding(.horizontal, 14)
        .background(surfaceElevated)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(inputText.isEmpty ? cardBorder : accent.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - 目标进程徽标（带删除按钮）

    private var targetAppBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "app.fill")
                .font(.system(size: 10))
            Text(targetApp?.displayName ?? "")
                .font(.caption2)
                .lineLimit(1)

            // 删除按钮
            Button {
                targetApp = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(textSecondary)
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accent.opacity(0.12))
        .clipShape(Capsule())
        .padding(.bottom, 6)
    }

    private var actionButton: some View {
        Button {
            if agent.isWorking {
                stopConversation()
            } else if canResumeFromInputButton {
                resumePendingTask()
            } else {
                sendInput()
            }
        } label: {
            Image(systemName: inputButtonIcon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(inputButtonDisabled ? textSecondary.opacity(0.4) : .white)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(inputButtonEnabled ? accent : surfaceElevated)
                )
        }
        .buttonStyle(.plain)
        .disabled(inputButtonDisabled)
    }

    private var inputButtonEnabled: Bool {
        if agent.isWorking { return true }
        if canResumeFromInputButton { return true }
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputButtonDisabled: Bool {
        !inputButtonEnabled
    }

    // MARK: - 状态信息

    private var navigationTitle: String {
        if agent.isWorking {
            return agent.stageText ?? "处理中"
        }
        if let task = currentTaskTitle { return task }
        return "AIReverse"
    }

    private var navigationSubtitle: String {
        if agent.isWorking { return "执行中…" }
        if modelStore.selectedModel != nil {
            return modelStore.selectedModel!.name
        }
        return "选择模型以开始"
    }

    private var currentTaskTitle: String? {
        guard let content = agent.messages.last(where: { $0.role == .user })?.content else { return nil }
        let singleLine = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return nil }
        return String(singleLine.prefix(18))
    }

    private var uploadStatusBar: some View {
        Group {
            if let name = uploadedFileName {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.caption)
                        .foregroundColor(accent)
                    Text("已上传：\(name)")
                        .font(.caption)
                        .foregroundColor(textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        removeUploadedFile()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(surface)
            } else if let error = uploadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(textSecondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(surface)
            }
        }
    }

    // MARK: - 底部功能键（相册 / 进程）— CatPaw 暗色适配

    private var quickActionsBar: some View {
        HStack(spacing: 0) {
            quickActionButton(
                title: "相册",
                icon: "photo.on.rectangle.angled",
                enabled: !agent.isWorking
            ) { showPhotoPicker = true }
            quickActionButton(
                title: "进程",
                icon: "cpu",
                enabled: !agent.isWorking
            ) { showProcessSheet = true }
        }
        .padding(.vertical, 6)
        .background(background)
        .overlay(
            Rectangle()
                .fill(surfaceElevated)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private func quickActionButton(title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(enabled ? accent : textSecondary.opacity(0.4))
                Text(title)
                    .font(.caption2)
                    .foregroundColor(enabled ? textSecondary : textSecondary.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Actions

    private var sendButtonColor: Color {
        if agent.isWorking { return .red }
        if canResumeFromInputButton { return accent }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Color(.systemGray4) }
        return accent
    }

    private var inputButtonIcon: String {
        if agent.isWorking { return "stop.fill" }
        if canResumeFromInputButton { return "arrow.clockwise" }
        return "arrow.up"
    }

    private var canResumeFromInputButton: Bool {
        !agent.isWorking
            && agent.pendingTask != nil
            && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && resumeTargetModel != nil
    }

    private func sendInput() {
        send(inputText)
        inputText = ""
    }

    private func stopConversation() {
        sendTask?.cancel()
        sendTask = nil
        agent.cancel()
    }

    private var resumeTargetModel: AIModelConfig? {
        guard let pending = agent.pendingTask else { return nil }
        return modelStore.models.first(where: { $0.id == pending.modelID }) ?? modelStore.selectedModel
    }

    private func resumePendingTask() {
        guard let model = resumeTargetModel else {
            agent.errorMessage = "请先选择用于恢复的模型"
            return
        }
        sendTask = Task { @MainActor in
            await agent.resumePendingTask(model: model)
            sendTask = nil
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !agent.isWorking else { return }
        var prompt = trimmed
        if let app = targetApp {
            prompt += """

            【当前目标应用】\(app.displayName)（\(app.bundleID)）
            路径：\(app.bundlePath)
            版本：\(app.version)
            """
        }
        sendTask = Task { @MainActor in
            guard let model = modelStore.selectedModel else {
                agent.errorMessage = "请先添加并选择模型"
                return
            }
            await agent.send(prompt, model: model)
            sendTask = nil
        }
    }

    // MARK: - 选择目标应用

    private func selectTargetApp(_ app: InstalledApp) {
        showProcessSheet = false
        targetApp = app

        // 发送提示消息到聊天
        let content = """
        🎯 已选中目标应用

        ▪ 名称：\(app.displayName)
        ▪ Bundle ID：\(app.bundleID)
        ▪ 版本：\(app.version)
        ▪ 路径：\(app.bundlePath)

        💡 现在发送的消息会自动附带此应用信息。
        点击徽标上的 ✕ 可删除此进程关联。
        """

        agent.appendLocalMessage(role: .assistant, content: content)
    }

    private func seedWelcome() {
        agent.appendLocalMessage(
            role: .assistant,
            content: "你好，我是 **AIReverse**。🦖\n\n直接发消息开始，或点击左侧 ➕ 上传 ipa / tipa / deb / dylib / apk 文件进行分析。"
        )
    }

    private func importPackageFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard packageExtensions.contains(ext) else {
            uploadError = "仅支持上传 .ipa、.tipa、.deb、.dylib、.apk 文件"
            uploadedFileName = nil
            uploadedFileURL = nil
            return
        }
        do {
            let savedURL = try saveUploadedPackage(url)
            let report = try PackageScanner().scan(url: savedURL)
            uploadedFileName = savedURL.lastPathComponent
            uploadedFileURL = savedURL
            uploadError = nil
            agent.setPackageScanSummary(report.summaryMarkdown)
            agent.appendLocalMessage(role: .user, content: "已上传文件：\(savedURL.lastPathComponent)")
            agent.appendLocalMessage(role: .assistant, content: report.summaryMarkdown)
        } catch {
            uploadError = "上传失败：\(error.localizedDescription)"
            uploadedFileName = nil
            uploadedFileURL = nil
            agent.setPackageScanSummary(nil)
        }
    }

    private func removeUploadedFile() {
        if let url = uploadedFileURL { try? FileManager.default.removeItem(at: url) }
        uploadedFileName = nil
        uploadedFileURL = nil
        uploadError = nil
        agent.setPackageScanSummary(nil)
    }

    private func saveUploadedPackage(_ url: URL) throws -> URL {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let uploads = docs.appendingPathComponent("Uploads", isDirectory: true)
        try fileManager.createDirectory(at: uploads, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let baseName = url.deletingPathExtension().lastPathComponent
        let safeName = baseName.isEmpty ? "package" : baseName
        let destination = uploads
            .appendingPathComponent("\(safeName)-\(timestamp)")
            .appendingPathExtension(url.pathExtension)
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    // MARK: - 相册

    private func handlePhotoPicked(_ images: [UIImage]) {
        guard let first = images.first else { return }
        hasPhotoAttachment = true
        if let data = first.jpegData(compressionQuality: 0.8) {
            let hash = String(format: "%06d", Int(Date().timeIntervalSince1970) % 1000000)
            let fileName = "photo_\(hash).jpg"
            if let url = savePhotoData(data, name: fileName),
               let dim = ImageDimension.from(data: data) {
                agent.appendLocalMessage(
                    role: .user,
                    content: "已添加图片：\(fileName)（\(dim.width)x\(dim.height)）"
                )
                agent.appendLocalMessage(
                    role: .assistant,
                    content: "已收到图片，告诉我你需要对它做什么：OCR / 构图分析 / …"
                )
            }
        }
    }

    private func savePhotoData(_ data: Data, name: String) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let uploads = docs.appendingPathComponent("Uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let url = uploads.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

}

// MARK: - 气泡消息行

/// CatPaw 风格气泡：右侧用户消息半透明白底；
/// AI 文本无背景直接渲染 Markdown；工具调用内联卡片
private struct BubbleMessageRow: View {
    let message: ChatMessage

    private let userBubble = Color(red: 0.22, green: 0.50, blue: 0.32)   // 深绿
    private let surface = Color(red: 0.15, green: 0.15, blue: 0.16)
    private let surfaceElevated = Color(red: 0.20, green: 0.20, blue: 0.22)
    private let accent = Color(red: 0.36, green: 0.80, blue: 0.48)
    private let textPrimary = Color(white: 0.96)
    private let textSecondary = Color(white: 0.62)
    private let textTime = Color(white: 0.45)

    var body: some View {
        VStack(spacing: 0) {
            if message.isProgress {
                progressRow
            } else if message.role == .user {
                userBubbleRow
            } else if message.role == .assistant {
                aiTextRow
            } else if message.role == .tool {
                toolCallCard
            } else {
                // system 或其他
                Text(message.content)
                    .font(.caption2)
                    .foregroundColor(textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .contextMenu {
            Button { UIPasteboard.general.string = message.content } label: {
                Label("复制内容", systemImage: "doc.on.doc")
            }
            Button { UIPasteboard.general.string = quotedContent } label: {
                Label("复制为引用", systemImage: "quote.bubble")
            }
        }
    }

    // MARK: 进度消息：CatPaw 风格 — 小灰字 + 左侧小绿点

    private var progressRow: some View {
        HStack(spacing: 8) {
            PulseDot(color: accent, size: 6)
            Text(message.content)
                .font(.system(size: 12.5))
                .foregroundColor(textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    // MARK: 用户消息：右侧胶囊气泡

    private var userBubbleRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 0)
            Text(message.content)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [userBubble, userBubble.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(
                    RoundedCorner(radius: 18, corners: [.topLeft, .topRight, .bottomLeft])
                )
                .frame(maxWidth: UIScreen.main.bounds.width * 0.72, alignment: .trailing)
        }
    }

    // MARK: AI 消息：左对齐纯文本 + Markdown

    private var aiTextRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                MarkdownView(content: message.content)
                    .foregroundColor(textPrimary)
                if let name = message.name, !name.isEmpty {
                    Text(name)
                        .font(.caption2)
                        .foregroundColor(textTime)
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    // MARK: 工具调用卡片：暗色背景 + 左侧 accent 色条 + 状态点

    private var toolCallCard: some View {
        HStack(alignment: .top, spacing: 0) {
            // accent 色条
            Rectangle()
                .fill(toolAccent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                // 标题行：状态点 + 工具名 + 标题
                HStack(spacing: 6) {
                    PulseDot(color: toolAccent, size: 6)
                    Text(toolTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textPrimary)
                    Spacer()
                    Text(message.name ?? "")
                        .font(.caption2)
                        .foregroundColor(textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(surface)
                        .clipShape(Capsule())
                }
                // 结果
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(white: 0.18), lineWidth: 0.5)
        )
        .padding(.leading, 36)  // 缩进对齐 AI 消息正文
    }

    private var toolAccent: Color {
        if message.content.contains("失败") || message.content.contains("错误") {
            return Color(red: 0.95, green: 0.45, blue: 0.45)
        }
        return accent
    }

    // MARK: 工具名中文映射

    private var toolTitle: String {
        guard let name = message.name, !name.isEmpty else { return "工具调用" }
        let mapping: [String: String] = [
            "execute_command": "执行命令",
            "read_file": "读取文件",
            "list_dir": "列出目录",
            "write_file": "写入文件",
            "edit_file": "编辑文件",
            "search_files": "查找内容",
            "grep": "查找内容",
            "find": "查找内容",
            "git_status": "仓库状态",
            "git_branch": "分支信息",
            "git_log": "提交记录",
            "git_commit": "提交代码",
            "repo_overview": "仓库概览",
            "package_scan": "扫描应用",
            "mcp_call": "MCP 调用",
            "llm_call": "模型调用",
            "github_pull": "拉取仓库",
            "github_push": "推送仓库",
        ]
        if let mapped = mapping[name] { return mapped }
        return name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var quotedContent: String {
        message.content
            .components(separatedBy: .newlines)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }
}

// MARK: - 自定义形状：指定角圆角

private struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - 脉冲圆点（指示正在执行）

private struct PulseDot: View {
    let color: Color
    var size: CGFloat = 5
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(animating ? 1.5 : 0.8)
            .opacity(animating ? 0.4 : 1.0)
            .animation(
                Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: animating
            )
            .onAppear { animating = true }
    }
}

// MARK: - 图像尺寸读取（保留）

fileprivate struct ImageDimension: CustomStringConvertible {
    let width: Int
    let height: Int

    var description: String { "\(width)x\(height)" }

    static func from(data: Data) -> ImageDimension? {
        if let img = UIImage(data: data) {
            return ImageDimension(width: Int(img.size.width), height: Int(img.size.height))
        }
        return nil
    }
}
