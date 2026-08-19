import Foundation
import Darwin

/// 进程管理器：查询运行中进程、Frida 状态、抓包工具可用性。
///
/// 所有涉及 root 的操作都通过 RootServiceClient 或 JailbreakRuntime.executeAsRoot 执行。
final class ProcessManager {
    static let shared = ProcessManager()
    private init() {}

    // MARK: - 进程信息模型

    struct ProcessInfo: Identifiable, Hashable {
        let pid: Int
        let name: String
        let bundleID: String   // 仅对 OC/Swift 应用可解析
        let path: String       // 可执行路径

        var id: Int { pid }
        var displayName: String { name.isEmpty ? "PID \(pid)" : name }

        /// 是否为第三方应用（非系统进程）
        var isThirdParty: Bool {
            !bundleID.hasPrefix("com.apple.") && !bundleID.hasPrefix("com.ai.")
        }
    }

    /// Frida 环境检测结果
    struct FridaStatus {
        let isInstalled: Bool     // frida-server 二进制存在
        let isRunning: Bool       // frida-server 进程运行中
        let fridaVersion: String  // 版本号
        let installCommand: String

        /// 简要状态描述
        var summary: String {
            if isRunning {
                return "✅ Frida 运行中 (v\(fridaVersion))"
            } else if isInstalled {
                return "⚠️ Frida 已安装但未启动"
            } else {
                return "❌ 未安装 Frida"
            }
        }
    }

    // MARK: - 运行环境检测

    /// 检查 Frida 是否可用
    func checkFridaStatus() -> FridaStatus {
        // 1. 检查 frida-server 二进制是否存在于常见路径
        let fridaPaths = [
            "/var/jb/usr/bin/frida-server",
            "/usr/bin/frida-server",
            "/usr/local/bin/frida-server",
            "/opt/procursus/bin/frida-server",
        ]

        var fridaBinPath: String?
        for p in fridaPaths {
            var exists = false
            p.withCString { ptr in exists = access(ptr, F_OK) == 0 }
            if exists {
                fridaBinPath = p
                break
            }
        }

        let isInstalled = (fridaBinPath != nil)

        // 2. 检查 frida-server 进程是否运行
        let isRunning = isProcessRunning(name: "frida-server")

        // 3. 获取版本
        var version = "未知"
        if let binPath = fridaBinPath {
            let (_, out) = rt.executeCommand("\(binPath) --version 2>/dev/null || echo unknown", environment: [:])
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "unknown" {
                version = trimmed
            }
        }

        return FridaStatus(
            isInstalled: isInstalled,
            isRunning: isRunning,
            fridaVersion: version,
            installCommand: "apt update && apt install frida"
        )
    }

    /// 检查 tcpdump 是否可用
    func checkTcpdumpAvailable() -> Bool {
        let paths = ["/usr/sbin/tcpdump", "/var/jb/usr/sbin/tcpdump", "/usr/bin/tcpdump"]
        for p in paths {
            var exists = false
            p.withCString { ptr in exists = access(ptr, F_OK) == 0 }
            if exists { return true }
        }
        return false
    }

    // MARK: - 进程列表

    /// 获取当前运行中的进程列表（仅限可枚举的）
    /// 通过 root 权限执行 ps 命令获取
    func listProcesses(includeSystem: Bool = false) -> [ProcessInfo] {
        // 使用 ps 获取进程列表，带 bundle ID
        let psCmd = "ps -eo pid,comm 2>/dev/null | awk 'NR>1{print \$1,\$2}'"
        let (code, output) = executeAsRoot(psCmd)
        guard code == 0 else {
            RuntimeLogger.shared.warning("ProcessManager", "ps 命令失败 (exit=\(code))")
            return []
        }

        var processes: [ProcessInfo] = []
        for line in output.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
            let comm = parts[1...].joined(separator: " ")

            // 跳过 kernel 和过于短小的名称
            guard pid > 0, !comm.isEmpty else { continue }

            // 尝试获取 bundle ID（仅对 ObjC 应用有效）
            let bundleID = bundleIDForPID(pid)

            // 过滤系统进程（可选）
            if !includeSystem && bundleID.hasPrefix("com.apple.") && !comm.contains("/") {
                // 纯命令名（非路径）+ apple bundle → 系统进程
                continue
            }

            processes.append(ProcessInfo(
                pid: pid,
                name: comm,
                bundleID: bundleID,
                path: processPathForPID(pid)
            ))
        }

