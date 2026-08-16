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

        // 确保目标目录存在
        if !FileManager.default.fileExists(atPath: targetDir) {
            // 尝试创建
            try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: targetDir) {
                throw InjectionError.failed("注入目录不存在且无法创建：\(targetDir)")
            }
        }

        // 复制 dylib 到目标目录
        let destDylib = (targetDir as NSString).appendingPathComponent(dylibName)
        if FileManager.default.fileExists(atPath: destDylib) {
            try? FileManager.default.removeItem(atPath: destDylib)
        }
        do {
            try FileManager.default.copyItem(atPath: dylibPath, toPath: destDylib)
        } catch {
            throw InjectionError.failed("复制 dylib 失败：\(error.localizedDescription)")
        }

        // 安装 Filter.plist（限定目标 App）
        let destPlist = (targetDir as NSString).appendingPathComponent(plistName)
        installFilterPlist(to: destPlist, bundleID: app.bundleID)

        // 刷新图标缓存
        if rt.isRoot {
            rt.executeCommand("/usr/bin/uicache", environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
            rt.executeCommand("/usr/bin/uicache", arguments: ["-p", app.bundlePath], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        }

        let record = InjectionRecord(
            appBundleID: app.bundleID,
            appName: app.displayName,
            dylibName: dylibName,
            targetDir: targetDir,
            status: "注入成功",
            message: "已将 \(dylibName) 注入 \(app.displayName)，注入目录：\(targetDir)\n请重启应用后生效。"
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