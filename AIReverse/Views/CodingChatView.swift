import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// AIReverse 聊天界面
///
/// 视觉设计：
/// - 白色扁平化主题
/// - 气泡式对话（右侧用户消息 / 左侧 AI 文本）
/// - 工具调用以内联执行卡片形式呈现
/// - 顶部状态栏以细点 + 文字展示当前阶段
/// - 底部胶囊式输入框（集成相册与文件上传）
struct CodingChatView: View {
    @EnvironmentObject var modelStore: ModelStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var agent: CodingAgent
    @ObservedObject private var speech = SpeechRecognizer.shared

    @State private var inputText = ""
    @State private var showModelSettings = false
    @State private var showUploadPicker = false
    @State private var uploadedFileName: String?
    @State private var uploadedFileURL: URL?
    @State private var uploadError: String?
    @State private var sendTask: Task<Void, Never>?

    @State private var showPhotoPicker = false
    @State private var showSlashMenu = false
    @State private var hasPhotoAttachment = false
    /// 随下一条消息发送的图片（已压缩）
    @State private var pendingImageData: Data?
    // MARK: - 视觉常量

    /// accent: CatPaw 绿 (调和自旧版 MonkeyCode 绿，适配深色背景更亮)
    private let accent = Color(red: 0.18, green: 0.78, blue: 0.35)            // OpenMinis 绿 #2EC759
    private let background = Color(white: 1.0)                                 // 纯白
    private let surface = Color(red: 0.95, green: 0.95, blue: 0.97)           // #F2F2F7
    private let surfaceElevated = Color(red: 0.93, green: 0.93, blue: 0.95)
    private let userBubble = Color(red: 0.95, green: 0.95, blue: 0.97)      // 浅灰气泡
    private let textPrimary = Color(white: 0.04)
    private let textSecondary = Color(white: 0.45)
    private let cardBorder = Color(white: 0.87)
    private let packageExtensions: Set<String> = ["ipa", "tipa", "deb", "dylib", "apk"]

    init(workspace: WorkspaceManager) {
        _agent = StateObject(wrappedValue: CodingAgent(workspace: workspace))
    }

    // MARK: - 上下文用量条（OpenMinis 风格）

