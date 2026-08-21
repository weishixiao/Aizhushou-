import Foundation

// MARK: - 任意 shell 命令执行工具（不限路径、不限命令）
final class ShellExecuteTool: CodingTool {
    var name: String { "shell_execute" }
    var description: String { "执行任意 shell 命令。可运行系统命令、读取/写入任意路径文件、执行脚本等。command 是要执行的完整命令。timeout 单位秒，默认 120。返回 stdout + stderr。无路径限制，可操作任何系统位置。" }
    var isMutating: Bool { true }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "要执行的完整 shell 命令"],
                "timeout": ["type": "integer", "description": "超时秒数，默认 120，最大 300"]
            ],
            "required": ["command"]
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let cmd = ToolArgs.string(arguments, "command") else {
            return ToolResult(success: false, output: "缺少 command 参数")
        }
        let timeout = ToolArgs.int(arguments, "timeout") ?? 120
        return ShellExecutor.run(command: cmd, timeout: min(timeout, 300))
    }
}

// MARK: - 任意路径文件读取工具
final class UnrestrictedReadFileTool: CodingTool {
    var name: String { "read_file" }
    var description: String { "读取任意路径的文本文件内容。path 支持绝对路径（如 /var/jb/opt/...）和相对路径。可选 start_line / end_line 读取部分行。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "文件路径，支持绝对路径如 /var/jb/opt/procursus/bin/sh，也支持相对路径"],
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
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            do {
                url = try workspace.resolve(path)
            } catch {
                return ToolResult(success: false, output: "路径无效：\(path)")
            }
        }
        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            if let s = start, let e = end {
                let lines = content.components(separatedBy: "\n")
                guard s >= 1, e >= s, e <= lines.count else {
                    return ToolResult(success: false, output: "行号范围无效：\(s)-\(e)，文件共 \(lines.count) 行")
                }
                content = Array(lines[(s - 1)..<e]).joined(separator: "\n")
            }
            return ToolResult(success: true, output: "=== \(path) ===\n\(content)")
        } catch {
            return ToolResult(success: false, output: "读取失败 \(path)：\(error.localizedDescription)")
        }
    }
}

// MARK: - 任意路径文件写入工具
final class UnrestrictedWriteFileTool: CodingTool {
    var name: String { "write_file" }
    var description: String { "将内容写入任意路径的文件。path 支持绝对路径。覆盖已有内容。" }
    var isMutating: Bool { true }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "文件路径，支持绝对路径"],
                "content": ["type": "string", "description": "要写入的完整文件内容"]
            ],
            "required": ["path", "content"]
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let path = ToolArgs.string(arguments, "path"), let content = ToolArgs.string(arguments, "content") else {
            return ToolResult(success: false, output: "缺少 path 或 content 参数")
        }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            do {
                url = try workspace.resolve(path)
            } catch {
                return ToolResult(success: false, output: "路径无效：\(path)")
            }
        }
        do {
            let dir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let tempURL = url.appendingPathExtension("tmp_write")
            try content.data(using: .utf8)?.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
            return ToolResult(success: true, output: "已写入 \(path)（\(content.count) 字符）")
        } catch {
            return ToolResult(success: false, output: "写入失败 \(path)：\(error.localizedDescription)")
        }
    }
}

// MARK: - 文件/内容搜索工具（find + grep）
final class FileSearchTool: CodingTool {
    var name: String { "find_files" }
    var description: String { "在指定目录递归搜索文件和匹配内容。path=搜索根目录（默认 /），pattern=文件名 glob（如 *.swift），content=匹配内容关键字（grep），max_results=最大结果数（默认 50），type=dir/file。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "搜索根目录，默认 /"],
                "pattern": ["type": "string", "description": "文件名 glob 模式，如 *.swift"],
                "content": ["type": "string", "description": "grep 匹配关键字"],
                "max_results": ["type": "integer", "description": "最大结果数，默认 50，最大 200"],
                "type": ["type": "string", "description": "搜索类型：file/dir/all，默认 file"]
            ],
            "required": []
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        let base = ToolArgs.string(arguments, "path") ?? "/"
        let pattern = ToolArgs.string(arguments, "pattern")
        let content = ToolArgs.string(arguments, "content")
        let maxResults = min(ToolArgs.int(arguments, "max_results") ?? 50, 200)
        let fileType = ToolArgs.string(arguments, "type") ?? "file"

        var cmd = "find"
        var args: [String] = []
        args.append(base)

        switch fileType {
        case "dir":
            args.append("-type")
            args.append("d")
        case "file":
            args.append("-type")
            args.append("f")
        default: break
        }

        if let p = pattern {
            args.append("-name")
            args.append(p)
        }

