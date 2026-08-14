import Foundation

/// 模型回复的解析结果
enum LLMReply {
    /// 纯文本回复
    case text(String)
    /// 需要执行工具调用（完成后需把结果回传再请求）
    case toolCalls([ToolCall])
}

/// OpenAI 兼容的 LLM 聊天客户端。
/// 支持任何符合 /v1/chat/completions 接口的服务（DeepSeek、OpenAI、Kimi、本地 Ollama 等），
/// 通过 AIModelConfig 自定义 Base URL / API Key / 模型名。
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

    /// 发送一次聊天请求（支持 tools），返回解析结果
    func chat(model: AIModelConfig, messages: [ChatMessage], tools: [[String: Any]]? = nil) async throws -> LLMReply {
        guard model.isFilled else { throw LLMError.emptyConfig }

        let endpoint = try endpointURL(model)
        var body: [String: Any] = [
            "model": model.modelID,
            "stream": false,
            "messages": messages.map { messageDict($0) }
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

    /// 发送带工具结果的下一轮请求
    func chat(model: AIModelConfig, messages: [ChatMessage]) async throws -> String {
        guard model.isFilled else { throw LLMError.emptyConfig }
        let endpoint = try endpointURL(model)
        var body: [String: Any] = [
            "model": model.modelID,
            "stream": false,
            "messages": messages.map { messageDict($0) }
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

    private func endpointURL(_ model: AIModelConfig) throws -> URL {
        var baseURL = model.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.hasSuffix("/") { baseURL.removeLast() }
        let endpoint: String
        if baseURL.hasSuffix("/v1") {
            endpoint = baseURL + "/chat/completions"
        } else if baseURL.contains("/chat/completions") {
            endpoint = baseURL
        } else {
            endpoint = baseURL + "/v1/chat/completions"
        }
        guard let url = URL(string: endpoint) else { throw LLMError.invalidURL }
        return url
    }

    private func post(endpoint: URL, body: [String: Any], model: AIModelConfig) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !model.apiKey.isEmpty {
            request.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization")
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

    private func messageDict(_ message: ChatMessage) -> [String: Any] {
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
