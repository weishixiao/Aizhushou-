import Foundation
import Combine

enum InjectionError: LocalizedError {
    case notRoot
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notRoot: return "当前非 root 权限，请在越狱/TrollStore 环境中确认"
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

/// 插件注入管理器
/// 模仿 TrollStore 的注入方式：
/// 1. 复制 dylib 到目标 App bundle 内
/// 2. 用 ldid 重签名 dylib
/// 3. 尝试 jtool 修改 Mach-O（LC_LOAD_DYLIB），失败则用 DYLD_INSERT_LIBRARIES
/// 4. 用 ldid 重签名主二进制
/// 5. 清理 CodeSignature
/// 6. uicache 刷新
final class InjectionManager: ObservableObject {
    static let shared = InjectionManager()
    @Published var recentInjections: [InjectionRecord] = []
    private let rt = JailbreakRuntime.shared
    private init() {}

    @discardableResult
    func injectDylib(at dylibPath: String, into app: InstalledApp, targetDir: String = "") throws -> String {
        guard rt.isJailbroken else {
            throw InjectionError.failed("未检测到越狱环境")
        }

        let dylibName = (dylibPath as NSString).lastPathComponent
        let appBundle = app.bundlePath
        let binaryName = (appBundle as NSString).lastPathComponent
        let mainBinary = (appBundle as NSString).appendingPathComponent(binaryName)
        let destDylib = (appBundle as NSString).appendingPathComponent(dylibName)
        let infoPlist = (appBundle as NSString).appendingPathComponent("Info.plist")
        let codeSignDir = (appBundle as NSString).appendingPathComponent("_CodeSignature")

        // 1. 复制 dylib 到目标 App bundle 内
        let (cpCode, _) = spawn("cp -f \(dylibPath) \(destDylib)")
        guard cpCode == 0 else {
            throw InjectionError.failed("复制 dylib 失败，确认 TrollStore 权限已全开")
        }
        spawn("chmod 755 \(destDylib)")

        // 2. 用 ldid 重签名 dylib
        let selfEnts = Bundle.main.path(forResource: "AIReverse", ofType: "entitlements") ?? ""
        if !selfEnts.isEmpty { spawn("ldid -S\(selfEnts) \(destDylib)") }
        else { spawn("ldid -S \(destDylib)") }

        // 3. 注入方式：优先 insert_dylib（文档推荐方式），次选 jtool，最后 DYLD_INSERT_LIBRARIES
        // 文档推荐路径策略：@executable_path/xxx.dylib（不需要写系统目录）
        let dylibInstallPath = "@executable_path/\(dylibName)"
        var method = "DYLD_INSERT_LIBRARIES"

        // 尝试 insert_dylib（最可靠，专为 Mach-O 注入设计）
        let (insertCode, _) = spawn("insert_dylib \(dylibInstallPath) \(mainBinary) \(mainBinary).injected 2>/dev/null && mv \(mainBinary).injected \(mainBinary)")
        if insertCode == 0 {
            method = "LC_LOAD_DYLIB (insert_dylib)"
        } else {
            // 尝试 jtool
            let (jtoolCode, _) = spawn("jtool --inplace --LC_LOAD_DYLIB=\(dylibInstallPath) \(mainBinary) 2>/dev/null")
            if jtoolCode == 0 {
                method = "LC_LOAD_DYLIB (jtool)"
            } else {
                // 后备：DYLD_INSERT_LIBRARIES（修改 Info.plist）
                let plistCmd = "/usr/libexec/PlistBuddy -c 'Add :DYLD_INSERT_LIBRARIES string @executable_path/\(dylibName)' \(infoPlist)"
                let (plistCode, _) = spawn(plistCmd)
                if plistCode != 0 {
                    let setCmd = "/usr/libexec/PlistBuddy -c 'Set :DYLD_INSERT_LIBRARIES @executable_path/\(dylibName)' \(infoPlist)"
                    let (setCode, _) = spawn(setCmd)
                    if setCode != 0 {
                        throw InjectionError.failed("修改 Info.plist 失败，无法注入")
                    }
                }
            }
        }

        // 4. 用 ldid 重签名主二进制（提取原 entitlements 再签名）
        let entFile = (appBundle as NSString).appendingPathComponent(".AIReverse_ent.plist")
        spawn("ldid -e \(mainBinary) > \(entFile)")
        spawn("ldid -S\(entFile) \(mainBinary)")
        spawn("rm -f \(entFile)")

        // 5. 清理 CodeSignature
        spawn("rm -rf \(codeSignDir) 2>/dev/null")

        // 6. uicache 刷新
        spawn("/usr/bin/uicache -p \(appBundle) 2>/dev/null")

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
        return record.message
    }

    @discardableResult
    private func spawn(_ command: String) -> (Int32, String) {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command)]
        argv.append(nil)
        var env: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/var/jb/usr/bin")]
        env.append(nil)
        let result = posix_spawn(&pid, "/bin/sh", nil, nil, argv, env)
        defer { for a in argv { if let a { free(a) } } }
        defer { for e in env { if let e { free(e) } } }
        guard result == 0 else { return (result, "posix_spawn 失败") }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return ((status >> 8) & 0xFF, "")
    }
}