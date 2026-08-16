import Foundation
import Combine

enum InjectionError: LocalizedError {
    case notRoot
    case notJailbroken
    case dylibNotFound(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notRoot: return "当前非 root 权限，请先配置 LaunchDaemon 守护进程获取 root 权限"
        case .notJailbroken: return "未检测到越狱环境"
        case .dylibNotFound(let path): return "dylib 文件不存在: \(path)"
        case .failed(let msg): return "注入失败：\(msg)"
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

/// 插件注入管理器 — 适配 Relaxin/Rootless 越狱环境
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
/// - 使用 JailbreakRuntime.executeCommand()，自动选择正确的 root shell（/var/jb/opt/procursus/bin/sh）
/// - PATH 覆盖 /var/jb/usr/bin 等越狱工具路径
/// - 所有命令输出捕获并用于诊断
final class InjectionManager: ObservableObject {
    static let shared = InjectionManager()
    @Published var recentInjections: [InjectionRecord] = []
    private let rt = JailbreakRuntime.shared
    private init() {}

    /// 越狱工具 PATH（覆盖 Procursus / Rootless 路径）
    private let jbPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin"

    /// 解析真实路径：在 rootless 环境下，通过 jbroot 前缀映射到真实路径
    private func resolvePath(_ path: String) -> String {
        let (code, jbRoot) = rt.executeCommand("jbroot 2>/dev/null || echo /var/jb", environment: ["PATH": jbPath])
        if code == 0, let root = jbRoot.split(separator: "\n").first, !root.isEmpty, root != "/var/jb" {
            // rootless 环境：如果路径以 /var/mobile 开头，尝试用 jbroot 前缀
            if path.hasPrefix("/var/mobile") {
                return (root as NSString).appendingPathComponent(String(path.dropFirst(11)))
            }
            if path.hasPrefix("/var/containers") {
                return (root as NSString).appendingPathComponent(String(path.dropFirst(13)))
            }
        }
        return path
    }

    @discardableResult
    func injectDylib(at dylibPath: String, into app: InstalledApp, targetDir: String = "") throws -> String {
        guard rt.isJailbroken else {
            throw InjectionError.notJailbroken
        }
        guard rt.isRoot else {
            throw InjectionError.notRoot
        }

        // ── 预检 ──
        let dylibName = (dylibPath as NSString).lastPathComponent

        // 0. 确认 dylib 源文件存在
        var srcExists = false
        dylibPath.withCString { ptr in srcExists = access(ptr, F_OK) == 0 }
        if !srcExists {
            throw InjectionError.dylibNotFound(dylibPath)
        }

        // 解析真实路径（rootless 适配）
        let realDylibPath = resolvePath(dylibPath)
        let realAppBundle = resolvePath(app.bundlePath)

        let binaryName = (realAppBundle as NSString).lastPathComponent
        let mainBinary = (realAppBundle as NSString).appendingPathComponent(binaryName)
        let destDylib = (realAppBundle as NSString).appendingPathComponent(dylibName)
        let infoPlist = (realAppBundle as NSString).appendingPathComponent("Info.plist")
        let codeSignDir = (realAppBundle as NSString).appendingPathComponent("_CodeSignature")

        // 0.5 确认目标 App bundle 和主二进制存在
        var binExists = false
        mainBinary.withCString { ptr in binExists = access(ptr, F_OK) == 0 }
        if !binExists {
            throw InjectionError.failed("目标 App 主二进制不存在: \(mainBinary)\n原始路径: \(app.bundlePath)")
        }

        var bundleExists = false
        realAppBundle.withCString { ptr in bundleExists = access(ptr, F_OK) == 0 }
        if !bundleExists {
            throw InjectionError.failed("目标 App bundle 不可写: \(realAppBundle)")
        }

        // 检查 ldid 是否可用
        let (ldidCheckCode, _) = rt.executeCommand("which ldid", environment: ["PATH": jbPath])
        if ldidCheckCode != 0 {
            throw InjectionError.failed("ldid 不可用。请通过 Cydia/Sileo 安装 ldid 或 Procursus 工具集")
        }

        let (log, method) = try doInject(
            realDylibPath: realDylibPath,
            destDylib: destDylib,
            mainBinary: mainBinary,
            infoPlist: infoPlist,
            codeSignDir: codeSignDir,
            dylibName: dylibName
        )

        let record = InjectionRecord(
            appBundleID: app.bundleID,
            appName: app.displayName,
            dylibName: dylibName,
            appBundlePath: realAppBundle,
            method: method,
            status: "注入成功",
            message: "已通过 \(method) 注入 \(dylibName) 到 \(app.displayName)\n重启应用后生效。"
        )
        recentInjections.insert(record, at: 0)

        return log
    }

    private func doInject(
        realDylibPath: String,
        destDylib: String,
        mainBinary: String,
        infoPlist: String,
        codeSignDir: String,
        dylibName: String
    ) throws -> (log: String, method: String) {
        var log = [String]()
        var method = "DYLD_INSERT_LIBRARIES"

        // ── 1. 复制 dylib 到目标 App bundle ──
        log.append("▸ 复制 dylib: \(realDylibPath) → \(destDylib)")
        let cpCmd = "cp -f '\(realDylibPath)' '\(destDylib)'"
        let (cpCode, cpOut) = rt.executeCommand(cpCmd, environment: ["PATH": jbPath])
        if cpCode != 0 {
            let err = cpOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未知错误" : cpOut
            throw InjectionError.failed("复制 dylib 失败:\n\(err)\n命令: \(cpCmd)\n\n可能的原因：\n• 目标路径不可写（确认 LaunchDaemon 守护进程已启动）\n• 路径冲突或权限不足\n• dylib 源文件不可读")
        }
        rt.executeCommand("chmod 755 '\(destDylib)'", environment: ["PATH": jbPath])
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
        let (ldid1Code, ldid1Out) = rt.executeCommand(ldidDylibCmd, environment: ["PATH": jbPath])
        if ldid1Code != 0 {
            let err = ldid1Out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未知错误" : ldid1Out
            log.append("⚠️ ldid 签名 dylib 失败: \(err)")
        } else {
            log.append("✓ dylib 签名完成")
        }

        // ── 3. 注入方式 ──
        let dylibInstallPath = "@executable_path/\(dylibName)"

        // 3a. 尝试 insert_dylib
        log.append("▸ 尝试 insert_dylib 修改 Mach-O...")
        var (insertCode, insertOut) = rt.executeCommand(
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
            log.append("▸ 尝试 jtool 修改 Mach-O...")
            var (jtoolCode, jtoolOut) = rt.executeCommand(
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
                let plistCmd = "/usr/libexec/PlistBuddy -c 'Set :DYLD_INSERT_LIBRARIES \(dylibInstallPath)' '\(infoPlist)'"
                let (plistCode, plistOut) = rt.executeCommand(plistCmd, environment: ["PATH": jbPath])
                if plistCode != 0 {
                    // 尝试 Add（key 不存在时）
                    let addCmd = "/usr/libexec/PlistBuddy -c 'Add :DYLD_INSERT_LIBRARIES string \(dylibInstallPath)' '\(infoPlist)'"
                    let (addCode, addOut) = rt.executeCommand(addCmd, environment: ["PATH": jbPath])
                    if addCode != 0 {
                        let err = addOut.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw InjectionError.failed("修改 Info.plist 失败:\n\(err)\n无法注入 dylib")
                    }
                }
                log.append("✓ Info.plist 已修改")
            }
        }

        // ── 4. ldid 重签名主二进制 ──
        log.append("▸ 提取原 entitlements 并重签名主二进制...")
        let entFile = (realAppBundle as NSString).appendingPathComponent(".AIReverse_ent.plist")
        let (entCode, entOut) = rt.executeCommand("ldid -e '\(mainBinary)' > '\(entFile)' 2>&1", environment: ["PATH": jbPath])
        if entCode == 0 {
            let (signCode, signOut) = rt.executeCommand("ldid -S'\(entFile)' '\(mainBinary)' 2>&1", environment: ["PATH": jbPath])
            if signCode == 0 {
                log.append("✓ 主二进制签名完成")
            } else {
                let err = signOut.trimmingCharacters(in: .whitespacesAndNewlines)
                log.append("⚠️ 主二进制签名失败: \(err.isEmpty ? "未知" : err)")
            }
        } else {
            let err = entOut.trimmingCharacters(in: .whitespacesAndNewlines)
            log.append("⚠️ 提取 entitlements 失败: \(err.isEmpty ? "未知" : err)")
            // 用空 entitlements 重试
            let (signCode2, signOut2) = rt.executeCommand("ldid -S '\(mainBinary)' 2>&1", environment: ["PATH": jbPath])
            if signCode2 == 0 {
                log.append("✓ 主二进制签名完成（无原 entitlements）")
            } else {
                let err2 = signOut2.trimmingCharacters(in: .whitespacesAndNewlines)
                log.append("⚠️ 主二进制签名（空 entitlements）失败: \(err2)")
            }
        }
        rt.executeCommand("rm -f '\(entFile)'", environment: ["PATH": jbPath])

        // ── 5. 清理 _CodeSignature ──
        let (_, rmOut) = rt.executeCommand("rm -rf '\(codeSignDir)' 2>/dev/null", environment: ["PATH": jbPath])
        if rmOut.contains("Permission") { log.append("⚠️ _CodeSignature 删除失败（权限不足）") }
        else { log.append("✓ _CodeSignature 已清理") }

        // ── 6. uicache 刷新 ──
        let (uicacheCode, uicacheOut) = rt.executeCommand("uicache -p '\(realAppBundle)' 2>&1", environment: ["PATH": jbPath])
        if uicacheCode == 0 {
            log.append("✓ uicache 已刷新")
        } else {
            let err = uicacheOut.trimmingCharacters(in: .whitespacesAndNewlines)
            log.append("⚠️ uicache 刷新失败: \(err.isEmpty ? "命令不可用" : err)")
        }

        log.append("")
        log.append("🎉 注入完成！重启应用后生效。")
        return (log: log.joined(separator: "\n"), method: method)
    }
}