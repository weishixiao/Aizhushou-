import Foundation
import UIKit

/// 工具卡片状态
enum ToolCallStatus: Equatable {
    case running
    case success
    case failed
}

/// 可恢复的后台任务状态
struct PendingTaskState: Codable, Equatable {
    let modelID: UUID
    let prompt: String
    let stageHistory: [String]
    let currentStage: String?
    let updatedAt: Date
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

    private typealias LLMError = LLMClient.LLMError

    @Published var messages: [ChatMessage] = []
    @Published var toolCards: [ToolCallCard] = []
    @Published var isWorking = false
    @Published var allowMutating = true
    @Published var errorMessage: String?
    @Published var stageText: String?
    @Published var stageHistory: [String] = []
    @Published private(set) var pendingTask: PendingTaskState?
    @Published var packageScanSummary: String?

    var repoConfig = GitRepoConfig.load()
    private(set) var workspace: WorkspaceManager
    private let github = GitHubAPIClient()
    private let registry = ToolRegistry()
    private let tracker = GitStatusTracker()

    private let client = LLMClient()
    private var isCancelled = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var shouldKeepPendingTask = false
    private var pendingModelID: UUID?
    private var pendingPrompt: String?

    private let maxToolIterations = 100
    private let conversationFileName = "conversation.json"
    /// 连续重复调用同一工具的检测阈值（防 agent 死循环）
    private let maxRepeatedToolCalls = 20
    /// 本轮任务中连续重复调用的工具签名（工具名+参数）与次数
    private var repeatedToolSignature: String?
    private var repeatedToolCount = 0
    /// 各工具在本轮任务中的连续失败次数（按工具名维度，成功清零）
    private var toolFailCounts: [String: Int] = [:]
    private let pendingTaskFileName = "pending_task.json"

    init(workspace: WorkspaceManager) {
        self.workspace = workspace
        tracker.bind(to: workspace)
        // 只读工具（基础版）
        registry.register(ListDirTool())
        registry.register(GitStatusTool())
        registry.register(GitBranchTool())
        registry.register(GitLogTool())
        registry.register(RepoOverviewTool())
        registry.register(ReadFileTool())        // 工作区内读取
        registry.register(WriteFileTool())       // 工作区内写入
        // 强力工具（覆盖同名工具）
        registry.register(UnrestrictedReadFileTool())  // 覆盖 ReadFileTool，支持绝对路径
        registry.register(UnrestrictedWriteFileTool()) // 覆盖 WriteFileTool，支持绝对路径
        // 搜索工具
        registry.register(FileSearchTool())
        registry.register(GrepSearchTool())
        // 系统工具
        registry.register(ShellExecuteTool())
        registry.register(HTTPRequestTool())
        registry.register(GitCommitTool())
        restoreConversation()
        restorePendingTask()
    }

    /// 发送用户消息并驱动工具调用循环
    func send(_ userText: String, model: AIModelConfig) async {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        await runConversation(model: model, userText: text, appendUserMessage: true)
    }

