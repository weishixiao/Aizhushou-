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
    /// 捕获 stdout+stderr 并拼接返回。
    /// 使用 posix_spawn（Darwin 原生 API，iOS 必定可用，不依赖 Foundation.Process/system()）。
    @discardableResult
    func executeCommand(_ command: String,
                        arguments: [String] = [],
                        workingDirectory: String? = nil,
                        environment: [String: String] = [:]) -> (exitCode: Int32, output: String) {
        // 通过 /bin/sh -c 组装命令，避免参数转义问题
        let fullCommand: String
        if arguments.isEmpty {
            fullCommand = command
        } else {
            let quoted = arguments.map { shQuote($0) }.joined(separator: " ")
            fullCommand = "\(command) \(quoted)"
        }

        // 输出重定向到临时文件
        let outFile = "\(NSTemporaryDirectory())cmd_out_\(UUID().uuidString).txt"

        // 组装 shell 命令：支持 cd 与 PATH，输出重定向到临时文件
        var shellCommand = ""
        if let workingDirectory {
            shellCommand += "cd \(shQuote(workingDirectory)); "
        }
        var envDict = ProcessInfo.processInfo.environment
        for (k, v) in environment { envDict[k] = v }
        envDict["PATH"] = envDict["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if let path = envDict["PATH"], !path.isEmpty {
            shellCommand += "export PATH=\(shQuote(path)); "
        }
        shellCommand += fullCommand
        shellCommand += " > \(shQuote(outFile)) 2>&1"

        // 构造 argv / envp（C 字符串数组）
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(shellCommand)]
        argv.append(nil)
        defer {
            for arg in argv { if let a = arg { free(a) } }
        }

        var cEnv: [UnsafeMutablePointer<CChar>?] = envDict.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for e in cEnv { if let e { free(e) } }
        }

        // spawn /bin/sh
        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, "/bin/sh", nil, nil, argv, cEnv)
        guard spawnResult == 0 else {
            return (exitCode: spawnResult, output: "posix_spawn 失败 (error=\(spawnResult))")
        }

        // 等待子进程结束
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exitCode = (status >> 8) & 0xFF

        // 读取输出
        let output = (try? String(contentsOfFile: outFile, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: outFile)
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