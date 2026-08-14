import Foundation

struct CodingTool {
    let name: String
    let description: String
    let parameters: [String: String]
}

struct CodingToolExecutor {
    private let tools: [CodingTool] = [
        CodingTool(name: "list_dir", description: "列出目录内容", parameters: ["path": "string"]),
        CodingTool(name: "read_file", description: "读取文本文件", parameters: ["path": "string", "start_line": "integer", "end_line": "integer"]),
        CodingTool(name: "git_status", description: "查看 Git 状态", parameters: [:]),
        CodingTool(name: "git_log", description: "查看 Git 提交历史", parameters: ["count": "integer"]),
        CodingTool(name: "git_branch", description: "列出或创建 Git 分支", parameters: ["name": "string", "from_commit": "string"]),
        CodingTool(name: "git_commit", description: "提交文件到 Git 仓库", parameters: ["branch": "string", "message": "string", "files": "object"])
    ]

    func toolDefinitions() -> [CodingTool] {
        tools
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "list_dir":
            let path = stringValue(arguments["path"]) ?? ""
            return try await CodingWorkspace.shared.listDirectory(path: path)
        case "read_file":
            let path = stringValue(arguments["path"]) ?? ""
            let startLine = intValue(arguments["start_line"])
            let endLine = intValue(arguments["end_line"])
            return try await CodingWorkspace.shared.readFile(path: path, startLine: startLine, endLine: endLine)
        case "git_status":
            return try await CodingGit.shared.status()
        case "git_log":
            let count = intValue(arguments["count"]) ?? 20
            return try await CodingGit.shared.log(count: count)
        case "git_branch":
            let branch = stringValue(arguments["name"])
            let fromCommit = stringValue(arguments["from_commit"])
            return try await CodingGit.shared.branch(name: branch, fromCommit: fromCommit)
        case "git_commit":
            let branch = stringValue(arguments["branch"])
            let message = stringValue(arguments["message"]) ?? "Update files"
            let files = arguments["files"] as? [String: String] ?? [:]
            return try await CodingGit.shared.commit(branch: branch, message: message, files: files)
        default:
            throw CodingToolError.unknownTool(name)
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
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
