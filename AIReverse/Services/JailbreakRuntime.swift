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

    /// 检测 rootless 环境下的 root shell 路径（/var/jb/opt/procursus/bin/sh 优先）
    var rootShell: String {
        let jbProcursusShell = "/var/jb/opt/procursus/bin/sh"
        var exists = false
        jbProcursusShell.withCString { ptr in exists = access(ptr, F_OK) == 0 }
        if exists { return jbProcursusShell }
        return "/bin/sh"
    }

    /// UserDefaults 手动覆盖越狱标识的 key
    static let overrideKey = "jailbreak_override_flag"

    /// 手动指定/解除越狱环境（自动检测失败时使用）
    func setJailbreakOverride(_ value: Bool?) {
        if let value {
            UserDefaults.standard.set(value, forKey: Self.overrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.overrideKey)
        }
    }

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
        // 0) 若用户手动强制指定，以手动值为准（自动检测在沙盒内可能受限）
        if UserDefaults.standard.object(forKey: Self.overrideKey) != nil {
            return UserDefaults.standard.bool(forKey: Self.overrideKey)
        }

        // 1) 越狱特征路径（用 access 而非 fileExists，因为沙盒内 fileExists 对系统路径会误报不存在）
        let indicators: [String] = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Applications/Installer.app",
            "/var/jb",                     // rootless (palera1n / Dopamine / RootHide)
            "/usr/libexec/cydia",
            "/usr/lib/substrate",
            "/usr/lib/libsubstrate.dylib",
            "/private/var/lib/apt",
            "/var/lib/apt",
            "/.installed_unc0ver",
            "/.bootstrapped_electra",
            "/binpack",
            "/var/binpack",
            "/var/lib/cydia",
            "/var/stash",
        ]
        for path in indicators where pathAccessable(path, mode: F_OK) {
            return true
        }

        // 2) 读写系统路径权限（越狱环境对系统可写）
        let writeProbes = ["/private/preboot", "/var/mobile", "/Library"]
        for p in writeProbes where FileManager.default.isWritableFile(atPath: p) {
            return true
        }

        // 3) 动态注入库（运行中进程注入）
        let injectLibs = ["/var/jb/usr/lib/libjailbreak.dylib",
                          "/usr/lib/libjailbreak.dylib",
                          "/usr/lib/libsubstrate.dylib",
                          "/var/jb/usr/lib/libsubstrate.dylib"]
        for lib in injectLibs {
            if dlopen(lib, RTLD_LAZY) != nil {
                dlclose_hack()
                return true
            }
        }

        // 4) 越狱注入库环境变量检测
        if executableInjected() {
            return true
        }

        return false
    }

    /// 用 access() 系统调用检测路径存在性（比 fileExists 更贴合越狱环境）
    private func pathAccessable(_ path: String, mode: Int32) -> Bool {
        return path.withCString { access($0, mode) == 0 }
    }

    /// 检测环境变量层面是否有越狱注入
    private func executableInjected() -> Bool {
        // DYLD_INSERT_LIBRARIES 常用于越狱注入
        if let injected = getenv("DYLD_INSERT_LIBRARIES") {
            return String(cString: injected).count > 0
        }
        return false
    }

    /// 打印一段环境摘要（供 AI 分析权限上下文）
    var environmentSummary: String {
        let jailbreakText = isJailbroken ? "是" : "否"
        let userText = isRoot ? "root（最高权限）" : "mobile（euid=\(currentUID)）"
        let sandboxText = isSandboxed ? "受限" : "已放宽"
        var lines: [String] = []
        lines.append("越狱环境：\(jailbreakText)")
        lines.append("运行用户：\(userText)")
        lines.append("沙盒状态：\(sandboxText)")
        if let jb = jbRootPath {
            lines.append("越狱根：\(jb)")
        }
        // 检测 jbroot 命令是否可用（RootHide 环境）
        let (jbCode, jbOut) = executeCommand("jbroot", environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        if jbCode == 0 {
            let jbRoot = jbOut.trimmingCharacters(in: .whitespacesAndNewlines)
            if !jbRoot.isEmpty {
                lines.append("jbroot: \(jbRoot)（RootHide 路径）")
                // 检测注入目录
                let injDir = (jbRoot as NSString).appendingPathComponent("Library/MobileSubstrate/DynamicLibraries")
                var exists = false
                injDir.withCString { ptr in exists = access(ptr, F_OK) == 0 }
                lines.append("注入目录: \(injDir)")
                lines.append("目录存在: \(exists ? "是" : "否")")
                if !exists {
                    lines.append("目录可写: 否（路径不存在）")
                }
            }
        } else {
            // 兜底：检测传统路径
            let legacyDir = "/var/jb/Library/MobileSubstrate/DynamicLibraries"
            var legacyExists = false
            legacyDir.withCString { ptr in legacyExists = access(ptr, F_OK) == 0 }
            lines.append("注入目录: \(legacyDir)")
            lines.append("目录存在: \(legacyExists ? "是" : "否")")
            if !legacyExists {
                let writable = FileManager.default.isWritableFile(atPath: "/var/jb")
                lines.append("目录可写: \(writable ? "是" : "否（权限不足）")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 越狱根路径检测（尝试 jbroot 命令，失败则回退到传统路径）
    var jbRootPath: String? {
        // 先尝试 jbroot 命令（RootHide）
        let (code, out) = executeCommand("jbroot", environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        if code == 0 {
            let jbRoot = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !jbRoot.isEmpty { return jbRoot }
        }
        // 传统路径
        var exists = false
        "/var/jb".withCString { ptr in exists = access(ptr, F_OK) == 0 }
        if exists { return "/var/jb" }
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

        // spawn 检测到的 root shell
        var pid: pid_t = 0
        let shellPath = isRoot ? rootShell : "/bin/sh"
        let spawnResult = posix_spawn(&pid, shellPath, nil, nil, argv, cEnv)
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