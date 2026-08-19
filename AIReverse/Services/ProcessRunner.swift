import Foundation
import Darwin

/// 结构化进程执行器：以参数数组方式启动子进程，避免 shell 字符串拼接造成的命令注入。
///
/// 相比直接拼 shell：
/// - launchPath + arguments 完整传给 posix_spawn，参数不经过 shell 解析，
///   路径中的空格、引号、$、;、&、|、* 等都不会被当作语法处理。
/// - 支持捕获 stdout 与 stderr。
/// - 在 iOS 上使用 POSIX 的 posix_spawn（而非 macOS 专属的 Process 类），
///   需要在越狱环境或拥有 com.apple.private.security.no-sandbox entitlement 下运行。
/// - 若通过 su/RootService 提权，仍需 shell（RootService 侧另有白名单校验兜底）。
final class ProcessRunner {

    struct Result {
        let exitCode: Int
        let stdout: String
        let stderr: String
        var success: Bool { exitCode == 0 }
        /// 合并输出，便于展示
        var combined: String {
            var parts: [String] = []
            if !stdout.isEmpty { parts.append(stdout) }
            if !stderr.isEmpty { parts.append(stderr) }
            return parts.joined(separator: "\n")
        }
    }

    /// 以参数数组执行命令。
    /// 内部使用 posix_spawnp（在 PATH 中搜索可执行文件）。
    /// - Parameters:
    ///   - launchPath: 可执行文件路径（如 /bin/cp、/usr/bin/ldid）
    ///   - arguments: 参数数组（不含程序名）
    ///   - environment: 环境变量字典
    /// - Returns: 退出码 + stdout/stderr
    func execute(
        launchPath: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> Result {
        // 构造 argv：第 0 个是程序名（basename），后续是参数
        let progName = (launchPath as NSString).lastPathComponent
        let argv: [String] = [progName] + arguments

        // 构造环境变量
        var envDict = ProcessInfo.processInfo.environment
        if !environment.isEmpty {
            envDict.merge(environment) { _, new in new }
        }

        // 创建管道
        let outPipe = self.makePipe()
        let errPipe = self.makePipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)

        // 子进程 stdout → outPipe 写入端
        posix_spawn_file_actions_adddup2(&fileActions, outPipe.writeEnd, STDOUT_FILENO)
        // 子进程 stderr → errPipe 写入端
        posix_spawn_file_actions_adddup2(&fileActions, errPipe.writeEnd, STDERR_FILENO)
        // 关闭父进程的管道写入端拷贝（子进程继承后已无需父进程持有）
        posix_spawn_file_actions_addclose(&fileActions, outPipe.writeEnd)
        posix_spawn_file_actions_addclose(&fileActions, errPipe.writeEnd)

        // 转换为 C 类型
        let cArgs = argv.map { $0.withCString(strdup) } + [UnsafeMutablePointer<Int8>(bitPattern: 0)]
        let cEnv = envDict.map { "\($0.key)=\($0.value)".withCString(strdup) } + [UnsafeMutablePointer<Int8>(bitPattern: 0)]
        defer {
            cArgs.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
        }

        var pid: pid_t = 0
        let ret = posix_spawnp(&pid, launchPath, &fileActions, nil, cArgs, cEnv)

        // 关闭父进程的写入端（只有子进程需要写入）
        close(outPipe.writeEnd)
        close(errPipe.writeEnd)

        if ret != 0 {
            return Result(exitCode: -1, stdout: "", stderr: "posix_spawnp 失败: \(String(cString: strerror(ret)))")
        }

        // 等待子进程退出
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        // 读取管道数据
        let outData = readAllFD(outPipe.readEnd)
        let errData = readAllFD(errPipe.readEnd)
        close(outPipe.readEnd)
        close(errPipe.readEnd)

        // WIFEXITED/WEXITSTATUS 是 C 宏，Swift 中不可用，手工解析 waitpid 返回的 status
        // 正常退出: (status & 0x7f) == 0；退出码: (status >> 8) & 0xff
        let exitCode = ((status & 0x7f) == 0) ? Int((status >> 8) & 0xff) : -1
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return Result(exitCode: Int(exitCode), stdout: stdout, stderr: stderr)
    }

    // MARK: - 管道辅助

    private struct PipePair {
        let readEnd: Int32
        let writeEnd: Int32
    }

    private func makePipe() -> PipePair {
        var fds: [Int32] = [0, 0]
        pipe(&fds)
        return PipePair(readEnd: fds[0], writeEnd: fds[1])
    }

    private func readAllFD(_ fd: Int32) -> Data {
        var buf = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<Int(n)])
        }
        return data
    }

    /// 便捷：以 /bin/sh -c 执行一段脚本（参数仍是单个 string，仅用于确实需要 shell 的场合，
    /// 例如命令组合。外部路径必须先通过 `sanitizeComponent` 校验）。
    func shell(_ cmd: String, environment: [String: String] = [:]) -> Result {
        execute(launchPath: "/bin/sh", arguments: ["-c", cmd], environment: environment)
    }

    /// 对单个路径组件做字符白名单校验，拒绝所有可能触发 shell 解释的元字符。
    /// 返回 true 表示安全，可用于命令拼接前的前置校验。
    static func isSafePathComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 1024 else { return false }
        for ch in s {
            // 允许：字母数字、常用文件系统字符、CJK（emoji 谨慎放行）
            let isAlnum = ch.isLetter || ch.isNumber
            let ok = isAlnum ||
                ch == "/" || ch == "." || ch == "_" || ch == "-" || ch == "@" || ch == "+" || ch == "="
            if !ok {
                // 明确拒绝危险字符
                let dangerous = "`'\"\\;|&$()<>*?[]{}! \t\n"
                if dangerous.contains(ch) {
                    return false
                }
                // 其他一律按不合法处理
                return false
            }
        }
        return true
    }
}
