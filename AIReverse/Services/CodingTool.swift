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

struct CodingToolExecutor {
    private let tools: [any CodingTool] = [
        ReadFileTool(),
        ListDirTool(),
        GitStatusTool(),
        GitLogTool(),
        GitBranchTool(),
        GitCommitTool()
    ]

    func toolDefinitions() -> [any CodingTool] {
        tools
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "list_dir":
            let path = ToolArgs.string(arguments, "path") ?? ""
            return try await CodingWorkspace.shared.listDirectory(path: path)
        case "read_file":
            let path = ToolArgs.string(arguments, "path") ?? ""
            let startLine = ToolArgs.int(arguments, "start_line")
            let endLine = ToolArgs.int(arguments, "end_line")
            return try await CodingWorkspace.shared.readFile(path: path, startLine: startLine, endLine: endLine)
        case "git_status":
            return try await CodingGit.shared.status()
        case "git_log":
            let count = ToolArgs.int(arguments, "count") ?? 20
            return try await CodingGit.shared.log(count: count)
        case "git_branch":
            let branch = ToolArgs.string(arguments, "name")
            let fromCommit = ToolArgs.string(arguments, "from_commit")
            return try await CodingGit.shared.branch(name: branch, fromCommit: fromCommit)
        case "git_commit":
            let branch = ToolArgs.string(arguments, "branch")
            let message = ToolArgs.string(arguments, "message") ?? "Update files"
            let files = arguments["files"] as? [String: String] ?? [:]
            return try await CodingGit.shared.commit(branch: branch, message: message, files: files)
        default:
            throw CodingToolError.unknownTool(name)
        }
    }

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
        register(ReadFileTool())
        register(ListDirTool())
        register(GitStatusTool())
        register(GitBranchTool())
        register(GitLogTool())
        register(RepoOverviewTool())
        register(WriteFileTool())
        register(GitCommitTool())
    }

    func register(_ tool: any CodingTool) {
        tools[tool.name] = tool
    }

    func openAIDefinitions(includeMutating: Bool) -> [[String: Any]] {
        tools.values
            .filter { includeMutating || !$0.isMutating }
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
        guard allowMutating || !tool.isMutating else {
            return ToolResult(success: false, output: "当前未开启修改权限")
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

/// 本地工作区工具适配
final class CodingWorkspace {
    static let shared = CodingWorkspace()

    private let workspace = WorkspaceManager()

    func listDirectory(path: String) async throws -> String {
        let entries = try workspace.listFiles(relativeTo: path)
        return entries.map { entry in
            let kind = entry.isDirectory ? "[dir]" : String(format: "%8d", entry.size)
            return "\(kind)  \(entry.name)"
        }.joined(separator: "\n")
    }

    func readFile(path: String, startLine: Int? = nil, endLine: Int? = nil) async throws -> String {
        if let startLine, let endLine {
            return try workspace.readText(path, startLine: startLine, endLine: endLine)
        }
        return try workspace.readText(path)
    }
}

/// 本地 Git 工具适配
final class CodingGit {
    static let shared = CodingGit()

    func status() async throws -> String { "当前版本未接入本地 git 二进制状态读取" }
    func log(count: Int) async throws -> String { "提交历史读取暂未接入" }
    func branch(name: String?, fromCommit: String?) async throws -> String { "分支操作暂未接入" }
    func commit(branch: String?, message: String, files: [String: String]) async throws -> String { "提交操作暂未接入" }
}
