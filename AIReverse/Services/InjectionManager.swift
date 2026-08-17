import Foundation
import Combine
import Darwin

enum InjectionError: LocalizedError {
    case notJailbroken
    case dylibNotFound(String)
    case targetNotFound(String)
    case failed(String)
    case noRootAccess(String)

    var errorDescription: String? {
        switch self {
        case .notJailbroken:
            return "未检测到越狱环境"
        case .dylibNotFound(let path):
            return "dylib 文件不存在: \(path)"
        case .targetNotFound(let path):
            return "目标路径不存在: \(path)"
        case .failed(let msg):
            return "注入失败：\(msg)"
        case .noRootAccess(let detail):
            return "无 root 权限\n\(detail)\n\n请在 NewTerm 中执行:\n1. su root\n2. export DYLD_INSERT_LIBRARIES=/var/jb/usr/lib/ellekit/ellekit.dylib\n3. /var/mobile/root_service\n\n或配置 LaunchDaemon 守护进程以 root 身份运行"
        }
    }
}

struct InjectionRecord: Identifiable {
    let id = UUID()
    let appBundleID: String
    let appName: String
    let dylibName: String
    let appBundlePath: String
    let method: String
    let status: String
    let message: String
    let date = Date()
}

/// 插件注入管理器 — 适配 Relaxin / Rootless 越狱环境
///
/// 注入方式：
/// 1. 复制 dylib 到目标 App bundle 内
/// 2. 用 ldid 重签名 dylib
/// 3. 优先 insert_dylib 修改 Mach-O（LC_LOAD_DYLIB），失败则改 Info.plist DYLD_INSERT_LIBRARIES
/// 4. 用 ldid 重签名主二进制
/// 5. 清理 _CodeSignature
/// 6. uicache 刷新图标缓存
///
/// 环境适配：
/// - 通过 runAsRoot() 自动处理 root 提权（直接执行 / su 提权 / RootService 回退）
/// - PATH 覆盖 Procursus / Rootless 工具路径
/// - 所有命令捕获 stdout+stderr，失败时显示具体错误
///
/// root 提权优先级：
///   1. 若已以 root 身份运行（LaunchDaemon）→ 直接执行
///   2. 否则尝试 /var/jb/opt/procursus/bin/su -c 提权
///   3. 否则通过 RootService socket 转发（需 root_service 已启动）
///   4. 全部失败 → 明确报错
final class InjectionManager: ObservableObject {
    static let shared = InjectionManager()
    @Published var recentInjections: [InjectionRecord] = []
    private let rt = JailbreakRuntime.shared
    private init() {}

    /// 越狱工具 PATH（覆盖 Procursus / Rootless 路径）
    private let jbPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin"

    /// 提权后的命令执行：
    ///   - 若 isRoot → 直接执行
    ///   - 否则尝试 su 提权，再回退 RootService
    private func runAsRoot(_ command: String,
                           environment: [String: String] = [:]) -> (Int32, String) {
        if rt.isRoot {
            return rt.executeCommand(command, environment: environment)
        }

        // 尝试 1：su 提权（Procursus 的 su 通常允许密码免）
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        let suPaths = ["/var/jb/opt/procursus/bin/su", "/bin/su", "su"]
        for suPath in suPaths {
            var exists = false
            suPath.withCString { ptr in exists = access(ptr, F_OK) == 0 }
            guard exists else { continue }

            let suCmd = "\(suPath) root -c '\(escaped)'"
            let (code, out) = rt.executeCommand(suCmd, environment: environment)
            if code == 0 {
                return (code, out)
            }
            // su 失败（密码错误等），继续尝试下一个路径
        }

        // 尝试 2：RootService socket（CMD_SHELL 转发）
        do {
            let rsc = RootServiceClient.shared
            let svcCmd = "CMD_SHELL \(command.replacingOccurrences(of: "\n", with: " "))"
            let result = try rsc.execute(svcCmd)
            // RootService 返回纯输出文本，exit code 未知，假设成功
            return (0, result)
        } catch {
            let errMsg = error.localizedDescription
            return (-1, "无法获取 root 权限\nsu 提权失败，RootService 不可用: \(errMsg)")
        }
    }

