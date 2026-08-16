import Foundation
import Combine

/// 注入失败/状态描述
enum InjectionError: LocalizedError {
    case notRoot
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRoot:
            return "当前非 root 权限，无法完成系统级注入。请在越狱/TrollStore 环境中确认。"
        case .failed(let msg):
            return "注入失败：\(msg)"
        }
    }
}

/// 一次注入任务的记录
struct InjectionRecord: Identifiable {
    let id = UUID()
    let appBundleID: String
    let appName: String
    let dylibName: String
    let appBundlePath: String
    let status: String
    let message: String
    let date = Date()
}

/// 插件注入管理器：
/// 模仿 TrollStore 的注入方式，对目标 App 进行：
/// 1. 复制 .dylib 到 App bundle 内
/// 2. 用 ldid 重签名 dylib（确保被系统接受）
/// 3. 修改 Info.plist 添加 DYLD_INSERT_LIBRARIES
/// 4. 用 ldid 重签名主二进制（确保修改后的 App 能运行）
/// 5. 更新 CodeResources
/// 6. uicache 刷新
final class InjectionManager: ObservableObject {
    static let shared = InjectionManager()

    @Published var recentInjections: [InjectionRecord] = []

    private let rt = JailbreakRuntime.shared

    private init() {}

    @discardableResult
    func injectDylib(at dylibPath: String, into app: InstalledApp, targetDir: String = "") throws -> String {
        guard rt.isJailbroken else {
            throw InjectionError.failed("未检测到越狱环境，无法注入")
        }

        let dylibName = (dylibPath as NSString).lastPathComponent
        let appBundle = app.bundlePath
        let binaryName = (appBundle as NSString).lastPathComponent
        let mainBinary = (appBundle as NSString).appendingPathComponent(binaryName)
        let destDylib = (appBundle as NSString).appendingPathComponent(dylibName)
        let infoPlist = (appBundle as NSString).appendingPathComponent("Info.plist")
        let codeResources = (appBundle as NSString).appendingPathComponent("_CodeSignature/CodeResources")

        // 1. 复制 dylib 到目标 App bundle 内
        let (cpCode, _) = spawnAsRoot("cp \(dylibPath) \(destDylib)")
        guard cpCode == 0 else {
            throw InjectionError.failed("复制 dylib 失败，请确认 TrollStore 中已开启所有权限")
        }

        // 2. 用 ldid 重签名 dylib（确保系统接受注入的库）
        // 使用 AIReverse 自身的 entitlements 作为签名权限
        let selfEnts = Bundle.main.path(forResource: "AIReverse", ofType: "entitlements") ?? ""
        if !selfEnts.isEmpty {
            spawnAsRoot("ldid -S\(selfEnts) \(destDylib)")
        } else {
            spawnAsRoot("ldid -S \(destDylib)")
        }

        // 3. 修改 Info.plist，添加 DYLD_INSERT_LIBRARIES
        let plistCmd = "/usr/libexec/PlistBuddy -c 'Add :DYLD_INSERT_LIBRARIES string @executable_path/\(dylibName)' \(infoPlist)"
        let (plistCode, _) = spawnAsRoot(plistCmd)
        if plistCode != 0 {
            let setCmd = "/usr/libexec/PlistBuddy -c 'Set :DYLD_INSERT_LIBRARIES @executable_path/\(dylibName)' \(infoPlist)"
            let (setCode, _) = spawnAsRoot(setCmd)
            if setCode != 0 {
                throw InjectionError.failed("修改 Info.plist 失败")
            }
        }

        // 4. 用 ldid 重签名主二进制（确保修改后的 App 能正常启动）
        // 先用 ldid 提取原始 entitlements，然后重新签名
        let entitlementsFile = (appBundle as NSString).appendingPathComponent(".AIReverse_ent.plist")
        spawnAsRoot("ldid -e \(mainBinary) > \(entitlementsFile)")
        spawnAsRoot("ldid -S\(entitlementsFile) \(mainBinary)")
        spawnAsRoot("rm -f \(entitlementsFile)")

        // 5. 更新 CodeResources（如果存在 _CodeSignature 目录）
        if FileManager.default.fileExists(atPath: codeResources) {
            spawnAsRoot("rm -rf \((appBundle as NSString).appendingPathComponent("_CodeSignature"))")
        }

        // 6. 设置正确权限
        spawnAsRoot("chmod 755 \(destDylib)")
        spawnAsRoot("chown root:wheel \(destDylib)")

        // 7. 刷新图标缓存
        spawnAsRoot("/usr/bin/uicache -p \(appBundle)")

        let record = InjectionRecord(
            appBundleID: app.bundleID,
            appName: app.displayName,
            dylibName: dylibName,
            appBundlePath: appBundle,
            status: "注入成功",
            message: "已将 \(dylibName) 注入 \(app.displayName)\n路径：\(appBundle)\n已用 ldid 重签名，重启应用生效。"
        )
        recentInjections.insert(record, at: 0)
        return record.message
    }

    @discardableResult
    private func spawnAsRoot(_ command: String) -> (Int32, String) {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command)]
        argv.append(nil)
        var env: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin")]
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