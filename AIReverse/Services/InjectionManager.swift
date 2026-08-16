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
/// 接受用户上传的 .dylib 文件，直接复制到目标 App 的 bundle 内，
/// 修改 Info.plist 添加 DYLD_INSERT_LIBRARIES，然后 uicache 刷新。
/// 兼容 TrollStore / Relaxin(RootHide) / 传统越狱环境。
final class InjectionManager: ObservableObject {
    static let shared = InjectionManager()

    @Published var recentInjections: [InjectionRecord] = []

    private let rt = JailbreakRuntime.shared

    private init() {}

    /// 注入一个已存在的 .dylib 文件到目标 App 的 bundle 内
    /// - Parameters:
    ///   - dylibPath: 已上传到沙盒的 .dylib 文件路径
    ///   - app: 目标应用
    ///   - targetDir: 忽略（兼容旧接口，不用）
    /// - Returns: 注入结果信息
    @discardableResult
    func injectDylib(at dylibPath: String, into app: InstalledApp, targetDir: String = "") throws -> String {
        guard rt.isJailbroken else {
            throw InjectionError.failed("未检测到越狱环境，无法注入")
        }

        let dylibName = (dylibPath as NSString).lastPathComponent
        let appBundle = app.bundlePath

        // 1. 复制 dylib 到目标 App bundle 内
        let destDylib = (appBundle as NSString).appendingPathComponent(dylibName)
        let cpCmd = "cp \(dylibPath) \(destDylib)"
        let (cpCode, _) = spawnAsRoot(cpCmd)
        guard cpCode == 0 else {
            throw InjectionError.failed("复制 dylib 到 App bundle 失败（退出码=\(cpCode)），请确认 TrollStore 中已开启所有权限")
        }

        // 2. 修改 Info.plist，添加 DYLD_INSERT_LIBRARIES
        let infoPlist = (appBundle as NSString).appendingPathComponent("Info.plist")
        let plistCmd = "/usr/libexec/PlistBuddy -c 'Add :DYLD_INSERT_LIBRARIES string @executable_path/\(dylibName)' \(infoPlist)"
        let (plistCode, _) = spawnAsRoot(plistCmd)
        if plistCode != 0 {
            // 可能已存在 key，尝试修改
            let setCmd = "/usr/libexec/PlistBuddy -c 'Set :DYLD_INSERT_LIBRARIES @executable_path/\(dylibName)' \(infoPlist)"
            let (setCode, _) = spawnAsRoot(setCmd)
            if setCode != 0 {
                throw InjectionError.failed("修改 Info.plist 失败（退出码=\(setCode)）")
            }
        }

        // 3. 刷新图标缓存
        spawnAsRoot("/usr/bin/uicache -p \(appBundle)")

        let record = InjectionRecord(
            appBundleID: app.bundleID,
            appName: app.displayName,
            dylibName: dylibName,
            appBundlePath: appBundle,
            status: "注入成功",
            message: "已将 \(dylibName) 注入 \(app.displayName) 的 bundle 内\n路径：\(appBundle)\n请重启应用后生效。"
        )
        recentInjections.insert(record, at: 0)
        return record.message
    }

    /// 以 root 权限执行命令（通过 posix_spawn）
    @discardableResult
    private func spawnAsRoot(_ command: String) -> (Int32, String) {
        var pid: pid_t = 0
        let fullCmd = "/bin/sh -c '\(command)'"
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command)]
        argv.append(nil)
        var env: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin")]
        env.append(nil)
        let result = posix_spawn(&pid, "/bin/sh", nil, nil, argv, env)
        defer { for a in argv { if let a { free(a) } } }
        defer { for e in env { if let e { free(e) } } }
        guard result == 0 else { return (result, "posix_spawn 失败") }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exitCode = (status >> 8) & 0xFF
        return (exitCode, "")
    }
}