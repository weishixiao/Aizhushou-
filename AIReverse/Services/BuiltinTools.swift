import Foundation

/// 读取文件工具（只读）
final class ReadFileTool: CodingTool {
    var name: String { "read_file" }
    var description: String { "读取工作区内文本文件内容。可指定 start_line 与 end_line 读取部分内容。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "文件相对路径，如 Sources/main.swift"],
                "start_line": ["type": "integer", "description": "起始行（可选，从 1 开始）"],
                "end_line": ["type": "integer", "description": "结束行（可选）"]
            ],
            "required": ["path"]
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let path = ToolArgs.string(arguments, "path") else {
            return ToolResult(success: false, output: "缺少 path 参数")
        }
        let start = ToolArgs.int(arguments, "start_line")
        let end = ToolArgs.int(arguments, "end_line")
        do {
            let content: String
            if let s = start, let e = end {
                content = try workspace.readText(path, startLine: s, endLine: e)
            } else {
                content = try workspace.readText(path)
            }
            return ToolResult(success: true, output: "=== \(path) ===\n\(content)")
        } catch {
            return ToolResult(success: false, output: "读取失败：\(error.localizedDescription)")
        }
    }
}

/// 列目录工具（只读）
final class ListDirTool: CodingTool {
    var name: String { "list_dir" }
    var description: String { "列出工作区内目录的内容（文件与子目录）。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "目录相对路径，空表示仓库根目录"]
            ],
            "required": []
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        let dir = ToolArgs.string(arguments, "path") ?? ""
        do {
            let entries = try workspace.listFiles(relativeTo: dir)
            var lines = ["=== \(dir.isEmpty ? "/" : dir) ==="]
            for entry in entries {
                let kind = entry.isDirectory ? "[dir]" : String(format: "%8d", entry.size)
                lines.append("\(kind)  \(entry.name)")
            }
            return ToolResult(success: true, output: lines.joined(separator: "\n"))
        } catch {
            return ToolResult(success: false, output: "列目录失败：\(error.localizedDescription)")
        }
    }
}

/// Git 状态工具（只读）
final class GitStatusTool: CodingTool {
    var name: String { "git_status" }
    var description: String { "显示工作区当前 git 状态：分支、已修改文件、未跟踪文件。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        ["type": "object", "properties": [:], "required": []]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        let tracker = GitStatusTracker()
        tracker.bind(to: workspace)
        let snapshot = workspace.snapshot(branch: repoConfig.branch, remoteURL: repoConfig.repo, commitHash: "")
        let changes = tracker.diff(current: snapshot)
        let untracked = tracker.untrackedFiles(workspace: workspace, baseline: tracker.loadSnapshot())

        var lines = ["当前分支：\(repoConfig.branch)"]
        if repoConfig.hasRemote {
            lines.append("远端：\(repoConfig.repo)")
        }
        let modified = changes.filter { $0.type == .modified }.map { $0.path }
        let deleted = changes.filter { $0.type == .deleted }.map { $0.path }
        if !modified.isEmpty {
            lines.append("已修改：")
            lines.append(contentsOf: modified.map { "  M \($0)" })
        }
        if !deleted.isEmpty {
            lines.append("已删除：")
            lines.append(contentsOf: deleted.map { "  D \($0)" })
        }
        if !untracked.isEmpty {
            lines.append("未跟踪：")
            lines.append(contentsOf: untracked.map { "  ?? \($0)" })
        }
        if modified.isEmpty && deleted.isEmpty && untracked.isEmpty {
            lines.append("工作区干净，无未提交变更")
        }
        return ToolResult(success: true, output: lines.joined(separator: "\n"))
    }
}

/// Git 分支工具（只读；创建分支走 git_commit 关联逻辑）
final class GitBranchTool: CodingTool {
    var name: String { "git_branch" }
    var description: String { "列出远端仓库分支。参数 name 与 from_commit 用于创建新分支（需开启允许修改）。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "要创建的分支名（可选，仅创建时提供）"],
                "from_commit": ["type": "string", "description": "新分支基于的 commit sha（可选，默认当前 HEAD）"]
            ],
            "required": []
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard repoConfig.hasRemote else {
            return ToolResult(success: false, output: "未配置远程仓库")
        }
        do {
            let branches = try await github.branches(repo: repoConfig.repo, token: repoConfig.token)
            return ToolResult(success: true, output: "分支列表：\n" + branches.map { "  \($0 == repoConfig.branch ? "* " : "  ")\($0)" }.joined(separator: "\n"))
        } catch {
            return ToolResult(success: false, output: "获取分支失败：\(error.localizedDescription)")
        }
    }
}

/// Git 日志工具（只读）
final class GitLogTool: CodingTool {
    var name: String { "git_log" }
    var description: String { "显示远端仓库最近的提交历史。参数 count 控制条数。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "count": ["type": "integer", "description": "提交条数，默认 20"]
            ],
            "required": []
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard repoConfig.hasRemote else {
            return ToolResult(success: false, output: "未配置远程仓库")
        }
        let count = ToolArgs.int(arguments, "count") ?? 20
        do {
            let log = try await github.commitLog(repo: repoConfig.repo, token: repoConfig.token, branch: repoConfig.branch, count: min(count, 50))
            let lines = log.map { item in
                let sha = String(item.sha.prefix(7))
                let date = item.commit.author.date.prefix(10)
                return "\(sha) \(date) \(item.commit.author.name) - \(item.commit.message.components(separatedBy: "\n").first ?? "")"
            }
            return ToolResult(success: true, output: "提交历史：\n" + lines.joined(separator: "\n"))
        } catch {
            return ToolResult(success: false, output: "获取提交历史失败：\(error.localizedDescription)")
        }
    }
}

/// 仓库概览工具（只读）
final class RepoOverviewTool: CodingTool {
    var name: String { "repo_overview" }
    var description: String { "查看工作区整体概览：文件树结构、文件数量与大小摘要。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        ["type": "object", "properties": [:], "required": []]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        do {
            let entries = try workspace.listFiles(relativeTo: "")
            var lines = ["=== 工作区概览（根目录）==="]
            for entry in entries {
                let kind = entry.isDirectory ? "[dir]" : String(format: "%8d", entry.size)
                lines.append("\(kind)  \(entry.name)")
            }
            lines.append("")
            lines.append("分支：\(repoConfig.branch)  远端：\(repoConfig.hasRemote ? repoConfig.repo : "未配置")")
            return ToolResult(success: true, output: lines.joined(separator: "\n"))
        } catch {
            return ToolResult(success: false, output: "获取概览失败：\(error.localizedDescription)")
        }
    }
}