    @discardableResult
    func injectDylib(at dylibPath: String, into app: InstalledApp, targetDir: String = "") throws -> String {
        guard rt.isJailbroken else {
            RuntimeLogger.shared.error("注入", "未检测到越狱环境，无法注入 \(dylibPath) 到 \(app.displayName)")
            throw InjectionError.notJailbroken
        }

        // ── 预检 ──
        let dylibName = (dylibPath as NSString).lastPathComponent

        // 确认 dylib 源文件存在
        var srcExists = false
        dylibPath.withCString { ptr in srcExists = access(ptr, F_OK) == 0 }
        if !srcExists {
            RuntimeLogger.shared.error("注入", "dylib 不存在: \(dylibPath)")
            throw InjectionError.dylibNotFound(dylibPath)
        }

        // 确认目标 App bundle 存在
        let appBundle = app.bundlePath

        var bundleExists = false
        appBundle.withCString { ptr in bundleExists = access(ptr, F_OK) == 0 }
        if !bundleExists {
            RuntimeLogger.shared.error("注入", "目标 App bundle 不存在: \(appBundle)")
            throw InjectionError.targetNotFound(appBundle)
        }

        // 定位主二进制（优先 Info.plist CFBundleExecutable，回退 bundle 名去 .app）
        let mainBinary = locateMainBinary(in: appBundle)
        var binExists = false
        mainBinary.withCString { ptr in binExists = access(ptr, F_OK) == 0 }
        if !binExists {
            RuntimeLogger.shared.error("注入", "目标主二进制不存在: \(mainBinary)")
            throw InjectionError.targetNotFound(mainBinary)
        }

        // 确认 root 权限可用（直接 root / su / RootService 任一即可）
        let (suCheckCode, suCheckOut) = runAsRoot("id", environment: ["PATH": jbPath])
        if suCheckCode != 0 {
            RuntimeLogger.shared.error("注入", "root 权限检查失败: \(suCheckOut)")
            throw InjectionError.noRootAccess("需要 root 权限写入 App bundle，但无法提权")
        }

        do {
            let (log, method) = try doInject(
                dylibPath: dylibPath,
                appBundle: appBundle,
                mainBinary: mainBinary,
                dylibName: dylibName
            )

            let record = InjectionRecord(
                appBundleID: app.bundleID,
                appName: app.displayName,
                dylibName: dylibName,
                appBundlePath: appBundle,
                method: method,
                status: "注入成功",
                message: "已通过 \(method) 注入 \(dylibName) 到 \(app.displayName)\n重启应用后生效。"
            )
            recentInjections.insert(record, at: 0)
            RuntimeLogger.shared.info("注入", "注入成功：\(dylibName) → \(app.displayName)（\(method)）")

            return log
        } catch {
            RuntimeLogger.shared.error("注入", "注入失败：\(error.localizedDescription)")
            throw error
        }
    }

    /// 定位 App bundle 的主二进制：
    /// 1. Info.plist CFBundleExecutable（最准确）
    /// 2. bundle 名去掉 .app 后缀（如 Foo.app → Foo）
    /// 3. bundle 名原样（带 .app）
    private func locateMainBinary(in appBundle: String) -> String {
        let infoPlist = (appBundle as NSString).appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOfFile: infoPlist),
           let exec = dict["CFBundleExecutable"] as? String, !exec.isEmpty {
            let candidate = (appBundle as NSString).appendingPathComponent(exec)
            var exists = false
            candidate.withCString { ptr in exists = access(ptr, F_OK) == 0 }
            if exists { return candidate }
        }

        let bundleName = (appBundle as NSString).lastPathComponent
        var execName = bundleName
        if execName.hasSuffix(".app") {
            execName = String(execName.dropLast(4))
        }
        let trimmed = (appBundle as NSString).appendingPathComponent(execName)
        var trimmedExists = false
        trimmed.withCString { ptr in trimmedExists = access(ptr, F_OK) == 0 }
        if trimmedExists { return trimmed }

