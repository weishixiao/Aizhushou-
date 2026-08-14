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
            case .emptyResponse:
                return "模型未返回内容"
            case .streamingUnsupported:
                return "当前服务不支持流式输出"
            }
        }
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    /// 发送一次聊天请求（支持 tools），按 API 类型路由到对应协议
    func chat(model: AIModelConfig, messages: [ChatMessage], tools: [[String: Any]]? = nil) async throws -> LLMReply {
        guard model.isFilled else { throw LLMError.emptyConfig }
        switch model.apiType {
        case .openAI:
            return try await openAIChat(model: model, messages: messages, tools: tools)
        case .anthropic:
            return try await anthropicChat(model: model, messages: messages, tools: tools)
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

        let data = try await post(endpoint: endpoint, body: body, model: model)

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

        let data = try await post(endpoint: endpoint, body: body, model: model)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]] else {
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

        // 收集 system 提示
        let systemTexts = messages
            .filter { $0.role == .system }
            .map { $0.content }
            .filter { !$0.isEmpty }
        if !systemTexts.isEmpty {
            body["system"] = systemTexts.joined(separator: "\n\n")
        }

        // 转换 messages：Anthropic 无 system role，tool 消息合并到 user
        body["messages"] = anthropicMessages(messages)

        // 转换工具定义：OpenAI {type,function:{name,description,parameters}} -> {name, description, input_schema}
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
                body["tools"] = converted
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
        switch model.apiType {
        case .openAI:
            return try await openAISimpleChat(model: model, messages: messages)
        case .anthropic:
            return try await anthropicSimpleChat(model: model, messages: messages)
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
        let data = try await post(endpoint: endpoint, body: body, model: model)
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
        let data = try await post(endpoint: endpoint, body: body, model: model)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]] else {
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
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.badStatus(http.statusCode, String(msg.prefix(500)))
        }
        return data
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
