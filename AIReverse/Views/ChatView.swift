import SwiftUI
import UIKit

/// 聊天视图：用户与 AI 对话，可附加当前分析结果作为上下文。
struct ChatView: View {
    @EnvironmentObject var modelStore: ModelStore
    @EnvironmentObject var analysisStore: AnalysisStore

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var includeContext = true

    private let client = LLMClient()

    var body: some View {
        VStack(spacing: 0) {
            // 上下文开关
            contextBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if isSending {
                            HStack {
                                ProgressView()
                                Text("分析中...")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .id("typing")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: isSending) { _ in
                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                }
            }

            // 错误提示
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            inputBar
        }
        .navigationTitle("AI 逆向对话")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if messages.isEmpty {
                seedWelcomeMessage()
            }
            includeContext = analysisStore.activeResult != nil
        }
        .onChange(of: analysisStore.activeResult?.url) { url in
            includeContext = url != nil
        }
    }

    private var contextBar: some View {
        HStack {
            Image(systemName: includeContext ? "doc.on.clipboard.fill" : "doc.on.clipboard")
                .foregroundColor(includeContext ? .blue : .secondary)
            Text("附带当前分析结果")
                .font(.footnote)
            Spacer()
            if let result = analysisStore.activeResult {
                Text(result.macho.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
            Toggle("", isOn: $includeContext)
                .labelsHidden()
                .disabled(analysisStore.activeResult == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    private var inputBar: some View {
        HStack(alignment: .bottom) {
            if #available(iOS 16.0, *) {
                TextField("向 AI 提问（例：分析登录逻辑）", text: $inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            } else {
                TextField("向 AI 提问（例：分析登录逻辑）", text: $inputText)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
            }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
        }
        .padding()
    }

    private func seedWelcomeMessage() {
        var text = "我是你的 AI 逆向助手。你可以在「分析」页打开一个 .tipa / .ipa / .app 或 Mach-O 二进制，然后在这里向我提问，例如：\n\n"
        if let result = analysisStore.activeResult {
            text += "当前已加载分析结果，请描述这个 App 的整体功能，重点关注可疑的网络请求。"
        } else {
            text += "当前还没有加载分析文件，请先在分析页选择文件。"
        }
        messages.append(ChatMessage(role: .assistant, content: text))
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        errorMessage = nil

        messages.append(ChatMessage(role: .user, content: text))
        isSending = true

        Task {
            var conversation = messages

            // 附加系统提示：包含分析上下文
            var systemPrompt = "你是专业的 iOS 逆向分析助手。使用简体中文回答，分析要专业、分点、引用具体地址、类名、方法名、字符串或符号名。优先识别网络接口、鉴权逻辑、加密解密、越狱检测、反调试、证书校验和敏感数据存储。"
            if includeContext, let result = analysisStore.activeResult {
                systemPrompt += "\n\n=== 当前分析上下文 ===\n\(result.contextText)"
            }
            conversation.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)

            guard let model = modelStore.selectedModel else {
                errorMessage = "请先在设置中添加并选择模型"
                isSending = false
                return
            }

            do {
                let reply = try await client.chat(model: model, messages: conversation)
                messages.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                errorMessage = error.localizedDescription
                messages.append(ChatMessage(role: .assistant, content: "请求失败：\(error.localizedDescription)"))
            }
            isSending = false
        }
    }
}

/// 单个聊天气泡
struct MessageBubble: View {
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .system {
                    Text(message.content)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color(.systemGray5))
                        .cornerRadius(8)
                } else {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(message.role == .user ? Color.blue : Color(.systemGray6))
                        .foregroundColor(message.role == .user ? .white : .primary)
                        .cornerRadius(14)
                }

                if message.role != .system {
                    Button {
                        UIPasteboard.general.string = message.content
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundColor(copied ? .green : .secondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            if message.role == .assistant || message.role == .system {
                Spacer(minLength: 20)
            }
        }
    }
}