    private var contextBar: some View {
        let totalChars = agent.messages.reduce(0) { $0 + $1.content.count }
        let maxChars = 100_000
        let pct = min(Double(totalChars) / Double(maxChars), 1.0)
        return HStack(spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 10))
                .foregroundColor(textSecondary)
            Text("上下文已用 \(Int(pct * 100))% · \(totalChars / 1000)k / \(maxChars / 1000)k")
                .font(.system(size: 11))
                .foregroundColor(textSecondary)
            Spacer(minLength: 0)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.2))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(accent)
                            .frame(width: geo.size.width * pct)
                    }
            }
            .frame(height: 4)
            .frame(maxWidth: 80)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            statusBar
            messageList
            uploadStatusBar
            // AI 工作时显示的工具栏
            if agent.isWorking {
                workingToolbar
            }
            inputBar
        }
        .background(background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
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

                // 会话管理
                Menu {
                    Button {
                        newSession()
                    } label: {
                        Label("新会话", systemImage: "plus.text")
                    }
                    Button {
                        clearContext()
                    } label: {
                        Label("清空上下文", systemImage: "eraser.line.dashed")
                    }
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
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
                    .preferredColorScheme(.light)
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
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(maxSelection: 1) { images in
                handlePhotoPicked(images)
            }
        }
        .sheet(isPresented: $showSlashMenu) {
            SlashMenuView { command in
                showSlashMenu = false
                applySlashCommand(command)
            }
        }
        .onAppear {
            if agent.messages.isEmpty { seedWelcome() }
            speech.onText = { text in
                inputText = text
            }
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
                        BubbleMessageRow(
                            message: msg,
                            onDelete: {
                                agent.deleteMessage(id: msg.id)
                            },
                            onRegenerate: msg.role == .assistant ? {
                                Task { @MainActor in
                                    if let model = modelStore.selectedModel {
                                        await agent.regenerateLast(model: model)
                                    }
                                }
                            } : nil
                        )
                        .id(msg.id)
                    }
                    // 流式输出中的回复（逐字增长）
                    if let streaming = agent.streamingText {
                        BubbleMessageRow(message: ChatMessage(role: .assistant, content: streaming))
                            .id("streaming")
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
            .onChange(of: agent.streamingText) { _ in
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        }
    }

    // MARK: - 输入区

    private var inputBar: some View {
        VStack(spacing: 6) {
            // 多行输入框
            if #available(iOS 16.0, *) {
                TextField("发送消息…", text: $inputText, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundColor(textPrimary)
                    .lineSpacing(2)
            } else {
                TextField("发送消息…", text: $inputText)
                    .font(.system(size: 16))
                    .foregroundColor(textPrimary)
            }

            // 底部按钮行：左（斜杠 + 文件 + 相册），右（发送 / 停止）
            HStack(spacing: 14) {
                Button {
                    showSlashMenu = true
                } label: {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundColor(textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(agent.isWorking)

                Button {
                    showUploadPicker = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundColor(textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(agent.isWorking)

                Button {
                    showPhotoPicker = true
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(hasPhotoAttachment ? accent : textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(agent.isWorking)

                Spacer()

                // 语音输入按钮
                Button {
                    if speech.isRecording {
                        speech.stop()
                    } else {
                        if !speech.hasPermission {
                            speech.requestPermissions()
                        }
                        speech.start()
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundColor(speech.isRecording ? .red : textSecondary)
                }
                .buttonStyle(.plain)

                actionButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 发送按钮（OpenMinis 风格 34pt 圆形图标）

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
                .font(.system(size: 34))
                .foregroundStyle(agent.isWorking ? Color.red : sendButtonColor)
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

    // MARK: - AI 工作工具栏

    private var workingToolbar: some View {
        HStack(spacing: 12) {
            // 状态指示器
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(accent)
                Text(agent.stageText ?? "处理中…")
                    .font(.caption)
                    .foregroundColor(textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // 停止按钮
            Button {
                stopConversation()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("停止")
                        .font(.caption)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.8))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // 清空对话按钮
            Button {
                agent.resetConversation()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                    Text("清空")
                        .font(.caption)
                }
                .foregroundColor(textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(surfaceElevated)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(surface.overlay(accent.opacity(0.03)))
        .overlay(
            Rectangle()
                .fill(cardBorder)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Actions

    private var sendButtonColor: Color {
        if canResumeFromInputButton { return accent }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Color(.systemGray4) }
        return Color(.systemGreen)
    }

    private var inputButtonIcon: String {
        if agent.isWorking { return "stop.circle.fill" }
        if canResumeFromInputButton { return "arrow.clockwise.circle.fill" }
        return "arrow.up.circle.fill"
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

    /// 打开新会话窗口：清空当前消息并重置上下文
    private func newSession() {
        sendTask?.cancel()
        sendTask = nil
        agent.cancel()
        agent.resetConversation()
        inputText = ""
    }

    /// 清空上下文：只清空消息，保留其他状态
    private func clearContext() {
        if agent.isWorking {
            sendTask?.cancel()
            sendTask = nil
            agent.cancel()
        }
        agent.resetConversation()
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
        let prompt = trimmed
        let image = pendingImageData
        pendingImageData = nil
        hasPhotoAttachment = false
        sendTask = Task { @MainActor in
            guard let model = modelStore.selectedModel else {
                agent.errorMessage = "请先添加并选择模型"
                return
            }
            await agent.send(prompt, model: model, imageData: image)
            sendTask = nil
        }
    }

    private func applySlashCommand(_ command: SlashCommand) {
        switch command {
        case .newSession:
            newSession()
        case .clearContext:
            clearContext()
        case .prompt(let text):
            inputText = text
        }
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
        // 压缩到适合发送的尺寸（长边 ≤1600px，JPEG 0.7）作为真实附件
        guard let data = Self.normalizedJPEGData(from: first) else {
            uploadError = "图片处理失败，请重试"
            return
        }
        pendingImageData = data
        hasPhotoAttachment = true
        uploadError = nil
        // 原图归档到 Uploads（供文件管理 / shell 工具访问）
        let hash = String(format: "%06d", Int(Date().timeIntervalSince1970) % 1000000)
        _ = savePhotoData(first.jpegData(compressionQuality: 0.9) ?? data, name: "photo_\(hash).jpg")
    }

    /// 长边超过 1600px 时等比缩放，返回 JPEG 数据
    private static func normalizedJPEGData(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 1600
        var target = image
        let longest = max(image.size.width, image.size.height)
        if longest > maxSide {
            let ratio = maxSide / longest
            let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            UIGraphicsBeginImageContextWithOptions(newSize, true, 1)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            if let resized = UIGraphicsGetImageFromCurrentImageContext() {
                target = resized
            }
            UIGraphicsEndImageContext()
        }
        return target.jpegData(compressionQuality: 0.7)
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
    var onDelete: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    @ObservedObject private var tts = TTSManager.shared

    private let userBubble = Color(red: 0.95, green: 0.95, blue: 0.97)   // 浅灰
    private let surface = Color(red: 0.95, green: 0.95, blue: 0.97)
    private let surfaceElevated = Color(red: 0.93, green: 0.93, blue: 0.95)
    private let accent = Color(red: 0.18, green: 0.78, blue: 0.35)       // 绿 #2EC759
    private let textPrimary = Color(white: 0.04)
    private let textSecondary = Color(white: 0.45)
    private let textTime = Color(white: 0.60)
    // 工具卡专用：OpenMinis 深色卡片
    private let toolCardBg = Color(red: 0.12, green: 0.12, blue: 0.14)   // #1E1E23
    private let toolCardText = Color(white: 0.88)
    private let toolCardSubtext = Color(white: 0.55)
    private let toolCardFail = Color(red: 0.85, green: 0.40, blue: 0.40)

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
            Button { TTSManager.shared.toggle(message.content) } label: {
                Label(tts.isSpeaking ? "停止朗读" : "朗读", systemImage: tts.isSpeaking ? "stop.circle" : "speaker.wave.2")
            }
            if onRegenerate != nil {
                Button { onRegenerate?() } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
            }
            if onDelete != nil {
                Button(role: .destructive) { onDelete?() } label: {
                    Label("删除此消息", systemImage: "trash")
                }
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
            VStack(alignment: .trailing, spacing: 6) {
                if let data = message.imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.5, maxHeight: 220)
                        .clipShape(
                            RoundedCorner(radius: 14, corners: [.topLeft, .topRight, .bottomLeft])
                        )
                }
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundColor(textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(userBubble)
                    .clipShape(
                        RoundedCorner(radius: 18, corners: [.topLeft, .topRight, .bottomLeft])
                    )
            }
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
            Button {
                TTSManager.shared.toggle(message.content)
            } label: {
                Image(systemName: tts.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 13))
                    .foregroundColor(tts.isSpeaking ? accent : textTime)
            }
            .buttonStyle(.plain)
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
                        .foregroundColor(toolCardText)
                    Spacer()
                    Text(message.name ?? "")
                        .font(.caption2)
                        .foregroundColor(toolCardSubtext)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(white: 0.18))
                        .clipShape(Capsule())
                }
                // 结果
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(toolCardSubtext)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(toolCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(white: 0.20), lineWidth: 0.5)
        )
        .padding(.leading, 36)  // 缩进对齐 AI 消息正文
    }

    private var toolAccent: Color {
        if message.content.contains("失败") || message.content.contains("错误") {
            return toolCardFail
        }
        return accent
    }

    // MARK: 工具名中文映射

    private var toolTitle: String {
        guard let name = message.name, !name.isEmpty else { return "工具调用" }
        let mapping: [String: String] = [
            "shell_execute": "执行命令",
            "read_file": "读取文件",
            "list_dir": "列出目录",
            "write_file": "写入文件",
            "edit_file": "编辑文件",
            "find_files": "搜索文件",
            "grep": "查找内容",
            "http_request": "HTTP 请求",
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

// MARK: - 斜杠命令（OpenMinis 风格快捷菜单）

enum SlashCommand: Identifiable {
    case newSession
    case clearContext
    case prompt(String)

    var id: String {
        switch self {
        case .newSession: return "new"
        case .clearContext: return "clear"
        case .prompt(let t): return "p-\(t)"
        }
    }
}

private struct SlashMenuView: View {
    let onSelect: (SlashCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    private let promptTemplates: [(String, String)] = [
        ("review", "审查这段代码的问题与优化点"),
        ("explain", "解释这段代码的作用"),
        ("fix", "修复以下报错"),
        ("test", "为这段代码编写测试"),
        ("optimize", "优化这段代码的性能与可读性"),
        ("translate", "翻译为中文"),
    ]

    var body: some View {
        NavigationView {
            List {
                Section("会话") {
                    Button { onSelect(.newSession) } label: {
                        Label("新会话", systemImage: "square.and.pencil")
                    }
                    Button { onSelect(.clearContext) } label: {
                        Label("清空上下文", systemImage: "trash")
                    }
                }
                Section("提示词模板") {
                    ForEach(promptTemplates, id: \.0) { icon, text in
                        Button { onSelect(.prompt(text)) } label: {
                            Label(text, systemImage: icon)
                        }
                    }
                }
            }
            .navigationTitle("快捷命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
