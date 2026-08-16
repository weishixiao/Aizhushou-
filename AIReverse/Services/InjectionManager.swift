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
    let targetDir: String
    let status: String
    let message: String
    let date = Date()
}

/// 插件注入管理器：
/// 接受用户上传的 .dylib 文件，复制到指定的注入目录，安装 Filter.plist，然后 uicache 刷新。
final class InjectionManager: ObservableObject {
    static let shared = InjectionManager()

    @Published var recentInjections: [InjectionRecord] = []

    private let rt = JailbreakRuntime.shared

    private init() {}

    /// 注入一个已存在的 .dylib 文件到目标应用
    /// - Parameters:
    ///   - dylibPath: 已上传到沙盒的 .dylib 文件路径
    ///   - app: 目标应用
    ///   - targetDir: 注入目录（如 /var/jb/Library/MobileSubstrate/DynamicLibraries）
    /// - Returns: 注入结果信息
    @discardableResult
    func injectDylib(at dylibPath: String, into app: InstalledApp, targetDir: String) throws -> String {
        guard rt.isJailbroken else {
            throw InjectionError.failed("未检测到越狱环境，无法注入")
        }

        let dylibName = (dylibPath as NSString).lastPathComponent
        let tweakName = (dylibName as NSString).deletingPathExtension
        let plistName = "\(tweakName).plist"

        // 用 access() 检测目录是否存在（比 fileExists 可靠，沙盒内也能感知越狱路径）
        var dirExists = false
        targetDir.withCString { ptr in
            dirExists = access(ptr, F_OK) == 0
        }
        if !dirExists {
            // 尝试通过 posix_spawn 创建目录（越狱环境可用）
            var pid: pid_t = 0
            let cmd = "/bin/mkdir -p \(targetDir)"
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd)]
            argv.append(nil)
            var env: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin")]
            env.append(nil)
            let spawnResult = posix_spawn(&pid, "/bin/sh", nil, nil, argv, env)
            defer { for a in argv { if let a { free(a) } } }
            defer { for e in env { if let e { free(e) } } }
            if spawnResult == 0 {
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                // 重新检测
                targetDir.withCString { ptr in
                    dirExists = access(ptr, F_OK) == 0
                }
            }
        }
        if !dirExists {
            throw InjectionError.failed("注入目录不存在且无法创建：\(targetDir)")
        }

        // 复制 dylib 到目标目录（用 posix_spawn cp 以绕过沙盒文件限制）
        let destDylib = (targetDir as NSString).appendingPathComponent(dylibName)
        let cpCmd = "/bin/cp \(dylibPath) \(destDylib)"
        var pid2: pid_t = 0
        var argv2: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cpCmd)]
        argv2.append(nil)
        var env2: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin")]
        env2.append(nil)
        let cpResult = posix_spawn(&pid2, "/bin/sh", nil, nil, argv2, env2)
        defer { for a in argv2 { if let a { free(a) } } }
        defer { for e in env2 { if let e { free(e) } } }
        guard cpResult == 0 else {
            throw InjectionError.failed("复制 dylib 失败（posix_spawn 错误码=\(cpResult)）")
        }
        var cpStatus: Int32 = 0
        waitpid(pid2, &cpStatus, 0)
        let cpExit = (cpStatus >> 8) & 0xFF
        guard cpExit == 0 else {
            throw InjectionError.failed("复制 dylib 失败（cp 退出码=\(cpExit)）")
        }

        // 安装 Filter.plist（限定目标 App）
        let destPlist = (targetDir as NSString).appendingPathComponent(plistName)
        installFilterPlist(to: destPlist, bundleID: app.bundleID)

        // 刷新图标缓存
        rt.executeCommand("/usr/bin/uicache", environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        rt.executeCommand("/usr/bin/uicache", arguments: ["-p", app.bundlePath], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])

        let record = InjectionRecord(
            appBundleID: app.bundleID,
            appName: app.displayName,
            dylibName: dylibName,
            targetDir: targetDir,
            status: "注入成功",
            message: "已将 \(dylibName) 注入 \(app.displayName)\n注入目录：\(targetDir)\n请重启应用后生效。"
        )
        recentInjections.insert(record, at: 0)
        return record.message
    }

    private func installFilterPlist(to destination: String, bundleID: String) {
        let plist: [String: Any] = [
            "Filter": [
                "Bundles": [bundleID]
            ]
        ]
        (plist as NSDictionary).write(toFile: destination, atomically: true)
    }
}