import Foundation

/// 模型回复的解析结果
enum LLMReply {
    /// 纯文本回复
    case text(String)
    /// 需要执行工具调用（完成后需把结果回传再请求）
    case toolCalls([ToolCall])
}

struct LLMModelInfo: Identifiable, Equatable {
    let id: String
    let name: String?
    let ownedBy: String?
    let status: String?

    var displayName: String {
        if let name, !name.isEmpty, name != id { return "\(name) · \(id)" }
        return id
    }
}

/// 支持 OpenAI 兼容与 Anthropic Claude 两种协议的 LLM 聊天客户端。
/// - OpenAI 兼容：任何符合 /v1/chat/completions 接口的服务（DeepSeek、OpenAI、Kimi、本地 Ollama 等）
/// - Anthropic：Claude 官方 /v1/messages 接口
final class LLMClient {

    enum LLMError: Error, LocalizedError {
        case emptyConfig
        case invalidURL
        case network(Error)
        case badStatus(Int, String)
        case rateLimited
        case serverOverloaded
        case emptyResponse
        case streamingUnsupported

        var errorDescription: String? {
            switch self {
            case .emptyConfig:
                return "模型配置不完整，请在设置中添加模型"
            case .invalidURL:
                return "Base URL 无效"
            case .network(let e):
                return "网络错误: \(e.localizedDescription)"
            case .badStatus(let code, let msg):
                return "服务器返回 \(code): \(msg)"
            case .rateLimited:
                return "请求过于频繁，已触发速率限制（429），请稍等片刻后重试"
            case .serverOverloaded:
                return "服务端过载（overloaded），正在自动重试，请稍候…"
            case .emptyResponse:
                return "模型未返回内容"
            case .streamingUnsupported:
                return "当前服务不支持流式输出"
            }
        }
    }

    private let session: URLSession
    /// 历史消息总 token 估算上限（字符数折算：1 token ≈ 4 ASCII 字符或 1.5 CJK 字符）
    private let maxContextCharacters = 200_000
    /// 单条工具结果最大字符
    private let maxToolResultChars = 32_000
    /// 重试配置
    private let maxRetryCount = 3
    private let baseRetryDelay: UInt64 = 2_000_000_000   // 2 秒

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// 发送一次聊天请求（支持 tools），按 API 类型路由到对应协议
    func chat(model: AIModelConfig, messages: [ChatMessage], tools: [[String: Any]]? = nil) async throws -> LLMReply {
        guard model.isFilled else { throw LLMError.emptyConfig }
        let trimmed = truncateHistory(messages)
        switch model.apiType {
        case .openAI:
            return try await openAIChat(model: model, messages: trimmed, tools: tools)
        case .anthropic:
            return try await anthropicChat(model: model, messages: trimmed, tools: tools)
        }
    }

    // MARK: - OpenAI 兼容协议

    private func openAIChat(model: AIModelConfig, messages: [ChatMessage], tools: [[String: Any]]? = nil) async throws -> LLMReply {
        let endpoint = try endpointURL(model, apiType: .openAI)
        var body: [String: Any] = [
            "model": model.modelID,
            "stream": false,
            "messages": messages.map { openAIMessageDict($0) }
        ]
        if model.maxTokens > 0 {
            body["max_tokens"] = model.maxTokens
        }
        if let tools, !tools.isEmpty {
            body["tools"] = tools
        }

        let data = try await postWithRetry(endpoint: endpoint, body: body, model: model)

        // 解析响应
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMError.emptyResponse
        }

