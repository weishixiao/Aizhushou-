import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// MonkeyCode 工作台风格的单聊编程助手界面：
/// 顶部模型信息条 + 文档式消息流 + 圆角输入区
struct CodingChatView: View {
    @EnvironmentObject var modelStore: ModelStore
    @StateObject private var agent: CodingAgent

    @State private var inputText = ""
    @State private var showRepoSettings = false
    @State private var showModelSettings = false
    @State private var showUploadPicker = false
    @State private var uploadedFileName: String?
    @State private var uploadError: String?

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)
    private let packageExtensions: Set<String> = ["ipa", "tipa", "deb", "dylib", "apk"]

    init(workspace: WorkspaceManager) {
        _agent = StateObject(wrappedValue: CodingAgent(workspace: workspace))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            uploadStatusBar
            inputBar
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
                Button {
                    showRepoSettings = true
                } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(accent)
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
        .onAppear {
            if agent.messages.isEmpty {
                seedWelcome()
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
                    if agent.isWorking {
                        stageIndicator
                            .id("typing")
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
            .onChange(of: agent.isWorking) { _ in
                withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
            }
        }
    }

    private var stageIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.stageText ?? "思考中")
                    .font(.footnote)
                    .foregroundColor(.primary)
                Text("AI 正在处理，请稍候")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - 输入区

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
                        .lineLimit(1...5)
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

            // 绿色圆形发送按钮
            Button {
                sendInput()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(inputText.trimmingCharacters(in: .whitespaces).isEmpty || agent.isWorking ? Color(.systemGray4) : accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || agent.isWorking)
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

    // MARK: - Actions

    private func sendInput() {
        send(inputText)
        inputText = ""
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !agent.isWorking else { return }
        Task {
            guard let model = modelStore.selectedModel else {
                agent.errorMessage = "请先在设置中添加并选择模型"
                return
            }
            await agent.send(trimmed, model: model)
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
            return
        }
        do {
            let savedURL = try saveUploadedPackage(url)
            uploadedFileName = savedURL.lastPathComponent
            uploadError = nil
            agent.appendLocalMessage(role: .user, content: "已上传文件：\(savedURL.lastPathComponent)")
        } catch {
            uploadError = "上传失败：\(error.localizedDescription)"
            uploadedFileName = nil
        }
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

    var body: some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 60)
                    Text(message.content)
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(red: 0.10, green: 0.62, blue: 0.42).opacity(0.12))
                        .cornerRadius(16)
                        .textSelection(.enabled)
                }
            } else if message.role == .assistant {
                // 文档式排版：无气泡背景，直接铺开
                MarkdownView(content: message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if message.role == .tool {
                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(message.content)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
