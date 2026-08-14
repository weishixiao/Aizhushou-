import Foundation

/// 写文件工具（修改类，需开启「允许修改」）
final class WriteFileTool: CodingTool {
    var name: String { "write_file" }
    var description: String { "将内容写入工作区指定文件（覆盖已有内容）。写入前自动备份原文件到 .ai_backup/。属于修改类操作。" }
    var isMutating: Bool { true }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "文件相对路径"],
                "content": ["type": "string", "description": "要写入的完整文件内容"]
            ],
            "required": ["path", "content"]
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let path = ToolArgs.string(arguments, "path") else {
            return ToolResult(success: false, output: "缺少 path 参数")
        }
        guard let content = ToolArgs.string(arguments, "content") else {
            return ToolResult(success: false, output: "缺少 content 参数")
        }
        do {
            try workspace.writeText(path, content: content)
            return ToolResult(success: true, output: "已写入 \(path)（\(content.count) 字符）")
        } catch {
            return ToolResult(success: false, output: "写入失败：\(error.localizedDescription)")
        }
    }
}

/// Git 提交工具（修改类，需开启「允许修改」）
/// 通过 GitHub Git Data API 顺序执行 blob -> tree -> commit -> ref。
final class GitCommitTool: CodingTool {
    var name: String { "git_commit" }
    var description: String { "提交工作区变更到远端仓库当前分支。会扫描本地快照差异：新增/修改的文件通过 files 参数提供内容，删除通过 deleted_paths 提供。提交后更新本地基线快照。属于修改类操作。" }
    var isMutating: Bool { true }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "message": ["type": "string", "description": "提交信息"],
                "branch": ["type": "string", "description": "目标分支，默认当前分支"],
                "files": [
                    "type": "object",
                    "description": "要提交写入的文件内容映射：{相对路径: 新内容}",
                    "additionalProperties": ["type": "string"]
                ],
                "deleted_paths": [
                    "type": "array",
                    "description": "要删除的文件相对路径列表",
                    "items": ["type": "string"]
                ]
            ],
            "required": ["message"]
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let message = ToolArgs.string(arguments, "message"), !message.isEmpty else {
            return ToolResult(success: false, output: "缺少 message 参数")
        }
        guard repoConfig.hasRemote else {
            return ToolResult(success: false, output: "未配置远程仓库，无法提交")
        }
        let branch = ToolArgs.string(arguments, "branch") ?? repoConfig.branch
        var files: [String: String] = [:]
        if let raw = arguments["files"] as? [String: Any] {
            for (key, value) in raw {
                if let s = value as? String {
                    files[key] = s
                } else if let d = value as? [String: Any], let s = d["content"] as? String {
                    files[key] = s
                }
            }
        }
        let deleted = ToolArgs.stringArray(arguments, "deleted_paths") ?? []

        // 若未显式提供 files，尝试从本地快照差异自动收集已修改文本文件
        var effectiveFiles = files
        if effectiveFiles.isEmpty {
            let tracker = GitStatusTracker()
            tracker.bind(to: workspace)
            let snapshot = workspace.snapshot(branch: branch, remoteURL: repoConfig.repo, commitHash: "")
            let changes = tracker.diff(current: snapshot)
            for change in changes where change.type == .modified {
                if workspace.isTextFile(change.path) {
                    if let content = try? workspace.readText(change.path) {
                        effectiveFiles[change.path] = content
                    }
                }
            }
            let untracked = tracker.untrackedFiles(workspace: workspace, baseline: tracker.loadSnapshot())
            for path in untracked {
                if workspace.isTextFile(path) {
                    if let content = try? workspace.readText(path) {
                        effectiveFiles[path] = content
                    }
                }
            }
            var effectiveDeleted = deleted
            for change in changes where change.type == .deleted {
                if !effectiveDeleted.contains(change.path) {
                    effectiveDeleted.append(change.path)
                }
            }
            if effectiveFiles.isEmpty && effectiveDeleted.isEmpty {
                return ToolResult(success: false, output: "没有需要提交的变更")
            }
            return try await performCommit(
                workspace: workspace, github: github, repoConfig: repoConfig,
                branch: branch, message: message,
                files: effectiveFiles, deleted: effectiveDeleted
            )
        }

        var effectiveDeleted = deleted
        // 用户显式删除路径也纳入
        for key in arguments.keys where key.hasPrefix("delete:") {
            if let p = arguments[key] as? String {
                effectiveDeleted.append(p)
            }
        }
        if effectiveFiles.isEmpty && effectiveDeleted.isEmpty {
            return ToolResult(success: false, output: "没有需要提交的文件")
        }
        return try await performCommit(
            workspace: workspace, github: github, repoConfig: repoConfig,
            branch: branch, message: message,
            files: effectiveFiles, deleted: effectiveDeleted
        )
    }

    private func performCommit(
        workspace: WorkspaceManager,
        github: GitHubAPIClient,
        repoConfig: GitRepoConfig,
        branch: String,
        message: String,
        files: [String: String],
        deleted: [String]
    ) async throws -> ToolResult {
        do {
            let sha = try await github.commitFiles(
                repo: repoConfig.repo,
                token: repoConfig.token,
                branch: branch,
                message: message,
                files: files,
                deletedPaths: deleted
            )
            // 提交成功后更新本地基线快照
            let tracker = GitStatusTracker()
            tracker.bind(to: workspace)
            let snapshot = workspace.snapshot(branch: branch, remoteURL: repoConfig.repo, commitHash: sha)
            try? tracker.saveSnapshot(snapshot)

            var summary = "提交成功：\(branch) \(String(sha.prefix(7)))"
            if !files.isEmpty {
                summary += "写入/修改：\n" + files.keys.sorted().map { "  + \($0)" }.joined(separator: "\n") + "\n"
            }
            if !deleted.isEmpty {
                summary += "删除：\n" + deleted.sorted().map { "  - \($0)" }.joined(separator: "\n")
            }
            return ToolResult(success: true, output: summary)
        } catch {
            return ToolResult(success: false, output: "提交失败：\(error.localizedDescription)")
        }
    }
}
