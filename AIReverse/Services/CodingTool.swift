import Foundation

/// AI 工具协议
protocol CodingTool {
    var name: String { get }
    var description: String { get }
    var isMutating: Bool { get }
    var parameters: [String: Any] { get }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult
}

/// 工具执行结果
struct ToolResult {
    let success: Bool
    let output: String
}

/// 工具参数帮助函数
enum ToolArgs {
    static func string(_ arguments: [String: Any], _ key: String) -> String? {
        arguments[key] as? String
    }

    static func int(_ arguments: [String: Any], _ key: String) -> Int? {
        if let value = arguments[key] as? Int { return value }
        if let value = arguments[key] as? NSNumber { return value.intValue }
        if let value = arguments[key] as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func stringArray(_ arguments: [String: Any], _ key: String) -> [String]? {
        arguments[key] as? [String]
    }

    static func bool(_ arguments: [String: Any], _ key: String) -> Bool? {
        if let value = arguments[key] as? Bool { return value }
        if let value = arguments[key] as? NSNumber { return value.boolValue }
        if let value = arguments[key] as? String {
            return value.lowercased() == "true" || value == "1" ? true : (value.lowercased() == "false" || value == "0" ? false : nil)
        }
        return nil
    }
}

enum CodingToolError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "未知工具: \(name)"
        }
    }
}

/// 工具注册器
final class ToolRegistry {
    private var tools: [String: any CodingTool] = [:]

    init() {
        register(ListDirTool())
        register(GitStatusTool())
        register(GitBranchTool())
        register(GitLogTool())
        register(RepoOverviewTool())
        register(GitCommitTool())
    }

    func register(_ tool: any CodingTool) {
        tools[tool.name] = tool
    }

    func openAIDefinitions(includeMutating: Bool) -> [[String: Any]] {
        tools.values
            .sorted { $0.name < $1.name }
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

    func execute(name: String, arguments: [String: Any], allowMutating: Bool, workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let tool = tools[name] else {
            return ToolResult(success: false, output: "未知工具: \(name)")
        }
        return try await tool.execute(arguments: arguments, workspace: workspace, github: github, repoConfig: repoConfig)
    }
}

/// 仓库配置
struct GitRepoConfig: Codable, Equatable {
    var platform: GitPlatform = .github
    var repo: String = ""
    var token: String = ""
    var branch: String = "main"

    var hasRemote: Bool {
        !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let storageKey = "git_repo_config_v1"
    private static let tokenAccount = "git.repo.token"

    static func load() -> GitRepoConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var config = try? JSONDecoder().decode(GitRepoConfig.self, from: data) else {
            return GitRepoConfig()
        }
        // 迁移：旧版本 token 明文存 UserDefaults —— 转入 Keychain
        if !config.token.isEmpty {
            KeychainStore.shared.write(config.token, account: Self.tokenAccount)
            config.token = ""
            Self.persist(config)
        } else if let stored = KeychainStore.shared.read(Self.tokenAccount) {
            config.token = stored
        }
        return config
    }

    private static func persist(_ config: GitRepoConfig) {
        var sanitized = config
        sanitized.token = ""
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func save() {
        // token 只入 Keychain，UserDefaults 中仅保留脱敏后的配置
        if token.isEmpty {
            KeychainStore.shared.delete(Self.tokenAccount)
        } else {
            KeychainStore.shared.write(token, account: Self.tokenAccount)
        }
        Self.persist(self)
    }
}
