import Foundation

/// 最小可用的 MCP（Model Context Protocol）远程工具客户端。
/// 仅支持 Streamable HTTP / SSE 两种 HTTP 传输 —— iOS 无法运行本地 stdio 进程。
/// 握手流程：initialize → notifications/initialized → tools/list → tools/call
final class MCPClient {

    struct MCPToolDef {
        let name: String
        let description: String
        let schema: [String: Any]
    }

    private let server: MCPServerConfig
    private let session: URLSession
    private var nextRequestID = 1
    /// Streamable HTTP 会话 ID（initialize 响应头返回）
    private var sessionID: String?

    init(server: MCPServerConfig) {
        self.server = server
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    var isSupported: Bool {
        server.transport == .streamableHTTP || server.transport == .sse
    }

    // MARK: - 会话

    /// initialize 握手 + notifications/initialized 通知
    func initialize() async throws {
        _ = try await sendRPC("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "AIReverse", "version": "1.2.1"]
        ])
        // 通知无响应体，失败不致命（部分老服务端直接 4xx）
        _ = try? await sendRPC("notifications/initialized", params: nil, notification: true)
    }

    /// 拉取服务端工具清单
    func listTools() async throws -> [MCPToolDef] {
        let result = try await sendRPC("tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return MCPToolDef(
                name: name,
                description: item["description"] as? String ?? "MCP 远程工具 \(name)",
                schema: item["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            )
        }
    }

    /// 调用远程工具，返回拼接后的文本内容
    func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        let result = try await sendRPC("tools/call", params: ["name": name, "arguments": arguments])
        if let isError = result["isError"] as? Bool, isError {
            let text = textContent(of: result)
            return "[MCP 工具返回错误]\(text.isEmpty ? "" : " " + text)"
        }
        let text = textContent(of: result)
        if !text.isEmpty { return text }
        // 无 content 字段时回退为结果摘要
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return String(s.prefix(4000))
        }
        return String(describing: result).prefix(4000).description
    }

    private func textContent(of result: [String: Any]) -> String {
        guard let content = result["content"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { parts.append(t) }
            case "image":
                parts.append("[图片内容]")
            case "resource":
                parts.append("[资源内容]")
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - JSON-RPC 传输

    /// 发送一条 JSON-RPC 请求；响应兼容纯 JSON 与 SSE 帧两种形态
    private func sendRPC(_ method: String, params: [String: Any]? = nil, notification: Bool = false) async throws -> [String: Any] {
        guard let url = URL(string: server.url) else { throw MCPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in server.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !notification {
            body["id"] = nextRequestID
            nextRequestID += 1
        }
        if let params { body["params"] = params }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MCPError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = sid
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw MCPError.httpStatus(http.statusCode, msg)
        }
        if notification { return [:] }

        // 形态一：普通 JSON
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try unwrap(json)
        }
        // 形态二：SSE 帧（data: {...} 行）
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: "\n").reversed() {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                return try unwrap(json)
            }
        }
        throw MCPError.badResponse
    }

    private func unwrap(_ json: [String: Any]) throws -> [String: Any] {
        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "MCP error"
            throw MCPError.rpcError(msg)
        }
        guard let result = json["result"] as? [String: Any] else { throw MCPError.badResponse }
        return result
    }
}

// MARK: - 错误

enum MCPError: LocalizedError {
    case invalidURL
    case badResponse
    case network(Error)
    case httpStatus(Int, String)
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "MCP Server URL 无效"
        case .badResponse:
            return "MCP 响应格式异常"
        case .network(let e):
            return "MCP 网络错误: \(e.localizedDescription)"
        case .httpStatus(let code, let msg):
            return "MCP 服务器返回 \(code): \(msg)"
        case .rpcError(let msg):
            return "MCP 错误: \(msg)"
        }
    }
}

// MARK: - 代理工具

/// 把 MCP 远程工具包装为本地的 CodingTool，注册进 ToolRegistry。
/// 命名规则 mcp_<server>_<tool>（清洗为 OpenAI function name 兼容字符，截断 64 字符）。
final class MCPProxyTool: CodingTool {
    private let serverConfig: MCPServerConfig
    private let remoteName: String
    private let toolName: String
    private let toolDescription: String
    private let toolParameters: [String: Any]

    var name: String { toolName }
    var description: String { toolDescription }
    var isMutating: Bool { true }
    var parameters: [String: Any] { toolParameters }

    init(server: MCPServerConfig, def: MCPClient.MCPToolDef) {
        self.serverConfig = server
        self.remoteName = def.name
        func sanitize(_ raw: String) -> String {
            let cleaned = raw.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            return String(cleaned.prefix(24))
        }
        self.toolName = String("mcp_\(sanitize(server.name))_\(sanitize(def.name))".prefix(64))
        self.toolDescription = "[MCP:\(server.name)] \(def.description)"
        self.toolParameters = def.schema
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        // 每次调用独立握手（无状态模式，兼容大多数远程 MCP 服务）
        let client = MCPClient(server: serverConfig)
        do {
            try await client.initialize()
            let output = try await client.callTool(remoteName, arguments: arguments)
            return ToolResult(success: true, output: output)
        } catch {
            return ToolResult(success: false, output: "MCP 调用失败：\(error.localizedDescription)")
        }
    }
}
