import Foundation

/// 工具执行结果
struct ToolResult {
    let success: Bool
    let output: String
}

/// 编码助手工具协议
protocol CodingTool {
    var name: String { get }
    var description: String { get }
    /// JSON Schema 形式的参数定义
    var parameters: [String: Any] { get }
    /// 是否为修改类工具（受「允许修改」开关约束）
    var isMutating: Bool { get }
    /// 执行工具
    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult
}

/// 仓库配置：远程地址 + Token + 当前分支 + 平台
struct GitRepoConfig: Codable, Equatable {
    var repo: String = ""
    var token: String = ""
    var branch: String = "main"
    var platform: GitPlatform = .github

    var hasRemote: Bool {
        !repo.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static let storageKey = "git_repo_config"

    static func load() -> GitRepoConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(GitRepoConfig.self, from: data) else {
            return GitRepoConfig()
        }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// 工具注册表：分发工具调用
final class ToolRegistry {

    private var tools: [String: CodingTool] = [:]

    func register(_ tool: CodingTool) {
        tools[tool.name] = tool
    }

    func tool(named name: String) -> CodingTool? {
        tools[name]
    }

    func allTools() -> [CodingTool] {
        tools.values.sorted { $0.name < $1.name }
    }

    /// 输出 OpenAI 兼容的工具定义列表
    func openAIDefinitions(includeMutating: Bool) -> [[String: Any]] {
        allTools()
            .filter { includeMutating || !$0.isMutating }
            .map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
    }

    /// 分发执行工具
    func execute(
        name: String,
        arguments: [String: Any],
        allowMutating: Bool,
        workspace: WorkspaceManager,
        github: GitHubAPIClient,
        repoConfig: GitRepoConfig
    ) async throws -> ToolResult {
        guard let tool = tools[name] else {
            return ToolResult(success: false, output: "未知工具：\(name)")
        }
        if tool.isMutating && !allowMutating {
            return ToolResult(success: false, output: "工具 \(name) 为修改类操作，请先开启「允许修改」开关")
        }
        return try await tool.execute(
            arguments: arguments,
            workspace: workspace,
            github: github,
            repoConfig: repoConfig
        )
    }
}

/// 工具参数解析辅助
enum ToolArgs {
    static func string(_ arguments: [String: Any], _ key: String) -> String? {
        guard let value = arguments[key] else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ arguments: [String: Any], _ key: String) -> Int? {
        if let n = arguments[key] as? NSNumber { return n.intValue }
        return nil
    }

    static func bool(_ arguments: [String: Any], _ key: String) -> Bool? {
        if let b = arguments[key] as? Bool { return b }
        if let n = arguments[key] as? NSNumber { return n.boolValue }
        return nil
    }

    static func stringArray(_ arguments: [String: Any], _ key: String) -> [String]? {
        if let arr = arguments[key] as? [String] { return arr }
        if let arr = arguments[key] as? [Any] {
            return arr.compactMap { $0 as? String }
        }
        return nil
    }
}
