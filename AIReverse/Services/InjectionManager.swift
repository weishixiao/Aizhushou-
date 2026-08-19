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
            return "未检测到越狱环境\n\n请确认设备已越狱。如确认已越狱但检测失败，可在注入页面开启「强制越狱模式」开关后重试。"
        case .dylibNotFound(let path):
            return "dylib 文件不存在: \(path)\n\n请检查上传的文件是否完整。"
        case .targetNotFound(let path):
            return "目标应用路径不存在: \(path)\n\n请确认目标应用已安装且未被卸载。"
        case .failed(let msg):
            return "注入失败：\(msg)"
        case .noRootAccess(let detail):
            return "无法获取 root 权限\n\n\(detail)\n\n解决方案：\n1. 在 NewTerm 中执行 su 切换到 root（默认密码 alpine）\n2. 确认 /var/jb/bin/su 存在且密码为 alpine\n3. 或启动 RootService（需 root_service 以 root 运行）"
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
        let suPaths = [
            "/var/jb/bin/su",               // rootless (palera1n/Dopamine)
            "/var/jb/usr/bin/su",           // rootless 备选
            "/var/jb/opt/procursus/bin/su",  // Procursus
            "/usr/bin/su",                  // 传统越狱
            "/bin/su",                      // 传统越狱备选
        ]
        for suPath in suPaths {
            var exists = false
            suPath.withCString { ptr in exists = access(ptr, F_OK) == 0 }
            guard exists else { continue }

            let suCmd = "\(suPath) root -c '\(escaped)'"
            // 超时保护：su 若需密码会阻塞等待 stdin，5 秒无响应则跳过
            let result = executeWithTimeout(command: suCmd, environment: environment, timeoutSeconds: 5)
            if result.0 == 0 {
                return result
            }
            RuntimeLogger.shared.warning("注入", "su 路径 \(suPath) 失败（可能需密码或超时），继续尝试…")
            // su 失败（密码错误/超时），继续尝试下一个路径
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

    /// 带超时的命令执行（防止 su 密码提示阻塞）
    private func executeWithTimeout(command: String,
                                     environment: [String: String],
                                     timeoutSeconds: UInt64) -> (Int32, String) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int32, String) = (-1, "超时")
        let workTask = Task.detached {
            let r = self.rt.executeCommand(command, environment: environment)
            result = r
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .seconds(Int(timeoutSeconds))
        if semaphore.wait(timeout: timeout) == .timedOut {
            workTask.cancel()
            RuntimeLogger.shared.warning("注入", "命令执行超过 \(timeoutSeconds)s，已取消: \(command.prefix(40))…")
            return (-1, "命令执行超时（\(timeoutSeconds) 秒，可能需输入密码）")
        }
        return result
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

        // 环境工具探测（诊断用）
        let probeNames = ["ldid", "insert_dylib", "jtool", "uicache", "dpkg-deb", "plutil"]
        let probeResult = probeNames
            .map { "\($0)=\(findTool($0) != nil ? "有" : "无")" }
            .joined(separator: "，")
        RuntimeLogger.shared.info("注入", "环境工具探测：\(probeResult)")

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

    /// 在 PATH 中查找工具是否存在（App 进程内探测，用于诊断日志）
    private func findTool(_ name: String) -> String? {
        for dir in jbPath.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            var exists = false
            candidate.withCString { ptr in exists = access(ptr, X_OK) == 0 }
            if exists { return candidate }
        }
        return nil
    }

    /// 写回补丁后的二进制：优先直接写，失败则经 root 复制覆盖
    private func writeBinary(_ data: Data, to path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("patched_bin_\(UUID().uuidString)")
            do {
                try data.write(to: URL(fileURLWithPath: tmp))
            } catch {
                throw InjectionError.failed("写临时补丁文件失败:\n\(error.localizedDescription)")
            }
            let (code, out) = runAsRoot("cp -f '\(tmp)' '\(path)'", environment: ["PATH": jbPath])
            runAsRoot("rm -f '\(tmp)'", environment: ["PATH": jbPath])
            if code != 0 {
                throw InjectionError.failed("写回补丁后二进制失败:\n\(out)")
            }
        }
        runAsRoot("chmod 755 '\(path)'", environment: ["PATH": jbPath])
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
        var injected = false

        // 3a. 纯 Swift 注入（自包含，不依赖外部 insert_dylib / jtool）
        log.append("▸ 纯 Swift 注入 LC_LOAD_DYLIB...")
        do {
            var original: Data
            do {
                original = try Data(contentsOf: URL(fileURLWithPath: mainBinary))
            } catch {
                // App 进程无权限直接读 → root 复制副本再读
                let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("orig_bin_\(UUID().uuidString)")
                let (rc, rout) = runAsRoot("cp -f '\(mainBinary)' '\(tmp)'", environment: ["PATH": jbPath])
                guard rc == 0 else {
                    throw InjectionError.failed("读取目标二进制失败:\n\(rout)")
                }
                original = try Data(contentsOf: URL(fileURLWithPath: tmp))
                runAsRoot("rm -f '\(tmp)'", environment: ["PATH": jbPath])
            }

            if try MachOEditor.containsDylib(dylibInstallPath, in: original) {
                method = "LC_LOAD_DYLIB (纯 Swift)"
                log.append("✓ 已检测到目标 dylib，无需重复注入")
                injected = true
            } else {
                let patched = try MachOEditor.patchData(original, dylibPath: dylibInstallPath)
                try writeBinary(patched, to: mainBinary)
                method = "LC_LOAD_DYLIB (纯 Swift)"
                log.append("✓ 纯 Swift 注入成功")
                injected = true
            }
        } catch {
            log.append("✗ 纯 Swift 注入失败: \(error.localizedDescription)")
        }

        if !injected {
            // 3b. 尝试 insert_dylib（外部工具回退）
            log.append("▸ 尝试 insert_dylib...")
            let (insertCode, insertOut) = runAsRoot(
                "insert_dylib \(dylibInstallPath) '\(mainBinary)' '\(mainBinary).injected' && mv '\(mainBinary).injected' '\(mainBinary)'",
                environment: ["PATH": jbPath]
            )
            if insertCode == 0 {
                method = "LC_LOAD_DYLIB (insert_dylib)"
                log.append("✓ insert_dylib 成功")
                injected = true
            } else {
                let insertErr = insertOut.trimmingCharacters(in: .whitespacesAndNewlines)
                log.append("✗ insert_dylib 失败: \(insertErr.isEmpty ? "命令不存在或执行失败" : insertErr)")

                // 3c. 尝试 jtool
                log.append("▸ 尝试 jtool...")
                let (jtoolCode, jtoolOut) = runAsRoot(
                    "jtool --inplace --LC_LOAD_DYLIB=\(dylibInstallPath) '\(mainBinary)'",
                    environment: ["PATH": jbPath]
                )
                if jtoolCode == 0 {
                    method = "LC_LOAD_DYLIB (jtool)"
                    log.append("✓ jtool 成功")
                    injected = true
                } else {
                    let jtoolErr = jtoolOut.trimmingCharacters(in: .whitespacesAndNewlines)
                    log.append("✗ jtool 失败: \(jtoolErr.isEmpty ? "命令不存在或执行失败" : jtoolErr)")

                    // 3d. 后备：DYLD_INSERT_LIBRARIES（修改 Info.plist）
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
                    method = "DYLD_INSERT_LIBRARIES"
                }
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