        args.append("-print")
        cmd = cmd + " " + args.joined(separator: " ")

        if let c = content, !c.isEmpty {
            cmd += " | grep -lF \"\(c)\" 2>/dev/null"
        }

        cmd += " | head -\(maxResults)"
        cmd += " 2>/dev/null"

        let result = ShellExecutor.run(command: cmd, timeout: 30)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return ToolResult(success: true, output: "未找到匹配结果")
        }
        return ToolResult(success: true, output: output)
    }
}

// MARK: - 内容搜索工具（grep）
final class GrepSearchTool: CodingTool {
    var name: String { "grep" }
    var description: String { "在文件或目录中搜索匹配文本。pattern=正则或字符串，path=文件或目录路径，context=上下文行数（默认 0），max_results=最大行数（默认 100）。支持 -i 忽略大小写（前缀 i:），-r 递归（前缀 r:）。用法示例：grep(pattern=\"func init\", path=\"/var/minis/workspace/Aizhushou\")" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "pattern": ["type": "string", "description": "搜索模式（grep 正则或 -F 字符串）"],
                "path": ["type": "string", "description": "文件路径或目录路径"],
                "context": ["type": "integer", "description": "上下文行数，默认 0"],
                "max_results": ["type": "integer", "description": "最大行数，默认 100"],
                "case_sensitive": ["type": "boolean", "description": "是否区分大小写，默认 true"]
            ],
            "required": ["pattern", "path"]
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let pattern = ToolArgs.string(arguments, "pattern"),
              let path = ToolArgs.string(arguments, "path") else {
            return ToolResult(success: false, output: "缺少 pattern 或 path 参数")
        }
        let context = ToolArgs.int(arguments, "context") ?? 0
        let maxResults = min(ToolArgs.int(arguments, "max_results") ?? 100, 500)
        let caseSensitive = ToolArgs.bool(arguments, "case_sensitive") ?? true

        var flags = ""
        if !caseSensitive { flags += "-i" }
        if context > 0 { flags += " -C\(context)" }
        flags += " --color=never"

        let cmd = "grep\(flags) -n \"\(pattern.replacingOccurrences(of: "\"", with: "\\\""))\" \(path) 2>/dev/null | head -\(maxResults)"
        let result = ShellExecutor.run(command: cmd, timeout: 30)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return ToolResult(success: true, output: "未找到匹配内容")
        }
        return ToolResult(success: true, output: output)
    }
}

