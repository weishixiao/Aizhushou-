import Foundation
import Darwin

/// 越狱提权方案管理。
///
/// 依据文档《Relaxin 环境唯一可行永久方案：LaunchDaemon 守护进程》实现。
///
/// 核心思路：
/// 1. 检测 App 真实二进制路径（/var/mobile/Containers/Bundle/Application/.../AIReverse.app/AIReverse）
/// 2. 生成 LaunchDaemon plist，让系统 launchd 以 root 身份自动拉起 App 二进制
/// 3. 用户通过桌面图标 + URL Scheme 唤醒前台 UI（非 root 的 UI 层）
///
/// ⚠️ 关键约束（来自文档）：
/// - 不可用 chmod u+s SetUID（AMFI/PPL 内核拦截）
/// - 不可移动 App 到 /Applications（rootless 下无效）
/// - 不可尝试 rootful 旧教程（Relaxin 不兼容）
///
/// 开发阶段建议：全程用 NewTerm root 启动测试；正式版用 LaunchDaemon + URL Scheme。
final class RootPrivilegeManager {
    static let shared = RootPrivilegeManager()
    private init() {}

    /// LaunchDaemon 的 label
    static let daemonLabel = "com.aireverse.rootlaunch"

    // MARK: - 环境检测

    /// 是否为 rootless 越狱（Relaxin / Dopamine / Palera1n-rootless / RootHide）
    var isRootless: Bool {
        let (code, _) = JailbreakRuntime.shared.executeCommand(
            "jbroot 2>/dev/null",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        return code == 0
    }

    /// 是否可能是 Relaxin 环境（RootHide 变种，无 jbroot 但有 /var/jb）
    var isRelaxin: Bool {
        var exists = false
        "/var/jb/opt/procursus/bin/sh".withCString { ptr in exists = access(ptr, F_OK) == 0 }
        return exists
    }

    /// 当前越狱环境描述
    var environmentDescription: String {
        if isRootless {
            let (code, out) = JailbreakRuntime.shared.executeCommand(
                "jbroot 2>/dev/null",
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            )
            let jbRoot = code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !jbRoot.isEmpty {
                return "Rootless（jbroot=\(jbRoot)）"
            }
            return "Rootless"
        }
        if isRelaxin {
            return "Relaxin（procursus 路径存在）"
        }
        return "Unknown（可能是 rootful 或 TrollStore）"
    }

    // MARK: - 路径检测

    /// 检测 rootless 的 root 用户 shell 路径（优先 /var/jb/opt/procursus/bin/sh）
    var rootShellPath: String {
        let (code, out) = JailbreakRuntime.shared.executeCommand(
            "jbroot 2>/dev/null",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        if code == 0 {
            let jbRoot = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let procursusShell = (jbRoot as NSString).appendingPathComponent("opt/procursus/bin/sh")
            var exists = false
            procursusShell.withCString { ptr in exists = access(ptr, F_OK) == 0 }
            if exists { return procursusShell }
        }
        // 检查 /var/jb 的 procursus
        let jbProcursusShell = "/var/jb/opt/procursus/bin/sh"
        var exists = false
        jbProcursusShell.withCString { ptr in exists = access(ptr, F_OK) == 0 }
        if exists { return jbProcursusShell }
        // 回退
        return "/bin/sh"
    }

    /// App 二进制路径（/var/mobile/Containers/Bundle/Application/XXXX/AIReverse.app/AIReverse）
    var appBinaryPath: String {
        let mainBundle = Bundle.main
        let binPath = mainBundle.executablePath ?? mainBundle.bundlePath
        return binPath
    }

    /// App 容器路径（Application bundle 所在目录）
    var appContainerPath: String {
        let mainBundle = Bundle.main
        return mainBundle.bundleURL.deletingLastPathComponent().path
    }

    // MARK: - LaunchDaemon 管理

    /// 生成 LaunchDaemon plist 内容
    func daemonPlistContent(binaryPath: String) -> String {
        """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>\(Self.daemonLabel)</string>
    <key>ProgramArguments</key>
    <array>
        <string>\(binaryPath)</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/mobile/aireverse-daemon-log.txt</string>
    <key>StandardErrorPath</key>
    <string>/var/mobile/aireverse-daemon-err.txt</string>
    <key>UserName</key>
    <string>root</string>
    <key>KeepAlive</key>
    <false/>
    <key>AbandonProcessGroup</key>
    <true/>
</dict>
</plist>
"""
    }

    /// 配置目录（rootless 用 jbroot 路径，普通越狱用 /var/jb）
    private var launchDaemonDir: String? {
        let rt = JailbreakRuntime.shared
        let (code, out) = rt.executeCommand(
            "jbroot 2>/dev/null",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        var jbRoot: String?
        if code == 0 {
            jbRoot = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let jbRoot, !jbRoot.isEmpty {
            return (jbRoot as NSString).appendingPathComponent("Library/LaunchDaemons")
        }
        // 回退
        return "/var/jb/Library/LaunchDaemons"
    }

    /// plist 文件完整路径
    var daemonPlistPath: String {
        guard let dir = launchDaemonDir else { return "" }
        return (dir as NSString).appendingPathComponent("com.aireverse.rootlaunch.plist")
    }

    /// 执行 LaunchDaemon 安装并启动
    /// - Returns: 包含操作日志的多行字符串
    func setupDaemon() -> String {
        let binaryPath = appBinaryPath
        var log = [String]()
        log.append("▸ 检测二进制路径: \(binaryPath)")

        let shellPath = rootShellPath
        let rt = JailbreakRuntime.shared

        // 0. 先检查二进制是否存在
        var binExists = false
        binaryPath.withCString { ptr in binExists = access(ptr, F_OK) == 0 }
        if !binExists {
            return "❌ 二进制路径不存在: \(binaryPath)\n请先用 TrollStore 安装 App"
        }
        log.append("✓ 二进制路径已确认")

        // 1. 创建目录
        guard let dir = launchDaemonDir else {
            return "❌ 无法确定 LaunchDaemons 目录路径"
        }
        let createDirCmd = "mkdir -p \(shQuote(dir))"
        let (createCode, createOut) = rt.executeCommand(createDirCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        if createCode != 0 {
            // mobile 用户无权限创建目录，提供手动命令
            log.append("⚠️ 自动创建目录失败（mobile 权限不足）")
            log.append("")
            log.append("📋 请在 NewTerm 中执行以下命令手动配置：")
            log.append("")
            log.append("=== 步骤 1：创建目录 ===")
            log.append("mkdir -p \(dir)")
            log.append("")
            log.append("=== 步骤 2：创建 plist 配置文件 ===")
            log.append("cat > \(shQuote(daemonPlistPath)) << 'PLISTEOF'")
            log.append(daemonPlistContent(binaryPath: binaryPath))
            log.append("PLISTEOF")
            log.append("")
            log.append("=== 步骤 3：设置权限并加载 ===")
            log.append("chown root:wheel \(shQuote(daemonPlistPath))")
            log.append("launchctl load \(shQuote(daemonPlistPath))")
            log.append("launchctl start \(Self.daemonLabel)")
            log.append("")
            log.append("🔑 root shell: \(shellPath)")
            return log.joined(separator: "\n")
        }
        log.append("✓ 目录已创建: \(dir)")

        // 2. 写入 plist
        let plistPath = daemonPlistPath
        let plistContent = daemonPlistContent(binaryPath: binaryPath)
        do {
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
            log.append("✓ plist 已写入: \(plistPath)")
        } catch {
            return "❌ 写入 plist 失败: \(error.localizedDescription)"
        }

        // 3. 设置权限 chown root:wheel
        let chownCmd = "chown root:wheel \(shQuote(plistPath))"
        let (chownCode, _) = rt.executeCommand(chownCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        if chownCode != 0 {
            log.append("⚠️ chown 失败（权限不足），尝试继续")
        } else {
            log.append("✓ 权限已设置（root:wheel）")
        }

        // 4. 停止已有守护
        let unloadCmd = "launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || launchctl unload /Library/LaunchDaemons/\(Self.daemonLabel).plist 2>/dev/null"
        let (unloadCode, _) = rt.executeCommand(unloadCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        if unloadCode == 0 {
            log.append("✓ 旧守护已停止")
        }

        // 5. 加载守护（两种方式都尝试）
        let loadMethods = [
            "launchctl bootout system/\(Self.daemonLabel) && launchctl bootstrap system /usr/libexec/getent.plist && launchctl load \(shQuote(plistPath))",
            "launchctl load -w \(shQuote(plistPath))",
            "launchctl load \(shQuote(plistPath))"
        ]
        var loaded = false
        for cmd in loadMethods {
            let (loadCode, _) = rt.executeCommand(cmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
            if loadCode == 0 {
                log.append("✓ LaunchDaemon 已加载（方法: \(cmd.split(separator: " ").first ?? "?")）")
                loaded = true
                break
            }
        }
        if !loaded {
            log.append("⚠️ 自动加载失败，请手动运行: launchctl load \(plistPath)")
            return log.joined(separator: "\n")
        }

        // 6. 启动守护
        let startCmd = "launchctl start \(Self.daemonLabel)"
        let (startCode, _) = rt.executeCommand(startCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        if startCode == 0 {
            log.append("✓ LaunchDaemon 已启动（以 root 身份）")
        } else {
            log.append("⚠️ 启动失败，守护可能已在运行")
        }

        log.append("")
        log.append("🎯 root 权限已就绪！")
        log.append("📋 桌面图标点击唤起 UI，后台守护进程以 root 身份运行")
        log.append("🔑 root shell: \(shellPath)")

        return log.joined(separator: "\n")
    }

    /// 停止并卸载 LaunchDaemon
    func teardownDaemon() -> String {
        var log = [String]()
        let rt = JailbreakRuntime.shared

        // 停止
        let stopCmd = "launchctl stop \(Self.daemonLabel) 2>/dev/null; launchctl bootout system/\(Self.daemonLabel) 2>/dev/null"
        let (stopCode, _) = rt.executeCommand(stopCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        log.append(stopCode == 0 ? "✓ 守护进程已停止" : "⚠️ 停止失败")

        // 卸载
        let unloadCmd = "launchctl unload \(shQuote(daemonPlistPath)) 2>/dev/null"
        let (unloadCode, _) = rt.executeCommand(unloadCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        log.append(unloadCode == 0 ? "✓ 守护进程已卸载" : "⚠️ 卸载失败")

        // 移除 plist
        let rmCmd = "rm -f \(shQuote(daemonPlistPath))"
        let (rmCode, _) = rt.executeCommand(rmCmd, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        log.append(rmCode == 0 ? "✓ 配置文件已删除" : "⚠️ 删除失败")

        return log.joined(separator: "\n")
    }

    /// 检查守护进程当前状态
    func daemonStatus() -> (label: String, isRunning: Bool, details: [String]) {
        let rt = JailbreakRuntime.shared
        var details = [String]()
        details.append("二进制路径: \(appBinaryPath)")

        // 检查 plist 是否存在
        var plistExists = false
        daemonPlistPath.withCString { ptr in plistExists = access(ptr, F_OK) == 0 }
        let plistText = plistExists ? "存在" : "不存在"
        details.append("plist: \(plistText)")

        // 检查进程是否运行（用 ps aux 查找 AIReverse）
        let (psCode, psOut) = rt.executeCommand(
            "ps aux 2>/dev/null | grep -i aireverse | grep -v grep",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        if psCode == 0 && !psOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details.append("进程: 正在运行（root）")
            return (label: "守护中", isRunning: true, details: details)
        }

        // 检查 launchctl 状态
        let (statusCode, statusOut) = rt.executeCommand(
            "launchctl list 2>/dev/null | grep -i aireverse",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        if statusCode == 0 {
            details.append(statusOut.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        details.append("进程: 未运行")
        let userText = geteuid() == 0 ? "root" : "mobile(euid=\(geteuid()))"
        details.append("运行用户: \(userText)")
        return (label: "未运行", isRunning: false, details: details)
    }

    // MARK: - URL Scheme

    static let urlScheme = "aireverse"
    static let rootURL = "\(urlScheme)://root"

    // MARK: - 工具

    private func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}