        // 工具调用优先
        if let toolCallsJSON = message["tool_calls"] as? [[String: Any]] {
            var calls: [ToolCall] = []
            for call in toolCallsJSON {
                guard let id = call["id"] as? String,
                      let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                let args: [String: Any]
                if let argsStr = fn["arguments"] as? String,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any] {
                    args = parsed
                } else {
                    args = [:]
                }
                calls.append(ToolCall(id: id, name: name, arguments: args))
            }
            if !calls.isEmpty {
                return .toolCalls(calls)
            }
        }

        // 纯文本
        guard let content = message["content"] as? String, !content.isEmpty else {
            // 允许 content 为 null 但无 tool_calls 的情况兜底
            throw LLMError.emptyResponse
        }
        return .text(content)
    }

    // MARK: - Anthropic Claude 协议

    /// 发送一次 Claude Messages API 请求
    private func anthropicChat(model: AIModelConfig, messages: [ChatMessage], tools: [[String: Any]]? = nil) async throws -> LLMReply {
        let endpoint = try endpointURL(model, apiType: .anthropic)
        let body = try anthropicRequestBody(model: model, messages: messages, tools: tools)

        let data = try await postWithRetry(endpoint: endpoint, body: body, model: model)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.emptyResponse
        }
        // 检查 Anthropic 错误体
        if let error = json["error"] as? [String: Any],
           let type = error["type"] as? String {
            if type == "overloaded_error" {
                throw LLMError.serverOverloaded
            }
            let msg = error["message"] as? String ?? type
            throw LLMError.badStatus(500, msg)
        }

        guard let contentBlocks = json["content"] as? [[String: Any]] else {
            throw LLMError.emptyResponse
        }

        var calls: [ToolCall] = []
        var textParts: [String] = []
        for block in contentBlocks {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String {
                    textParts.append(t)
                }
            case "tool_use":
                if let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    let input = (block["input"] as? [String: Any]) ?? [:]
                    calls.append(ToolCall(id: id, name: name, arguments: input))
                }
            default:
                break
            }
        }

        if !calls.isEmpty {
            return .toolCalls(calls)
        }
        let text = textParts.joined(separator: "\n")
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return .text(text)
    }

    /// 构造 Claude Messages API 请求体
    private func anthropicRequestBody(model: AIModelConfig, messages: [ChatMessage], tools: [[String: Any]]? = nil) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model.modelID,
            "max_tokens": model.maxTokens > 0 ? model.maxTokens : 4096
        ]

        // Anthropic 支持结构化 system blocks（可加 cache_control 提升缓存命中率）
        let systemTexts = messages
            .filter { $0.role == .system }
            .map { $0.content }
            .filter { !$0.isEmpty }
        if !systemTexts.isEmpty {
            let joined = systemTexts.joined(separator: "\n\n")
            body["system"] = [
                ["type": "text", "text": joined, "cache_control": ["type": "ephemeral"]]
            ]
        }

        // 转换 messages：Anthropic 无 system role，tool 消息合并到 user
        body["messages"] = anthropicMessages(messages)

        // 转换工具定义
        if let tools, !tools.isEmpty {
            let converted: [[String: Any]] = tools.compactMap { tool in
                guard let fn = tool["function"] as? [String: Any],
                      let name = fn["name"] as? String else { return nil }
                return [
                    "name": name,
                    "description": fn["description"] as? String ?? "",
                    "input_schema": fn["parameters"] as? [String: Any] ?? [:]
                ]
            }
            if !converted.isEmpty {
                // 最后一个 tool 加 cache_control（工具定义一般不变）
                var finalTools = converted
                let lastIdx = finalTools.count - 1
                finalTools[lastIdx]["cache_control"] = ["type": "ephemeral"]
                body["tools"] = finalTools
            }
        }
        return body
    }

    /// 将内部消息转换为 Claude 格式（tool 结果并入 user 消息）
    private func anthropicMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        func appendUserText(_ content: String) {
            guard !content.isEmpty else { return }
            if var last = result.last, last["role"] as? String == "user",
               let arr = last["content"] as? [[String: Any]] {
                var merged = arr
                merged.append(["type": "text", "text": content])
                last["content"] = merged
                result[result.count - 1] = last
            } else {
                result.append(["role": "user", "content": [["type": "text", "text": content]]])
            }
        }

        for msg in messages {
            switch msg.role {
            case .system:
                continue
            case .user:
                appendUserText(msg.content)
            case .assistant:
                var blocks: [[String: Any]] = []
                if !msg.content.isEmpty {
                    blocks.append(["type": "text", "text": msg.content])
                }
                if let calls = msg.assistantToolCalls, !calls.isEmpty {
                    for call in calls {
                        let argsData = (try? JSONSerialization.data(withJSONObject: call.arguments)) ?? Data()
                        let input = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]
                        blocks.append([
                            "type": "tool_use",
                            "id": call.id,
                            "name": call.name,
                            "input": input
                        ])
                    }
                }
                if !blocks.isEmpty {
                    result.append(["role": "assistant", "content": blocks])
                }
            case .tool:
                let toolResult: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": msg.toolCallID ?? "",
                    "content": msg.content
                ]
                if var last = result.last, last["role"] as? String == "user",
                   var arr = last["content"] as? [[String: Any]] {
                    arr.append(toolResult)
                    last["content"] = arr
                    result[result.count - 1] = last
                } else {
                    result.append(["role": "user", "content": [toolResult]])
                }
            }
        }
        return result
    }

    func listModels(baseURL: String, apiKey: String, apiType: ModelAPIType = .openAI) async throws -> [LLMModelInfo] {
        switch apiType {
        case .openAI:
            return try await listOpenAIModels(baseURL: baseURL, apiKey: apiKey)
        case .anthropic:
            return try await listAnthropicModels(baseURL: baseURL, apiKey: apiKey)
        }
    }

    private func listOpenAIModels(baseURL: String, apiKey: String) async throws -> [LLMModelInfo] {
        let endpoint = try modelsURL(baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw LLMError.rateLimited
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.badStatus(http.statusCode, String(msg.prefix(500)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw LLMError.emptyResponse
        }

        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return LLMModelInfo(
                id: id,
                name: item["name"] as? String,
                ownedBy: item["owned_by"] as? String,
                status: item["status"] as? String
            )
        }
    }

    private func listAnthropicModels(baseURL: String, apiKey: String) async throws -> [LLMModelInfo] {
        let endpoint = try modelsURL(baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw LLMError.rateLimited
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.badStatus(http.statusCode, String(msg.prefix(500)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw LLMError.emptyResponse
        }

        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return LLMModelInfo(
                id: id,
                name: item["display_name"] as? String,
                ownedBy: "anthropic",
                status: item["status"] as? String
            )
        }
    }

    /// 发送带工具结果的下一轮请求
    func chat(model: AIModelConfig, messages: [ChatMessage]) async throws -> String {
        guard model.isFilled else { throw LLMError.emptyConfig }
        let trimmed = truncateHistory(messages)
        switch model.apiType {
        case .openAI:
            return try await openAISimpleChat(model: model, messages: trimmed)
        case .anthropic:
            return try await anthropicSimpleChat(model: model, messages: trimmed)
        }
    }

    private func openAISimpleChat(model: AIModelConfig, messages: [ChatMessage]) async throws -> String {
        let endpoint = try endpointURL(model, apiType: .openAI)
        var body: [String: Any] = [
            "model": model.modelID,
            "stream": false,
            "messages": messages.map { openAIMessageDict($0) }
        ]
        if model.maxTokens > 0 {
            body["max_tokens"] = model.maxTokens
        }
        let data = try await postWithRetry(endpoint: endpoint, body: body, model: model)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.emptyResponse
        }
        return content
    }

    private func anthropicSimpleChat(model: AIModelConfig, messages: [ChatMessage]) async throws -> String {
        let endpoint = try endpointURL(model, apiType: .anthropic)
        let body = try anthropicRequestBody(model: model, messages: messages)
        let data = try await postWithRetry(endpoint: endpoint, body: body, model: model)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.emptyResponse
        }
        if let error = json["error"] as? [String: Any],
           let type = error["type"] as? String {
            if type == "overloaded_error" { throw LLMError.serverOverloaded }
            throw LLMError.badStatus(500, error["message"] as? String ?? type)
        }
        guard let contentBlocks = json["content"] as? [[String: Any]] else {
            throw LLMError.emptyResponse
        }
        let texts = contentBlocks.compactMap { $0["text"] as? String }
        let text = texts.joined(separator: "\n")
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    private func endpointURL(_ model: AIModelConfig, apiType: ModelAPIType) throws -> URL {
        var baseURL = model.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.hasSuffix("/") { baseURL.removeLast() }
        let endpoint: String
        switch apiType {
        case .openAI:
            if baseURL.hasSuffix("/v1") {
                endpoint = baseURL + "/chat/completions"
            } else if baseURL.hasSuffix("/v1beta") || baseURL.hasSuffix("/openai") {
                endpoint = baseURL + "/chat/completions"
            } else if baseURL.contains("/chat/completions") {
                endpoint = baseURL
            } else {
                endpoint = baseURL + "/v1/chat/completions"
            }
        case .anthropic:
            if baseURL.hasSuffix("/v1") {
                endpoint = baseURL + "/messages"
            } else if baseURL.contains("/messages") {
                endpoint = baseURL
            } else {
                endpoint = baseURL + "/v1/messages"
            }
        }
        guard let url = URL(string: endpoint) else { throw LLMError.invalidURL }
        return url
    }

    private func modelsURL(_ rawBaseURL: String) throws -> URL {
        var baseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.hasSuffix("/") { baseURL.removeLast() }
        if baseURL.hasSuffix("/chat/completions") {
            baseURL = String(baseURL.dropLast("/chat/completions".count))
        } else if baseURL.hasSuffix("/messages") {
            baseURL = String(baseURL.dropLast("/messages".count))
        }
        let endpoint: String
        if baseURL.hasSuffix("/v1") || baseURL.hasSuffix("/v1beta") || baseURL.hasSuffix("/openai") {
            endpoint = baseURL + "/models"
        } else {
            endpoint = baseURL + "/v1/models"
        }
        guard let url = URL(string: endpoint) else { throw LLMError.invalidURL }
        return url
    }

    private func post(endpoint: URL, body: [String: Any], model: AIModelConfig) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch model.apiType {
        case .openAI:
            if !model.apiKey.isEmpty {
                request.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            if !model.apiKey.isEmpty {
                request.setValue(model.apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw LLMError.rateLimited
            }
            if http.statusCode == 529 {
                throw LLMError.serverOverloaded
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.badStatus(http.statusCode, String(msg.prefix(500)))
        }
        return data
    }

    /// 带智能退避重试的 POST：429/529/503 自动重试
    private func postWithRetry(endpoint: URL, body: [String: Any], model: AIModelConfig) async throws -> Data {
        var lastError: Error = LLMError.emptyResponse
        for attempt in 0..<maxRetryCount {
            do {
                return try await post(endpoint: endpoint, body: body, model: model)
            } catch let error as LLMError {
                lastError = error
                switch error {
                case .rateLimited, .serverOverloaded:
                    let delay = baseRetryDelay * UInt64(1 << attempt)
                    let delayMs = delay / 1_000_000
                    RuntimeLogger.shared.warning("LLM", "遇到可重试错误 (\(error))，第 \(attempt + 1) 次等待 \(delayMs)ms 后重试")
                    try? await Task.sleep(nanoseconds: delay)
                case .badStatus(let code, _) where code >= 500:
                    let delay = baseRetryDelay * UInt64(1 << attempt)
                    try? await Task.sleep(nanoseconds: delay)
                default:
                    throw error
                }
            } catch {
                lastError = error
                if attempt < maxRetryCount - 1 {
                    let delay = baseRetryDelay * UInt64(1 << attempt)
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError
    }

    /// 截断历史消息至上下文窗口限制内
    /// 策略：保留 system 消息 + 最近消息，超长 tool 结果截断
    private func truncateHistory(_ messages: [ChatMessage]) -> [ChatMessage] {
        // 1. 先截单条过长的 tool 内容
        var processed = messages.map { msg -> ChatMessage in
            guard msg.role == .tool && msg.content.count > maxToolResultChars else { return msg }
            var trimmed = msg
            trimmed.content = String(msg.content.prefix(maxToolResultChars))
                + "\n…[截断，原始 \(msg.content.count) 字符]"
            return trimmed
        }

        // 2. 估算总字符，若超限则裁剪中段（保留 system + 头部少量 + 尾部大量）
        let totalChars = processed.reduce(0) { $0 + $1.content.count }
        if totalChars <= maxContextCharacters { return processed }

        // system 消息必须保留
        let systemMsgs = processed.filter { $0.role == .system }
        var nonSystem = processed.filter { $0.role != .system }

        // 从旧消息开始丢弃，保留最近 N 条可用窗口
        // 可用字符 = 上限 - system 占用
        let systemChars = systemMsgs.reduce(0) { $0 + $1.content.count }
        var budget = maxContextCharacters - systemChars

        // 从末尾往前累加，直到超过 budget
        var keepFromEnd: [ChatMessage] = []
        for msg in nonSystem.reversed() {
            let c = msg.content.count
            if budget - c < 0, !keepFromEnd.isEmpty { break }
            keepFromEnd.insert(msg, at: 0)
            budget -= c
        }

        // 拼接：system + 保留的非 system
        return systemMsgs + keepFromEnd
    }

    private func openAIMessageDict(_ message: ChatMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "role": roleName(message.role),
            "content": message.content
        ]
        if message.role == .tool, let id = message.toolCallID {
            dict["tool_call_id"] = id
            if let name = message.name {
                dict["name"] = name
            }
        }
        if message.role == .assistant, let calls = message.assistantToolCalls, !calls.isEmpty {
            dict["tool_calls"] = calls.map { call in
                let argsData = (try? JSONSerialization.data(withJSONObject: call.arguments)) ?? Data()
                return [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": String(data: argsData, encoding: .utf8) ?? "{}"
                    ]
                ]
            }
        }
        return dict
    }

    private func roleName(_ role: ChatMessage.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        case .tool: return "tool"
        }
    }
}