// MARK: - HTTP 请求 / 下载工具
final class HTTPRequestTool: CodingTool {
    var name: String { "http_request" }
    var description: String { "发起 HTTP 请求。method=GET/POST/PUT/DELETE，url=目标URL，headers=请求头JSON对象{\"key\":\"val\"}，body=请求体，download=true 时下载文件并保存到工作区返回路径。" }
    var isMutating: Bool { true }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "method": ["type": "string", "description": "HTTP 方法：GET/POST/PUT/DELETE/PATCH，默认 GET"],
                "url": ["type": "string", "description": "目标 URL"],
                "headers": ["type": "object", "description": "请求头，JSON 对象"],
                "body": ["type": "string", "description": "请求体（POST/PUT/PATCH 时使用）"],
                "download": ["type": "boolean", "description": "是否下载文件到工作区，默认 false"],
                "save_path": ["type": "string", "description": "下载保存路径（download=true 时必填）"]
            ],
            "required": ["url"]
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let urlStr = ToolArgs.string(arguments, "url") else {
            return ToolResult(success: false, output: "缺少 url 参数")
        }
        guard var url = URL(string: urlStr) else {
            return ToolResult(success: false, output: "URL 无效：\(urlStr)")
        }
        let method = (ToolArgs.string(arguments, "method") ?? "GET").uppercased()
        let download = ToolArgs.bool(arguments, "download") ?? false
        let savePath = ToolArgs.string(arguments, "save_path")

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60

        // 解析 headers
        if let headersRaw = arguments["headers"] as? [String: Any] {
            for (key, value) in headersRaw {
                if let val = value as? String {
                    request.setValue(val, forHTTPHeaderField: key)
                }
            }
        }

        if let body = ToolArgs.string(arguments, "body"), !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let session = URLSession(configuration: .default)
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if download {
                    guard let sp = savePath else {
                        return ToolResult(success: false, output: "download=true 时需要 save_path")
                    }
                    let url: URL
                    if sp.hasPrefix("/") {
                        url = URL(fileURLWithPath: sp)
                    } else {
                        do {
                            url = try workspace.resolve(sp)
                        } catch {
                            url = URL(fileURLWithPath: sp)
                        }
                    }
                    let dir = url.deletingLastPathComponent()
                    if !FileManager.default.fileExists(atPath: dir.path) {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    }
                    try data.write(to: url)
                    return ToolResult(success: true, output: "下载完成 → \(url.path)（\(data.count) bytes，HTTP \(httpResponse.statusCode)）")
                }

                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "[二进制数据]"
                let preview = text.count > 16000 ? String(text.prefix(16000)) + "\n...[截断]" : text
                return ToolResult(success: true, output: "HTTP \(httpResponse.statusCode)\n\n\(preview)")
            }

            return ToolResult(success: false, output: "响应类型异常：\(type(of: response))")
        } catch {
            return ToolResult(success: false, output: "请求失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - POSIX Shell 执行器（基于 posix_spawn，写脚本避免转义问题）
struct ShellExecutor {
    static func run(command: String, timeout: Int = 120) -> ToolResult {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return ToolResult(success: false, output: "无法访问文档目录")
        }

        // 将用户命令写入临时脚本文件，避免 shell 转义问题
        let scriptName = "shell_cmd_\(UUID().uuidString).sh"
        let scriptURL = docs.appendingPathComponent(scriptName)
        let stdoutURL = docs.appendingPathComponent("shell_out_\(UUID().uuidString)")
        let stderrURL = docs.appendingPathComponent("shell_err_\(UUID().uuidString)")
        let exitURL = docs.appendingPathComponent("shell_exit_\(UUID().uuidString)")

        // 脚本内容：先清空输出文件，执行命令，记录退出码
        let scriptContent = """
#!/bin/sh
: > "\(stdoutURL.path)"
: > "\(stderrURL.path)"
timeout \(max(timeout, 1)) /bin/sh -c "\(shellEscape(command))" >"\(stdoutURL.path)" 2>"\(stderrURL.path)"
echo $? >"\(exitURL.path)"
"""

        do {
            try scriptContent.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return ToolResult(success: false, output: "创建脚本失败：\(error.localizedDescription)")
        }

        // 用 posix_spawn 执行脚本
        var pid = pid_t(0)
        let args = ["/bin/sh", scriptURL.path]
        let cstrs = args.map { NSString(string: $0).utf8String }
        var cargs: [UnsafeMutablePointer<CChar>?] = cstrs.map { $0 }
        cargs.append(nil)
        let spawnResult = posix_spawn(&pid, "/bin/sh", nil, nil, &cargs, nil)

        if spawnResult != 0 {
            try? FileManager.default.removeItem(at: scriptURL)
            return ToolResult(success: false, output: "posix_spawn 失败：\(String(cString: strerror(CInt(spawnResult))!))")
        }

        // 等待子进程（带超时兜底）
        let deadline = DispatchTime.now() + DispatchTimeInterval.seconds(Int(max(timeout + 10, 15)))
        var waitStatus = Int32(0)
        var waited = false
        while !waited {
            let result = waitpid(pid, &waitStatus, WNOHANG)
            if result > 0 {
                waited = true
            } else if result == 0 {
                if DispatchTime.now() >= deadline {
                    kill(pid, SIGKILL)
                    waitpid(pid, &waitStatus, 0)
                    waited = true
                } else {
                    usleep(50_000)
                }
            } else {
                break
            }
        }

        // 读取输出
        var stdout = ""
        if FileManager.default.fileExists(atPath: stdoutURL.path) {
            stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        }
        var stderr = ""
        if FileManager.default.fileExists(atPath: stderrURL.path) {
            stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        }
        let exitCode: Int
        if FileManager.default.fileExists(atPath: exitURL.path) {
            let ec = (try? String(contentsOf: exitURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            exitCode = Int(ec ?? "127") ?? 127
        } else {
            exitCode = 127
        }

        // 清理临时文件
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
        try? FileManager.default.removeItem(at: exitURL)

        // 构建输出
        let isTimeout = exitCode == 124 // timeout 命令退出码
        var output = stdout
        if !stderr.isEmpty {
            output += "\n[stderr]\n\(stderr)"
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalOutput = trimmed.count > 16000 ? String(trimmed.prefix(16000)) + "\n...[截断]" : trimmed

        if isTimeout {
            return ToolResult(success: false, output: "[命令超时 \(timeout)s]\n\(finalOutput)")
        } else if exitCode == 0 {
            return ToolResult(success: true, output: finalOutput)
        } else {
            return ToolResult(success: false, output: "[退出码 \(exitCode)]\n\(finalOutput)")
        }
    }

    // 用双引号包裹命令，转义内部双引号、反斜杠、美元符号和反引号
    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\"", with: "\\\"")
          .replacingOccurrences(of: "$", with: "\\$")
          .replacingOccurrences(of: "`", with: "\\`")
    }
}