        return processes
    }

    /// 获取目标 App 的运行时信息（用于注入）
    func runtimeInfo(forApp app: InstalledApp) -> String {
        var lines: [String] = []
        lines.append("应用: \(app.displayName)")
        lines.append("Bundle ID: \(app.bundleID)")
        lines.append("安装路径: \(app.bundlePath)")

        // 尝试获取可执行名称
        let execName = executableName(forApp: app)
        lines.append("可执行文件: \(execName ?? "未知")")

        // 沙盒容器路径
        let container = containerPath(forApp: app)
        lines.append("沙盒容器: \(container ?? "无（可能未运行）")")

        // 当前是否运行中
        let runningPIDs = pidsForBundleID(app.bundleID)
        lines.append("运行状态: \(runningPIDs.isEmpty ? "未运行" : "运行中 PID=\(runningPIDs.map(String.init).joined(separator: ","))")")

        // 可执行文件路径（完整路径）
        if let execName {
            let execPath = "\(app.bundlePath)/\(execName)"
            lines.append("可执行完整路径: \(execPath)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 内部辅助

    /// 通过 root 执行命令
    private func executeAsRoot(_ command: String) -> (exitCode: Int, output: String) {
        return InjectionManager.shared.executeAsRoot(command)
    }

    /// 检查进程名是否在运行
    private func isProcessRunning(name: String) -> Bool {
        let (code, output) = executeAsRoot("pgrep -x \(name) 2>/dev/null && echo RUNNING", timeout: 5)
        return output.contains("RUNNING")
    }

    /// 获取 PID 对应的 Bundle ID
    private func bundleIDForPID(_ pid: Int) -> String {
        // 通过 NSXPC 或读取 /proc/pid/info 不太直接，使用 lsof 或 footprint
        let (_, output) = executeAsRoot("ps -p \(pid) -o command= 2>/dev/null | grep -oE 'com\\.[a-zA-Z0-9.]+' | head -1", timeout: 5)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 获取进程的可执行文件路径
    private func processPathForPID(_ pid: Int) -> String {
        let (_, output) = executeAsRoot("ps -p \(pid) -o command= 2>/dev/null | awk '{print \$1}'", timeout: 5)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 通过 Bundle ID 查找 PID
    private func pidsForBundleID(_ bundleID: String) -> [Int] {
        let (_, output) = executeAsRoot("pgrep -f '\(bundleID)' 2>/dev/null || true", timeout: 5)
        return output.components(separatedBy: .newlines).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 获取 App 的可执行文件名（从中读取 Info.plist 的 CFBundleExecutable）
    private func executableName(forApp app: InstalledApp) -> String? {
        let infoPlistPath = "\(app.bundlePath)/Info.plist"
        let (_, output) = executeAsRoot(
            "/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' '\(infoPlistPath)' 2>/dev/null || " +
            "plutil -extract CFBundleExecutable raw '\(infoPlistPath)' 2>/dev/null",
            timeout: 5
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 获取 App 的沙盒容器路径（通过 mobile_container_manager 或 footprint）
    private func containerPath(forApp app: InstalledApp) -> String? {
        let (_, output) = executeAsRoot(
            "ls -d /var/mobile/Containers/Data/Application/* 2>/dev/null | while read d; do " +
            "if [ -f \"\$d/..\$Info.plist\" ] && grep -q \"\(app.bundleID)\" \"\$d/..\$Info.plist\" 2>/dev/null; then " +
            "echo \"\$d\"; break; fi; done",
            timeout: 5
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private let rt = JailbreakRuntime.shared
