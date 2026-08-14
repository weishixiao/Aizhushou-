import SwiftUI
import UIKit

/// MonkeyCode 工作台风格的单聊编程助手界面：
/// 顶部模型信息条 + 文档式消息流 + 圆角输入区
struct CodingChatView: View {
    @EnvironmentObject var modelStore: ModelStore
    @EnvironmentObject var analysisStore: AnalysisStore
    @StateObject private var agent: CodingAgent

    @State private var inputText = ""
    @State private var showRepoSettings = false
    @State private var showModelPicker = false

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)

    init(workspace: WorkspaceManager) {
        _agent = StateObject(wrappedValue: CodingAgent(workspace: workspace))
    }

    var body: some View {
        VStack(spacing: 0) {
            modelBar
            analysisContextBar
            if !hasStartedConversation {
                repoEntryCard
            }
            messageList
            inputBar
        }
        .background(backgroundColor.ignoresSafeArea())
        .navigationTitle("实现 Git 仓库接口")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showRepoSettings = true
                } label: {
                    Label("仓库", systemImage: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(accent)
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
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(modelStore: modelStore)
        }
        .onAppear {
            syncAnalysisContext()
            if agent.messages.isEmpty {
                seedWelcome()
            }
        }
        .onChange(of: analysisStore.activeResult?.url) { _ in
            syncAnalysisContext()
        }
    }

    private func syncAnalysisContext() {
        let result = analysisStore.activeResult
        agent.setAnalysisContext(result)
        agent.includeAnalysisContext = result != nil
    }

    private var backgroundColor: Color {
        Color(red: 0.98, green: 0.97, blue: 0.95)
    }

    // MARK: - 顶部模型信息条

    private var modelBar: some View {
        HStack(spacing: 10) {
            // 圆环徽标（会话序号）
            ZStack {
                Circle()
                    .stroke(Color.orange, lineWidth: 1.5)
                    .frame(width: 32, height: 32)
                Text("\(sessionCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
            }

            // 模型胶囊（点击切换模型）
            Button {
                showModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("基础模型")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(modelName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // token 信息
            Text("\(tokenDisplay)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // 允许修改开关（绿色小徽标）
            Button {
                agent.allowMutating.toggle()
            } label: {
                Text(agent.allowMutating ? "可修改" : "只读")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(agent.allowMutating ? accent : Color(.systemGray5))
                    .foregroundColor(agent.allowMutating ? .white : .secondary)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var sessionCount: Int {
        agent.messages.filter { $0.role == .user }.count + 1
    }

    /// 是否已开始对话（有用户消息则隐藏引导卡片）
    private var hasStartedConversation: Bool {
        agent.messages.contains { $0.role == .user }
    }

    /// 仓库引导卡片：会话开始前的显眼入口
    private var repoEntryCard: some View {
        let isDefault = agent.workspace.workspaceRoot?.path == agent.workspace.defaultRoot()?.path
        let label = isDefault ? "打开 / 导入仓库" : "切换仓库"
        let caption = isDefault
            ? "连接你的 Git 仓库后，AI 才能读取并优化你的项目代码。"
            : "当前仓库：\(agent.workspace.workspaceRoot?.lastPathComponent ?? "未知")"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16))
                    .foregroundColor(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接 Git 仓库")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            Button {
                showRepoSettings = true
            } label: {
                Label(label, systemImage: "folder.fill.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accent)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.white)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// 分析上下文状态条：显示当前分析的文件，并支持开关附带
    private var analysisContextBar: some View {
        let hasAnalysis = analysisStore.activeResult != nil
        return HStack(spacing: 8) {
            Image(systemName: "doc.magnifyingglass")
                .font(.caption)
                .foregroundColor(hasAnalysis ? accent : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("分析上下文")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(analysisStore.activeResult?.url.lastPathComponent ?? "未加载分析文件")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                guard hasAnalysis else { return }
                agent.includeAnalysisContext.toggle()
            } label: {
                Text(hasAnalysis ? (agent.includeAnalysisContext ? "已附带" : "已关闭") : "无上下文")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(hasAnalysis && agent.includeAnalysisContext ? accent : Color(.systemGray5))
                    .foregroundColor(hasAnalysis && agent.includeAnalysisContext ? .white : .secondary)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(!hasAnalysis)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var modelName: String {
        if let model = modelStore.selectedModel {
            return model.modelID
        }
        return "未配置模型"
    }

    private var tokenDisplay: String {
        let count = agent.messages.reduce(0) { $0 + $1.content.count }
        if count >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK tokens", Double(count) / 1_000)
        }
        return "\(count) tokens"
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
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(accent)
                            Text("思考中...")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
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

    // MARK: - 输入区

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 输入框（胶囊形白底）
            HStack(alignment: .bottom, spacing: 0) {
                Button {
                    showRepoSettings = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                .buttonStyle(.plain)

                if #available(iOS 16.0, *) {
                    TextField("向 AI 描述你的编码任务...", text: $inputText, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.system(size: 15))
                        .padding(.vertical, 10)
                } else {
                    TextField("向 AI 描述你的编码任务...", text: $inputText)
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
        .background(Color.white)
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
        # 实现 Git 仓库接口

        欢迎使用编程助手。你可以让我直接读写代码、查看 git 状态并提交变更；如果在「分析」页已打开文件，我还能基于分析结果回答逆向问题。

        ## 开始之前

        1. 点右上角文件夹图标，打开本地目录或导入 GitHub 仓库
        2. 在「模型设置」页配置并选择一个模型
        3. 开启顶部「可修改」开关后，我才能写文件与提交

        ## 试试这样问我

        - 查看当前工作区有哪些文件
        - 分析页打开的文件主要做了什么，有没有可疑网络请求
        - 帮我新增一个工具函数
        - 提交当前的所有变更
        """
        agent.messages.append(ChatMessage(role: .assistant, content: text))
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

/// 模型选择器：点击模型胶囊后弹出，选择当前使用的模型
struct ModelPickerView: View {
    @ObservedObject var modelStore: ModelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if modelStore.models.isEmpty {
                    Section {
                        Text("还没有添加模型，请先到「模型设置」页添加。")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section("选择模型") {
                        ForEach(modelStore.models) { model in
                            Button {
                                modelStore.select(model.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: modelStore.selectedModel?.id == model.id
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(modelStore.selectedModel?.id == model.id
                                                         ? Color(red: 0.10, green: 0.62, blue: 0.42) : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(model.modelID)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("切换模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
