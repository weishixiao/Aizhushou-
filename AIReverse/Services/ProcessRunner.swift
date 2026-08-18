import Foundation
import Darwin

/// 结构化进程执行器：以参数数组方式启动子进程，避免 shell 字符串拼接造成的命令注入。
///
/// 相比直接拼 shell：
/// - launchPath + arguments 完整传给 posix_spawn/execve，参数不经过 shell 解析，
///   路径中的空格、引号、$、;、&、|、* 等都不会被当作语法处理。
/// - 支持捕获 stdout 与 stderr。
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
    /// - Parameters:
    ///   - launchPath: 可执行文件绝对路径（如 /bin/cp、/usr/bin/ldid）
    ///   - arguments: 参数数组（不含程序名）
    ///   - environment: 追加环境变量
    /// - Returns: 退出码 + stdout/stderr
    func execute(
        launchPath: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        // 环境变量：保留基础 PATH，叠加用户传入
        var env = ProcessInfo.processInfo.environment
        if !environment.isEmpty {
            env.merge(environment) { _, new in new }
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: "启动失败: \(error.localizedDescription)")
        }

        // 并发读避免管道填满死锁
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let outData = outHandle.readDataToEndOfFile()
        let errData = errHandle.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return Result(exitCode: Int(process.terminationStatus), stdout: stdout, stderr: stderr)
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
        for ch in s.unicodeScalars {
            // 允许：字母数字、常用文件系统字符、CJK（emoji 谨慎放行）
            let isASCIIAlnum = ch.isASCII && (ch.properties.isAlphabetic || ch.properties.isNumeric)
            let cjkOrOther = ch.properties.isAlphabetic && ch.value > 127 && ch.value != 0xFE0F
            let ok = isASCIIAlnum || cjkOrOther ||
                ch == "/" || ch == "." || ch == "_" || ch == "-" || ch == "@" || ch == "+" || ch == "="
            if !ok {
                // 明确拒绝危险字符
                let dangerous = "`'\"\\;|&$()<>*?[]{}! \t\n"
                if dangerous.unicodeScalars.contains(ch) {
                    return false
                }
                // 其他一律按不合法处理
                return false
            }
        }
        return true
    }
}