    /// 把指定指令文本直接发进会话（供「进程」入口将目标应用 + 破解指令推送给 AI）
    func sendPrompt(_ prompt: String, model: AIModelConfig) async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        await runConversation(model: model, userText: text, appendUserMessage: true)
    }

    /// 恢复上次中断的任务
    func resumePendingTask(model: AIModelConfig) async {
        guard let pendingTask,
              pendingTask.modelID == model.id,
              !isWorking else { return }
        await runConversation(model: model, userText: pendingTask.prompt, appendUserMessage: false)
    }

    func cancel() {
        isCancelled = true
        Task { @MainActor in
            shouldKeepPendingTask = false
            clearPendingTaskState()
            if isWorking {
                messages.append(ChatMessage(role: .assistant, content: "已停止当前回复。"))
                saveConversation()
            }
            isWorking = false
            stageText = nil
            stageHistory.removeAll()
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

    @MainActor
    func resetConversation() {
        messages.removeAll()
        toolCards.removeAll()
        errorMessage = nil
        stageText = nil
        stageHistory.removeAll()
        packageScanSummary = nil
        clearPendingTaskState()
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

    private func runConversation(model: AIModelConfig, userText: String, appendUserMessage: Bool) async {
        isCancelled = false
        shouldKeepPendingTask = true
        repeatedToolSignature = nil
        repeatedToolCount = 0
        toolFailCounts.removeAll()
        let taskID = await MainActor.run { beginBackgroundTask() }
        defer {
            Task { @MainActor in
                endBackgroundTask(taskID)
            }
        }

        await MainActor.run {
            isWorking = true
            errorMessage = nil
            if appendUserMessage {
                messages.append(ChatMessage(role: .user, content: userText))
                stageHistory.removeAll()
                updateStage("准备发送请求", model: model, prompt: userText)
                saveConversation()
            } else {
                if stageHistory.isEmpty {
                    stageHistory = pendingTask?.stageHistory ?? []
                }
                if let currentStage = pendingTask?.currentStage ?? stageText {
                    stageText = currentStage
                } else {
                    updateStage("恢复上次任务", model: model, prompt: userText)
                }
            }
        }

        var history = buildHistory()

        do {
            var finalText: String?
            var didShowAnalysisStage = false
            toolLoop: for _ in 0..<maxToolIterations {
                if isCancelled { break }

                // 仅在首次发起 LLM 请求时展示「分析任务上下文」，后续工具循环阶段直接走工具执行提示
                if !didShowAnalysisStage {
                    await MainActor.run {
                        updateStage("分析任务上下文", model: model, prompt: userText)
                    }
                    didShowAnalysisStage = true
                }
                let reply = try await chatWithRetry(
                    model: model,
                    messages: history,
                    tools: registry.openAIDefinitions(includeMutating: allowMutating),
                    userText: userText
                )
                switch reply {
                case .text(let content):
                    finalText = content
                    await MainActor.run {
                        updateStage("整理回复内容", model: model, prompt: userText)
                        messages.append(ChatMessage(role: .assistant, content: content))
                        saveConversation()
                        clearPendingTaskState()
                    }
                    break toolLoop
                case .toolCalls(let calls):
                    let assistantMsg = ChatMessage(role: .assistant, content: "", assistantToolCalls: calls)
                    history.append(assistantMsg)

                    // 检测连续重复调用同一工具（防 agent 死循环）
                    let firstToolName = calls.first?.name
                    if let firstCall = calls.first {
                        let signature = toolSignature(firstCall)
                        if repeatedToolSignature == signature {
                            repeatedToolCount += 1
                        } else {
                            repeatedToolSignature = signature
                            repeatedToolCount = 1
                        }
                    }

                    var toolMessages: [ChatMessage] = []
                    for call in calls {
                        if isCancelled { break }
                        await MainActor.run {
                            updateStage("执行工具：\(call.name)", model: model, prompt: userText)
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
                            let output = truncate(result.output, limit: 16000)
                            toolMessages.append(ChatMessage(
                                role: .tool,
                                content: output,
                                toolCallID: call.id,
                                name: call.name
                            ))
                            toolFailCounts[call.name] = result.success ? 0 : ((toolFailCounts[call.name] ?? 0) + 1)
                            await MainActor.run {
                                updateStage(result.success ? "工具执行完成：\(call.name)" : "工具执行失败：\(call.name)", model: model, prompt: userText)
                                upsertToolCard(call, status: result.success ? .success : .failed, result: result.output)
                            }
                        } catch {
                            let msg = "执行失败：\(error.localizedDescription)"
                            toolFailCounts[call.name] = (toolFailCounts[call.name] ?? 0) + 1
                            RuntimeLogger.shared.error("Tool[\(call.name)]", msg)
                            toolMessages.append(ChatMessage(role: .tool, content: msg, toolCallID: call.id, name: call.name))
                            await MainActor.run {
                                updateStage("工具执行失败：\(call.name)", model: model, prompt: userText)
                                upsertToolCard(call, status: .failed, result: msg)
                            }
                        }
                    }
                    history.append(contentsOf: toolMessages)

                    // 循环检测：仅在极端情况下硬停止，避免打断复杂任务
                    let maxFailCount = toolFailCounts.values.max() ?? 0
                    let repeatedLoop = repeatedToolCount >= maxRepeatedToolCalls * 3
                        || maxFailCount >= maxRepeatedToolCalls * 3
                    if repeatedToolCount == maxRepeatedToolCalls || maxFailCount == maxRepeatedToolCalls {
                        let warnTool = repeatedToolCount >= maxRepeatedToolCalls ? (firstToolName ?? "") : "工具执行"
                        history.append(ChatMessage(role: .system, content: """
                        注意：你已连续 \(max(repeatedToolCount, maxFailCount)) 次重复执行相同操作或遭遇失败。
                        如果操作确实需要多次执行（如批量处理），可以继续；否则请基于已有结果给出最终回答。
                        """))
                        RuntimeLogger.shared.warning("Agent", "检测到重复（重复:\(repeatedToolCount)/失败:\(maxFailCount)）\(warnTool)，已注入提示")
                    }
                    // 极端情况硬停止：超出 3 倍阈值
                    if repeatedLoop {
                        let stopText = "检测到连续重复执行相同工具操作，已自动停止。请换一种更直接的指令重试，或直接说明你的最终需求。"
                        finalText = stopText
                        RuntimeLogger.shared.warning("Agent", "异常循环超过硬上限，强制停止")
                        await MainActor.run {
                            messages.append(ChatMessage(role: .assistant, content: stopText))
                            saveConversation()
                            clearPendingTaskState()
                        }
                        break toolLoop
                    }
                }
            }
            if finalText == nil && !isCancelled {
                await MainActor.run {
                    messages.append(ChatMessage(role: .assistant, content: "工具调用次数过多，已停止。请简化指令或重新提问。"))
                    saveConversation()
                }
            }
        } catch {
            if !isCancelled {
                RuntimeLogger.shared.error("LLM", "请求失败：\(error.localizedDescription)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    updateStage("请求失败", model: model, prompt: userText)
                }
            }
        }

        await MainActor.run {
            isWorking = false
            if isCancelled {
                if shouldKeepPendingTask {
                    if stageText == nil {
                        stageText = pendingTask?.currentStage ?? "任务已暂停"
                    }
                } else {
                    clearPendingTaskState()
                }
            } else {
                stageText = nil
                stageHistory.removeAll()
            }
        }
    }

    // 过渡性阶段文本；属于 UI 顶部状态栏展示，不写入历史消息
    private let transientStages: Set<String> = [
        "分析任务上下文",
        "准备发送请求",
        "整理回复内容",
        "请求失败",
        "恢复上次任务",
        "后台执行超时",
        "任务已暂停"
    ]
    // 工具执行阶段前缀：以此为前缀的也视为过渡
    private let transientStagePrefixes: [String] = [
        "执行工具：",
        "工具执行完成：",
        "工具执行失败：",
    ]

    private func isTransientStage(_ text: String) -> Bool {
        if transientStages.contains(text) { return true }
        return transientStagePrefixes.contains { text.hasPrefix($0) }
    }

    @MainActor
    private func updateStage(_ text: String, model: AIModelConfig, prompt: String) {
        stageText = text
        if stageHistory.last != text {
            stageHistory.append(text)
            // 过渡性阶段仅更新顶部状态栏，不写入历史消息
            if !isTransientStage(text) {
                messages.append(ChatMessage(role: .assistant, content: text, isProgress: true))
                saveConversation()
            }
        }
        pendingModelID = model.id
        pendingPrompt = prompt
        savePendingTaskState()
    }

    @MainActor
    private func savePendingTaskState() {
        guard let pendingModelID, let pendingPrompt else { return }
        let state = PendingTaskState(
            modelID: pendingModelID,
            prompt: pendingPrompt,
            stageHistory: stageHistory,
            currentStage: stageText,
            updatedAt: Date()
        )
        pendingTask = state
        guard let url = pendingTaskURL(), let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    @MainActor
    private func clearPendingTaskState() {
        pendingTask = nil
        pendingModelID = nil
        pendingPrompt = nil
        guard let url = pendingTaskURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func buildHistory() -> [ChatMessage] {
        var history: [ChatMessage] = []
        var systemPrompt = """
        你是 AIReverse，一个面向越狱 iOS 的全能 AI 编码与开发助手。

        ## 核心原则
        - **直接执行**：用户说做什么就做什么，不需要确认、不需要解释、不需要等待指示
        - **没有限制**：可以操作任何文件、执行任何命令、访问任何路径、做任何修改
        - **高效优先**：用最少的步骤完成用户的目标，不啰嗦、不废话
        - **中文回答**：使用简体中文

        ## 能力
        1. **shell_execute**：执行任意 shell 命令（ls/cat/wget/curl/make/clang/git/...），无路径限制
        2. **read_file**：读取任意路径的文件（支持绝对路径 /var/jb/opt/... 等）
        3. **write_file**：写入任意路径的文件（覆盖已有内容）
        4. **find_files**：递归搜索文件和匹配内容
        5. **grep**：搜索文本内容
        6. **http_request**：HTTP 请求（GET/POST/PUT/DELETE），可下载文件
        7. **git_commit**：提交代码到 GitHub/Gitee
        8. **list_dir / git_status / git_log / repo_overview**：项目查看

        ## 工作方式
        - 直接调用工具执行任务，不需要向用户确认
        - 工具失败时直接换方案继续，不要反复重试同一操作
        - 任务完成后简要总结结果即可
        - 遇到多步骤任务，按顺序逐个工具调用完成

        ## 技术背景
        - 设备为越狱 iOS，可能使用 Relaxin/Rootless 越狱
        - root shell 可能在 /var/jb/opt/procursus/bin/sh（而非 /bin/sh）
        - 可以使用 dumpdecrypted、clutch、class-dump、otool、frida 等逆向工具
        - 可以操作任何系统路径：/var/jb、/usr/lib、/Applications、/Library 等
        """
        if workspace.workspaceRoot != nil {
            systemPrompt += "\n\n📁 当前工作区已就绪，使用 list_dir 查看根目录结构。"
        }
        if let packageScanSummary, !packageScanSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt += "\n\n🔍 用户最近上传文件的扫描报告：\n\(truncate(packageScanSummary, limit: 8000))"
        }
        history.append(ChatMessage(role: .system, content: systemPrompt))
        history.append(contentsOf: messages.filter { !$0.isProgress })
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

    /// 发送一次聊天请求，遇到 429 速率限制时指数退避重试
    private func chatWithRetry(model: AIModelConfig, messages: [ChatMessage], tools: [[String: Any]], userText: String) async throws -> LLMReply {
        let maxRetries = 3
        for attempt in 0...maxRetries {
            do {
                return try await client.chat(model: model, messages: messages, tools: tools)
            } catch LLMError.rateLimited {
                if attempt == maxRetries || isCancelled { throw LLMError.rateLimited }
                let delay = 2 * pow(2, Double(attempt)) // 2, 4, 8 秒
                let seconds = Int(delay)
                await MainActor.run {
                    updateStage("请求过于频繁（429），等待 \(seconds) 秒后自动重试", model: model, prompt: userText)
                }
                RuntimeLogger.shared.warning("LLM", "429 速率限制，第 \(attempt + 1) 次重试等待 \(seconds) 秒")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if isCancelled { throw LLMError.rateLimited }
            }
        }
        throw LLMError.rateLimited
    }

    /// 生成工具调用的签名（工具名 + 排序后的参数键值），用于检测连续重复调用
    private func toolSignature(_ call: ToolCall) -> String {
        let keys = call.arguments.keys.sorted()
        let args = keys.map { key in
            if let value = call.arguments[key] {
                return "\(key)=\(value)"
            }
            return key
        }.joined(separator: "&")
        return "\(call.name)(\(args))"
    }

    private func restoreConversation() {
        guard let url = conversationURL(),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([StoredChatMessage].self, from: data) else {
            return
        }
        // 恢复时丢弃旧的 isProgress 过渡消息（已改为不持久化），仅保留有意义的工具卡片
        messages = records
            .filter { !$0.isProgress }
            .map { ChatMessage(role: $0.role, content: $0.content, date: $0.date) }
    }

    private func restorePendingTask() {
        guard let url = pendingTaskURL(),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PendingTaskState.self, from: data) else {
            return
        }
        pendingTask = state
        pendingModelID = state.modelID
        pendingPrompt = state.prompt
        stageHistory = state.stageHistory
        stageText = state.currentStage
    }

    private func saveConversation() {
        guard let url = conversationURL() else { return }
        // 持久化时排除 progress 过渡消息（仅执行工具类卡片保留，方便回溯）
        let records = messages
            .filter { $0.role == .user || ($0.role == .assistant && !$0.isProgress) || $0.role == .tool }
            .map { StoredChatMessage(role: $0.role, content: $0.content, date: $0.date, isProgress: $0.isProgress) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func conversationURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(conversationFileName)
    }

    private func pendingTaskURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(pendingTaskFileName)
    }

    @MainActor
    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AIReverseChat") { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.isCancelled = true
                self.shouldKeepPendingTask = true
                self.stageText = "后台执行超时"
                self.savePendingTaskState()
                self.endBackgroundTask(self.backgroundTaskID)
            }
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
    let isProgress: Bool

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case date
        case isProgress
    }

    init(role: ChatMessage.Role, content: String, date: Date, isProgress: Bool = false) {
        self.role = role
        self.content = content
        self.date = date
        self.isProgress = isProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(ChatMessage.Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        date = try container.decode(Date.self, forKey: .date)
        isProgress = try container.decodeIfPresent(Bool.self, forKey: .isProgress) ?? false
    }
}