        return (appBundle as NSString).appendingPathComponent(bundleName)
    }

    private func doInject(
        dylibPath: String,
        appBundle: String,
        mainBinary: String,
        dylibName: String
    ) throws -> (log: String, method: String) {
        var log = [String]()
        var method = "DYLD_INSERT_LIBRARIES"
        let destDylib = (appBundle as NSString).appendingPathComponent(dylibName)
        let infoPlist = (appBundle as NSString).appendingPathComponent("Info.plist")
        let codeSignDir = (appBundle as NSString).appendingPathComponent("_CodeSignature")

        // ── 1. 复制 dylib 到目标 App bundle ──
        log.append("▸ 复制 dylib...")
        let (cpCode, cpOut) = runAsRoot("cp -f '\(dylibPath)' '\(destDylib)'", environment: ["PATH": jbPath])
        if cpCode != 0 {
            let err = cpOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未知错误" : cpOut
            throw InjectionError.failed("复制 dylib 失败:\n\(err)")
        }
        runAsRoot("chmod 755 '\(destDylib)'", environment: ["PATH": jbPath])
        log.append("✓ dylib 已复制")

        // ── 2. ldid 重签名 dylib ──
        log.append("▸ ldid 重签名 dylib...")
        let selfEnts = Bundle.main.path(forResource: "AIReverse", ofType: "entitlements") ?? ""
        let ldidDylibCmd: String
        if !selfEnts.isEmpty {
            ldidDylibCmd = "ldid -S'\(selfEnts)' '\(destDylib)'"
        } else {
            ldidDylibCmd = "ldid -S '\(destDylib)'"
        }
        let (ldid1Code, ldid1Out) = runAsRoot(ldidDylibCmd, environment: ["PATH": jbPath])
        if ldid1Code != 0 {
            let err = ldid1Out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未知错误" : ldid1Out
            log.append("⚠️ ldid 签名 dylib 失败: \(err)")
        } else {
            log.append("✓ dylib 签名完成")
        }

        // ── 3. 注入方式：Mach-O 修改 ──
        let dylibInstallPath = "@executable_path/\(dylibName)"

        // 3a. 尝试 insert_dylib（最可靠）
        log.append("▸ 尝试 insert_dylib...")
        let (insertCode, insertOut) = runAsRoot(
            "insert_dylib \(dylibInstallPath) '\(mainBinary)' '\(mainBinary).injected' && mv '\(mainBinary).injected' '\(mainBinary)'",
            environment: ["PATH": jbPath]
        )
        if insertCode == 0 {
            method = "LC_LOAD_DYLIB (insert_dylib)"
            log.append("✓ insert_dylib 成功")
        } else {
            let insertErr = insertOut.trimmingCharacters(in: .whitespacesAndNewlines)
            log.append("✗ insert_dylib 失败: \(insertErr.isEmpty ? "命令不存在或执行失败" : insertErr)")

            // 3b. 尝试 jtool
            log.append("▸ 尝试 jtool...")
            let (jtoolCode, jtoolOut) = runAsRoot(
                "jtool --inplace --LC_LOAD_DYLIB=\(dylibInstallPath) '\(mainBinary)'",
                environment: ["PATH": jbPath]
            )
            if jtoolCode == 0 {
                method = "LC_LOAD_DYLIB (jtool)"
                log.append("✓ jtool 成功")
            } else {
                let jtoolErr = jtoolOut.trimmingCharacters(in: .whitespacesAndNewlines)
                log.append("✗ jtool 失败: \(jtoolErr.isEmpty ? "命令不存在或执行失败" : jtoolErr)")

                // 3c. 后备：DYLD_INSERT_LIBRARIES（修改 Info.plist）
                log.append("▸ 使用 DYLD_INSERT_LIBRARIES（修改 Info.plist）...")
                let setCmd = "/usr/libexec/PlistBuddy -c 'Set :DYLD_INSERT_LIBRARIES \(dylibInstallPath)' '\(infoPlist)'"
                let (setCode, setOut) = runAsRoot(setCmd, environment: ["PATH": jbPath])
                if setCode != 0 {
                    let addCmd = "/usr/libexec/PlistBuddy -c 'Add :DYLD_INSERT_LIBRARIES string \(dylibInstallPath)' '\(infoPlist)'"
                    let (addCode, addOut) = runAsRoot(addCmd, environment: ["PATH": jbPath])
                    if addCode != 0 {
                        let err = addOut.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw InjectionError.failed("修改 Info.plist 失败:\n\(err.isEmpty ? "未知错误" : err)")
                    }
                }
                log.append("✓ Info.plist 已修改")
            }
        }

        // ── 4. ldid 重签名主二进制 ──
        log.append("▸ 重签名主二进制...")
        let entFile = (appBundle as NSString).appendingPathComponent(".AIReverse_ent.plist")
        let (entCode, entOut) = runAsRoot("ldid -e '\(mainBinary)' > '\(entFile)' 2>&1", environment: ["PATH": jbPath])
        if entCode == 0 {
            let (signCode, signOut) = runAsRoot("ldid -S'\(entFile)' '\(mainBinary)' 2>&1", environment: ["PATH": jbPath])
            if signCode == 0 {
                log.append("✓ 主二进制签名完成")
            } else {
                let err = signOut.trimmingCharacters(in: .whitespacesAndNewlines)
                log.append("⚠️ 主二进制签名失败: \(err)")
            }
        } else {
            let err = entOut.trimmingCharacters(in: .whitespacesAndNewlines)
            log.append("⚠️ 提取 entitlements 失败: \(err)")
            let (signCode2, signOut2) = runAsRoot("ldid -S '\(mainBinary)' 2>&1", environment: ["PATH": jbPath])
            if signCode2 == 0 {
                log.append("✓ 主二进制签名完成（无原 entitlements）")
            } else {
                let err2 = signOut2.trimmingCharacters(in: .whitespacesAndNewlines)
                log.append("⚠️ 主二进制签名失败: \(err2)")
            }
        }
        runAsRoot("rm -f '\(entFile)'", environment: ["PATH": jbPath])

        // ── 5. 清理 _CodeSignature ──
        let (_, rmOut) = runAsRoot("rm -rf '\(codeSignDir)' 2>/dev/null", environment: ["PATH": jbPath])
        if rmOut.contains("Permission") {
            log.append("⚠️ _CodeSignature 删除失败（权限不足）")
        } else {
            log.append("✓ _CodeSignature 已清理")
        }

        // ── 6. uicache 刷新 ──
        log.append("▸ 刷新图标缓存...")
        let (uicacheCode, uicacheOut) = runAsRoot("uicache -p '\(appBundle)' 2>&1", environment: ["PATH": jbPath])
        if uicacheCode == 0 {
            log.append("✓ uicache 已刷新")
        } else {
            let err = uicacheOut.trimmingCharacters(in: .whitespacesAndNewlines)
            log.append("⚠️ uicache 刷新失败: \(err.isEmpty ? "命令不可用" : err)")
        }

        log.append("")
        log.append("🎉 注入完成！重启目标应用后生效。")
        return (log: log.joined(separator: "\n"), method: method)
    }
}