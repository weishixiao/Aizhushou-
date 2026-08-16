import Foundation
import Darwin

/// 越狱运行时的最高权限管理。
///
/// 本模块负责：
/// 1. 检测当前进程所处的越狱环境（jailbreak / TrollStore / rootless / sandbox 状态）
/// 2. 尝试获取并用好 root 权限（geteuid == 0）
/// 3. 提供「以最高权限 spawn 外部命令」的封装，供注入 / 修改数据使用
final class JailbreakRuntime {
    static let shared = JailbreakRuntime()
    private init() {}

    // MARK: - 环境探测

    /// 当前 euid（0 表示 root）
    var currentUID: uid_t {
        geteuid()
    }

    /// 是否以 root 运行
    var isRoot: Bool {
        geteuid() == 0
    }

    /// 是否处于沙盒内（对越狱环境通常应绕过/禁用作弊检测，本标志用于给 AI 提示权限状态）
    var isSandboxed: Bool {
        // 简化判断：sandbox 下读 /Applications 受限；rootless 越狱通常有权限
        geteuid() != 0
    }

    /// 是否为越狱 / TrollStore 环境
    var isJailbroken: Bool {
        // 常见的越狱痕迹 / 路径
        let indicators: [String] = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/var/jb",                     // rootless (palera1n / Dopamine / RootHide)
            "/usr/libexec/cydia",
            "/private/var/lib/apt",
            "/var/lib/apt",
            "/.installed_unc0ver",
            "/.bootstrapped_electra",
            "/binpack",
        ]
        for path in indicators where FileManager.default.fileExists(atPath: path) {
            return true
        }

        // 尝试读写系统路径判断权限
        let probe = "/private/preboot"
        if FileManager.default.isWritableFile(atPath: probe) {
            return true
        }

        // 动态链接注入判断（运行中进程注入的逃逸检测——本工具自身）
        if dlopen("/usr/lib/libjailbreak.dylib", RTLD_LAZY) != nil {
            dlclose_hack()
            return true
        }

        return false
    }

    /// 打印一段环境摘要（供 AI 分析权限上下文）
    var environmentSummary: String {
        let jailbreakText = isJailbroken ? "是" : "否"
        let userText = isRoot ? "root（最高权限）" : "非 root（euid=\(currentUID)）"
        let sandboxText = isSandboxed ? "受限" : "已放宽"
        var lines: [String] = []
        lines.append("越狱环境：\(jailbreakText)")
        lines.append("当前用户：\(userText)")
        lines.append("沙盒状态：\(sandboxText)")
        if let jb = jbRootPath {
            lines.append("越狱根路径：\(jb)")
        }
        return lines.joined(separator: "\n")
    }

    /// 越狱根路径检测（rootless 越狱为 /var/jb，legacy 为 /）
    var jbRootPath: String? {
        if FileManager.default.fileExists(atPath: "/var/jb") { return "/var/jb" }
        if FileManager.default.fileExists(atPath: "/usr/bin/uicache") { return "/" }
        return isJailbroken ? "/" : nil
    }

    private func dlclose_hack() {
        // dlopen 成功代表有越狱注入库，立即关闭即可（此处仅为探测，不需持有）
        // 真实签名 defer 即可，不必调用 dlclose（会被平台策略拦截，静默忽略）
    }

    // MARK: - root 权限命令执行封装

    /// 用当前进程权限（root 时即最高权限）执行外部命令，
    /// 支持把 stdout/stderr 拼接返回。
    @discardableResult
    func executeCommand(_ command: String,
                        arguments: [String] = [],
                        workingDirectory: String? = nil,
                        environment: [String: String] = [:]) -> (exitCode: Int32, output: String) {
        // 通过 ash -c 组装命令，避免参数转义问题
        let shell = "/bin/sh"
        let fullCommand: String
        if arguments.isEmpty {
            fullCommand = command
        } else {
            let quoted = arguments.map { shQuote($0) }.joined(separator: " ")
            fullCommand = "\(command) \(quoted)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        var args = ["-c", fullCommand]
        // 尝试以 root 身份运行：越狱 rootless 环境常用 setuid(0) 已由 trusted platform 提供，
        // 这里保留 setuid 探测逻辑，若已为 root 则直接忽略
        if !isRoot {
            // 尝试提权（仅当可注入 setuid 辅助时生效，通常不可行，予以忽略）
            let _ = setuid(0)
        }
        process.arguments = args
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        // 注入环境变量
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment {
            env[k] = v
        }
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var outputData = Data()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handler in
            let data = handler.availableData
            if data.isEmpty { return }
            outputData.append(data)
        }

        var exitCode: Int32 = -1
        do {
            try process.run()
            process.waitUntilExit()
            exitCode = process.terminationStatus
        } catch {
            return (errorCode: errno, output: error.localizedDescription)
        }
        handle.readabilityHandler = nil
        let output = String(data: outputData, encoding: .utf8) ?? ""

        return (exitCode, output)
    }

    /// POSIX sh 安全引号
    private func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 最常用注入/修改的便捷包装

    /// 以 root 权限把文件复制到目标路径并设置 0755（注入 dylib 常用）
    @discardableResult
    func installFileAsRoot(source: String, destination: String) -> (Int32, String) {
        executeCommand("/bin/cp", arguments: [source, destination], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    /// 以 root 权限移除某路径
    @discardableResult
    func removePathAsRoot(_ path: String) -> (Int32, String) {
        executeCommand("/bin/rm", arguments: ["-rf", path], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }
}

// 供外部读取使用的小工具
enum RuntimeEnv {
    /// 全局共享的越狱运行时
    static let runtime = JailbreakRuntime.shared
}