import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// MonkeyCode 工作台风格的单聊编程助手界面：
/// 顶部模型信息条 + 文档式消息流 + 圆角输入区
struct CodingChatView: View {
    @EnvironmentObject var modelStore: ModelStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var agent: CodingAgent

    @State private var inputText = ""
    @State private var showRepoSettings = false
    @State private var showModelSettings = false
    @State private var showUploadPicker = false
    @State private var uploadedFileName: String?
    @State private var uploadedFileURL: URL?
    @State private var uploadError: String?
    @State private var sendTask: Task<Void, Never>?

    // 底部三功能键状态
    @State private var showAppsSheet = false            // 「应用」：注入插件
    @State private var showProcessSheet = false         // 「进程」：发往 AI 破解
    @State private var targetApp: InstalledApp?          // 「进程」选中的目标应用（停留在聊天界面）
    @State private var showPhotoPicker = false          // 「相册」：调取本机相册
    @State private var showMemorySheet = false          // 「内存」：内存扫描/读写/patch
    @State private var hasPhotoAttachment = false

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)
    private let packageExtensions: Set<String> = ["ipa", "tipa", "deb", "dylib", "apk"]

    init(workspace: WorkspaceManager) {
        _agent = StateObject(wrappedValue: CodingAgent(workspace: workspace))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            uploadStatusBar
            modelSwitcher
            targetAppBar
            inputBar
            quickActionsBar
        }
        .background(backgroundColor.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
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

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        showRepoSettings = true
                    } label: {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(accent)
                    }
                }
            }

            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(navigationProgressTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(navigationProgressSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    }
            }
        }
        .sheet(isPresented: $showRepoSettings) {
            NavigationView {
                RepoManagerView(agent: agent)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showRepoSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showModelSettings) {
            NavigationView {
                SettingsHubView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showModelSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showUploadPicker) {
            DocumentPicker(allowedContentTypes: [.item], onPick: { url in
                importPackageFile(url)
            })
        }
        // 「相册」：调取本机相册
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(maxSelection: 1) { images in
                handlePhotoPicked(images)
            }
        }
        // 「应用」：选择应用注入插件
        .sheet(isPresented: $showAppsSheet) {
            NavigationView {
                InstalledAppsView(intent: .injectPlugin)
            }
        }
        // 「进程」：选择应用发往 AI 破解
        .sheet(isPresented: $showProcessSheet) {
            NavigationView {
                InstalledAppsView(intent: .addressToAI) { app in
                    DispatchQueue.main.async {
                        selectTargetApp(app)
                    }
                }
            }
        }
        // 「内存」：内存扫描/读写/代码 Patch
        .sheet(isPresented: $showMemorySheet) {
            NavigationView {
                MemoryView()
            }
        }
        .onAppear {
            if agent.messages.isEmpty {
                seedWelcome()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active, agent.pendingTask != nil, !agent.isWorking {
                // 保持恢复提示可见，等待用户点按继续
            }
        }
    }

    private var backgroundColor: Color {
        Color(red: 0.98, green: 0.97, blue: 0.95)
    }

    // MARK: - 状态信息

    private var navigationProgressTitle: String {
        if agent.isWorking {
            return agent.stageText ?? "处理中"
        }
        if let task = currentTaskTitle {
            return task
        }
        return "等待输入"
    }

    private var navigationProgressSubtitle: String {
        if agent.isWorking {
            return "当前任务进行中"
        }
        if agent.messages.contains(where: { $0.role == .user }) {
            return "上次对话已恢复"
        }
        return "发送消息或上传文件开始任务"
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
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        removeUploadedFile()
                    } label: {
                        Label("删除", systemImage: "xmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.white)
            } else if let error = uploadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.white)
            }
        }
    }

    // MARK: - 文档式消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(agent.messages) { msg in
                        DocumentMessageRow(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: agent.messages.count) { _ in
                withAnimation {
                    if let last = agent.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - 输入区

    private var modelSwitcher: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("当前模型")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(selectedModelTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            Spacer()

            if modelStore.models.isEmpty {
                Button {
                    showModelSettings = true
                } label: {
                    Label("添加模型", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(modelStore.models) { model in
                        Button {
                            modelStore.select(model.id)
                        } label: {
                            Label(model.name, systemImage: modelStore.selectedModel?.id == model.id ? "checkmark.circle.fill" : "circle")
                        }
                    }

                    Button {
                        showModelSettings = true
                    } label: {
                        Label("管理模型", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Label("切换", systemImage: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundColor(agent.isWorking ? .secondary : accent)
                }
                .disabled(agent.isWorking)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(backgroundColor)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .top
        )
    }

    private var selectedModelTitle: String {
        guard let model = modelStore.selectedModel else { return "未配置模型" }
        return "\(model.name) · \(model.modelID)"
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 输入框（胶囊形白底）
            HStack(alignment: .bottom, spacing: 0) {
                Button {
                    showUploadPicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                .buttonStyle(.plain)

                if #available(iOS 16.0, *) {
                    TextField("发送消息，或上传 ipa / tipa / deb / dylib / apk...", text: $inputText, axis: .vertical)
                        .font(.system(size: 15))
                        .padding(.vertical, 10)
                } else {
                    TextField("发送消息，或上传 ipa / tipa / deb / dylib / apk...", text: $inputText)
                        .font(.system(size: 15))
                        .padding(.vertical, 10)
                }

                Button {
                    // 语音输入占位
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                .buttonStyle(.plain)
            }
            .background(Color.white)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )

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
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(sendButtonColor)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(inputButtonDisabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(backgroundColor)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - 目标应用条（进程功能选中后停留在聊天界面）

    @ViewBuilder
    private var targetAppBar: some View {
        if let targetApp {
            HStack(spacing: 8) {
                if let icon = targetApp.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                        .cornerRadius(5)
                } else {
                    Image(systemName: "app.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("目标：\(targetApp.displayName)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(targetApp.bundleID)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    clearTargetApp()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(accent.opacity(0.1))
            .overlay(
                Rectangle()
                    .fill(Color.black.opacity(0.04))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
    }

    // MARK: - 底部三功能键（应用 / 相册 / 进程）

    private var quickActionsBar: some View {
        HStack(spacing: 0) {
            quickActionButton(
                title: "应用",
                icon: "app.badge.fill",
                action: { showAppsSheet = true }
            )
            quickActionButton(
                title: "相册",
                icon: "photo.on.rectangle.angled",
                action: { showPhotoPicker = true }
            )
            quickActionButton(
                title: "进程",
                icon: "cpu",
                action: { showProcessSheet = true }
            )
            quickActionButton(
                title: "内存",
                icon: "memory",
                action: { showMemorySheet = true }
            )
        }
        .padding(.vertical, 7)
        .background(backgroundColor)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .top
        )
    }

    private func quickActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(accent)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(agent.isWorking)
    }

    /// 「相册」选择到图片后的处理：保存到沙盒并注入会话上下文
    private func handlePhotoPicked(_ images: [UIImage]) {
        guard let first = images.first else { return }
        hasPhotoAttachment = true
        if let data = first.jpegData(compressionQuality: 0.8) {
            let hash = String(format: "%06d", Int(Date().timeIntervalSince1970) % 1000000)
            let fileName = "photo_\(hash).jpg"
            if let url = savePhotoData(data, name: fileName) {
                guard let dim = ImageDimension.from(data: data) else { return }
                agent.appendLocalMessage(
                    role: .user,
                    content: "已从相册添加图片：\(fileName)（尺寸 \(dim.width)x\(dim.height)）"
                )
                agent.appendLocalMessage(role: .assistant, content: "已接收图片，你可以告诉我需要对这张图片做什么，例如 OCR 识别、构图分析等。")
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

    /// 「进程」选中应用后：设置为当前分析目标（停留在聊天界面，由用户发指令）
    private func selectTargetApp(_ app: InstalledApp) {
        showProcessSheet = false
        targetApp = app
        agent.appendLocalMessage(
            role: .assistant,
            content: "已选中目标应用：**\(app.displayName)**（\(app.bundleID)）\n现在可以发送指令给它（例如：分析它的加载逻辑、生成去除广告的插件、修改某个存档等）。"
        )
    }

    /// 关闭当前目标应用选择
    private func clearTargetApp() {
        targetApp = nil
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

    private var inputButtonDisabled: Bool {
        if agent.isWorking { return false }
        if canResumeFromInputButton { return false }
        return inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            agent.errorMessage = "请先在设置中配置并选择用于恢复的模型"
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
        // 若已选中目标应用，把目标信息注入 AI 上下文（用户指令针对该应用执行）
        if let targetApp {
            prompt += """

            【当前目标应用】\(targetApp.displayName)（\(targetApp.bundleID)）
            路径：\(targetApp.bundlePath)
            版本：\(targetApp.version)
            请针对上述目标应用执行我的指令（分析、生成插件、修改数据等）。
            """
        }
        sendTask = Task { @MainActor in
            guard let model = modelStore.selectedModel else {
                agent.errorMessage = "请先在设置中添加并选择模型"
                return
            }
            await agent.send(prompt, model: model)
            sendTask = nil
        }
    }

    private func seedWelcome() {
        let text = """
        你好，我是 AIReverse。你可以直接发消息，也可以点击输入框左侧附件上传 ipa、tipa、deb、dylib 或 apk 文件。
        """
        agent.appendLocalMessage(role: .assistant, content: text)
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
        if let url = uploadedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
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
}

/// 文档式消息行：AI 消息直接铺开渲染 Markdown，用户消息为绿色轻量卡片
struct DocumentMessageRow: View {
    let message: ChatMessage

    private let aiBubble = Color(red: 0.92, green: 0.92, blue: 0.95)  // 浅灰蓝 AI 气泡
    private let userBubble = Color(red: 0.85, green: 0.95, blue: 0.88) // 浅绿 用户气泡
    private let toolBubble = Color(red: 0.90, green: 0.90, blue: 0.90) // 浅灰工具气泡

    var body: some View {
        VStack(spacing: 2) {
            if message.role == .assistant {
                // AI 消息：左对齐，浅灰蓝气泡
                HStack {
                    MarkdownView(content: message.content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(aiBubble)
                        .cornerRadius(14)
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: .leading)
                    Spacer(minLength: 0)
                }
            } else if message.role == .user {
                // 用户消息：右对齐，浅绿气泡
                HStack {
                    Spacer(minLength: 0)
                    Text(message.content)
                        .font(.system(size: 15))
                        .foregroundColor(Color(red: 0.10, green: 0.10, blue: 0.12)) // 深色字体
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(userBubble)
                        .cornerRadius(14)
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.85, alignment: .trailing)
                }
            } else if message.role == .tool {
                HStack {
                    Image(systemName: "hammer.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(message.content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(toolBubble)
                .cornerRadius(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(message.content)
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
            Button { UIPasteboard.general.string = formattedDate } label: {
                Label("复制时间", systemImage: "clock")
            }
        }
    }

    private var quotedContent: String {
        message.content
            .components(separatedBy: .newlines)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter.string(from: message.date)
    }
}

/// 从 JPEG/PNG 二进制读取图像尺寸的轻量辅助
fileprivate struct ImageDimension: CustomStringConvertible {
    let width: Int
    let height: Int

    var description: String { "\(width)x\(height)" }

    static func from(data: Data) -> ImageDimension? {
        // 优先用 UIImage 取尺寸（最可靠）
        if let img = UIImage(data: data) {
            return ImageDimension(width: Int(img.size.width), height: Int(img.size.height))
        }
        return nil
    }
}
