import Foundation
import UIKit

/// 工具卡片状态
enum ToolCallStatus: Equatable {
    case running
    case success
    case failed
}

struct ToolCallCard: Identifiable {
    let id: String
    let name: String
    let argumentsText: String
    var status: ToolCallStatus
    var resultPreview: String?
}

/// 聊天 + 工具调用的编排状态
final class CodingAgent: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var toolCards: [ToolCallCard] = []
    @Published var isWorking = false
    @Published var allowMutating = false
    @Published var errorMessage: String?
    @Published var stageText: String?
    @Published var packageScanSummary: String?

    var repoConfig = GitRepoConfig.load()
    private(set) var workspace: WorkspaceManager
    private let github = GitHubAPIClient()
    private let registry = ToolRegistry()
    private let tracker = GitStatusTracker()

    private let client = LLMClient()
    private var isCancelled = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private let maxToolIterations = 15
    private let conversationFileName = "conversation.json"

    init(workspace: WorkspaceManager) {
        self.workspace = workspace
        tracker.bind(to: workspace)
        registry.register(ReadFileTool())
        registry.register(ListDirTool())
        registry.register(GitStatusTool())
        registry.register(GitBranchTool())
        registry.register(GitLogTool())
        registry.register(RepoOverviewTool())
        registry.register(WriteFileTool())
        registry.register(GitCommitTool())
        restoreConversation()
    }

    /// 发送用户消息并驱动工具调用循环
    func send(_ userText: String, model: AIModelConfig) async {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        isCancelled = false
        let taskID = await MainActor.run { beginBackgroundTask() }
        defer {
            Task { @MainActor in
                endBackgroundTask(taskID)
            }
        }

        await MainActor.run {
            isWorking = true
            stageText = "准备发送请求"
            errorMessage = nil
            messages.append(ChatMessage(role: .user, content: text))
            saveConversation()
        }

        var history = buildHistory()

        do {
            var finalText: String?
            toolLoop: for _ in 0..<maxToolIterations {
                if isCancelled { break }

                await MainActor.run {
                    stageText = "等待模型回复"
                }
                let reply = try await client.chat(
                    model: model,
                    messages: history,
                    tools: registry.openAIDefinitions(includeMutating: allowMutating)
                )
                switch reply {
                case .text(let content):
                    finalText = content
                    await MainActor.run {
                        stageText = "整理回复内容"
                        messages.append(ChatMessage(role: .assistant, content: content))
                        saveConversation()
                    }
                    break toolLoop
                case .toolCalls(let calls):
                    let assistantMsg = ChatMessage(role: .assistant, content: "", assistantToolCalls: calls)
                    history.append(assistantMsg)

                    var toolMessages: [ChatMessage] = []
                    for call in calls {
                        if isCancelled { break }
                        await MainActor.run {
                            stageText = "执行工具：\(call.name)"
                            upsertToolCard(call, status: .running)
                        }
                        do {
                            github.platform = repoConfig.platform
                            let result = try await registry.execute(
                                name: call.name,
                                arguments: call.arguments,
                                allowMutating: allowMutating,
                                workspace: workspace,
                                github: github,
                                repoConfig: repoConfig
                            )
                            let output = truncate(result.output, limit: 8000)
                            toolMessages.append(ChatMessage(
                                role: .tool,
                                content: output,
                                toolCallID: call.id,
                                name: call.name
                            ))
                            await MainActor.run {
                                stageText = result.success ? "工具执行完成：\(call.name)" : "工具执行失败：\(call.name)"
                                upsertToolCard(call, status: result.success ? .success : .failed, result: result.output)
                            }
                        } catch {
                            let msg = "执行失败：\(error.localizedDescription)"
                            toolMessages.append(ChatMessage(role: .tool, content: msg, toolCallID: call.id, name: call.name))
                            await MainActor.run {
                                stageText = "工具执行失败：\(call.name)"
                                upsertToolCard(call, status: .failed, result: msg)
                            }
                        }
                    }
                    history.append(contentsOf: toolMessages)
                }
            }
            if finalText == nil && !isCancelled {
                // 达到迭代上限仍无文本，给出提示
                await MainActor.run {
                    messages.append(ChatMessage(role: .assistant, content: "工具调用次数过多，已停止。请简化指令或重新提问。"))
                    saveConversation()
                }
            }
        } catch {
            if !isCancelled {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    stageText = "请求失败"
                }
            }
        }

        await MainActor.run {
            isWorking = false
            stageText = nil
        }
    }

    func cancel() {
        isCancelled = true
        Task { @MainActor in
            if isWorking {
                messages.append(ChatMessage(role: .assistant, content: "已停止当前回复。"))
                saveConversation()
            }
            isWorking = false
            stageText = nil
            endBackgroundTask(backgroundTaskID)
        }
    }

    /// 切换工作区根目录
    func setWorkspace(_ url: URL) {
        try? workspace.setWorkspace(url)
        tracker.bind(to: workspace)
    }

    func updateRepoConfig(_ update: (inout GitRepoConfig) -> Void) {
        update(&repoConfig)
        repoConfig.save()
    }

    func resetConversation() {
        messages.removeAll()
        toolCards.removeAll()
        errorMessage = nil
        stageText = nil
        packageScanSummary = nil
        saveConversation()
    }

    func setPackageScanSummary(_ summary: String?) {
        packageScanSummary = summary
    }

    func appendLocalMessage(role: ChatMessage.Role, content: String) {
        messages.append(ChatMessage(role: role, content: content))
        saveConversation()
    }

    // MARK: - Private

    private func buildHistory() -> [ChatMessage] {
        var history: [ChatMessage] = []
        var systemPrompt = """
        你是 AIReverse 内置的编程编码助手。你可以浏览工作区、读取和修改代码文件、查看 git 状态并提交变更。

        使用简体中文回答。当需要修改代码时：
        1. 先用 read_file / list_dir 了解项目结构
        2. 用 write_file 写入修改
        3. 需要保存变更时用 git_commit

        修改文件前，明确告知用户你将修改哪些文件、为什么。
        """
        if workspace.workspaceRoot != nil {
            systemPrompt += "\n\n当前工作区已就绪。使用 list_dir 查看根目录结构。"
        }
        if let packageScanSummary, !packageScanSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt += "\n\n用户最近上传文件的本地静态扫描摘要：\n\(truncate(packageScanSummary, limit: 5000))"
        }
        history.append(ChatMessage(role: .system, content: systemPrompt))
        history.append(contentsOf: messages)
        return history
    }

    private func upsertToolCard(_ call: ToolCall, status: ToolCallStatus, result: String? = nil) {
        if let idx = toolCards.firstIndex(where: { $0.id == call.id }) {
            toolCards[idx].status = status
            if let result { toolCards[idx].resultPreview = truncate(result, limit: 300) }
        } else {
            let argsData = (try? JSONSerialization.data(withJSONObject: call.arguments)) ?? Data()
            let argsText = String(data: argsData, encoding: .utf8) ?? "{}"
            toolCards.append(ToolCallCard(
                id: call.id,
                name: call.name,
                argumentsText: argsText,
                status: status,
                resultPreview: result.map { truncate($0, limit: 300) }
            ))
        }
    }

    private func truncate(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "\n...[已截断]"
    }

    private func restoreConversation() {
        guard let url = conversationURL(),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([StoredChatMessage].self, from: data) else {
            return
        }
        messages = records.map { ChatMessage(role: $0.role, content: $0.content, date: $0.date) }
    }

    private func saveConversation() {
        guard let url = conversationURL() else { return }
        let records = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { StoredChatMessage(role: $0.role, content: $0.content, date: $0.date) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func conversationURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(conversationFileName)
    }

    @MainActor
    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AIReverseChat") { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.stageText = "后台执行超时"
            self.endBackgroundTask(self.backgroundTaskID)
        }
        return backgroundTaskID
    }

    @MainActor
    private func endBackgroundTask(_ taskID: UIBackgroundTaskIdentifier) {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        if backgroundTaskID == taskID {
            backgroundTaskID = .invalid
        }
    }
}

private struct StoredChatMessage: Codable {
    let role: ChatMessage.Role
    let content: String
    let date: Date
}
