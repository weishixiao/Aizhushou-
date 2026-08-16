import Foundation
import UIKit

/// 单个已安装应用的信息
struct InstalledApp: Identifiable, Hashable, Equatable {
    /// 应用唯一标识（用于 SwiftUI 列表，用 bundleID + 路径去重）
    var id: String { "\(bundleID)|\(bundlePath)" }
    /// 应用名称（如「微信」）
    var name: String
    /// 包名（如 com.tencent.xin）
    var bundleID: String
    /// 主二进制 / 应用的绝对路径
    var bundlePath: String
    /// 应用版本
    var version: String
    /// 是否为系统应用（com.apple.* 等）
    var isSystem: Bool
    /// 图标缓存（可为空，降低内存）
    var icon: UIImage?

    var displayName: String {
        name.isEmpty ? bundleID : name
    }
}

/// 已安装应用枚举器
/// 优先走越狱环境可用的 LSApplicationWorkspace（私有框架），
/// 失败时回退为遍历 /var/containers/Bundle/Application 目录（仅 sandbox 内可见性）
final class InstalledApps {
    static let shared = InstalledApps()

    private init() {}

    /// 系统应用 bundleID 前缀，用于过滤
    private let systemIDPrefixes: [String] = [
        "com.apple.",
        "com.apple.webapp.",
        "com.apple.mobilesafari",
        "com.apple.springboard",
    ]

    /// 过滤掉系统工具类应用的 bundleID 精确匹配
    private let systemIDExact: Set<String> = [
        "com.apple.Preferences",
        "com.apple.MobileStore",
        "com.apple.AppStore",
    ]

    /// 列出全部已安装应用
    func allApps() -> [InstalledApp] {
        if let apps = listViaLSApplicationWorkspace() {
            return apps
        }
        return listViaContainersDirectory()
    }

    /// 仅用户应用（排除系统应用）
    func userApps() -> [InstalledApp] {
        allApps().filter { !$0.isSystem }
    }

    private func isSystemApp(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return true }
        if systemIDExact.contains(bundleID) { return true }
        return systemIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    // MARK: - 方式一：LSApplicationWorkspace（越狱/TrollStore 下可用）

    private func listViaLSApplicationWorkspace() -> [InstalledApp]? {
        let className = "LSApplicationWorkspace"
        guard let workspaceClass: AnyClass = NSClassFromString(className),
              let defaultWorkspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace")),
              let workspace = defaultWorkspace.takeUnretainedValue() as? NSObject
        else {
            return nil
        }

        let selector = NSSelectorFromString("allApplications")
        guard workspace.responds(to: selector),
              let apps = workspace.perform(selector)?.takeUnretainedValue() as? [NSObject]
        else {
            return nil
        }

        var result: [InstalledApp] = []

        for app in apps {
            // 通过 applicationIdentifier 取 bundleID
            let bundleID = app.perform(NSSelectorFromString("applicationIdentifier"))?.takeUnretainedValue() as? String ?? ""

            // 通过 bundleURL 取路径
            var appPath = ""
            if app.responds(to: NSSelectorFromString("bundleURL")),
               let url = app.perform(NSSelectorFromString("bundleURL"))?.takeUnretainedValue() as? URL {
                appPath = url.path
            }

            let name = localizedName(for: app, bundleID: bundleID, path: appPath)
            let version = app.perform(NSSelectorFromString("bundleVersion"))?.takeUnretainedValue() as? String
                ?? app.perform(NSSelectorFromString("shortVersionString"))?.takeUnretainedValue() as? String
                ?? ""

            result.append(InstalledApp(
                name: name,
                bundleID: bundleID,
                bundlePath: appPath,
                version: version,
                isSystem: isSystemApp(bundleID: bundleID),
                icon: icon(for: app)
            ))
        }

        // 去重
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }

    private func localizedName(for app: NSObject, bundleID: String, path: String) -> String {
        if app.responds(to: NSSelectorFromString("localizedName")),
           let name = app.perform(NSSelectorFromString("localizedName"))?.takeUnretainedValue() as? String,
           !name.isEmpty {
            return name
        }
        // 兜底：从 Info.plist 读 CFBundleDisplayName
        if !path.isEmpty {
            let plistPath = (path as NSString).appendingPathComponent("Info.plist")
            if let dict = NSDictionary(contentsOfFile: plistPath),
               let name = dict["CFBundleDisplayName"] as? String,
               !name.isEmpty {
                return name
            }
            if let dict = NSDictionary(contentsOfFile: plistPath),
               let name = dict["CFBundleName"] as? String,
               !name.isEmpty {
                return name
            }
        }
        return bundleID
    }

    private func icon(for app: NSObject) -> UIImage? {
        // 尝试私有 API iconForApplication:
        let sel = NSSelectorFromString("iconForApplication:")
        if app.responds(to: sel),
           let img = app.perform(sel)?.takeUnretainedValue() as? UIImage {
            return img
        }
        return nil
    }

    // MARK: - 方式二：遍历 /var/containers/Bundle/Application/

    private func listViaContainersDirectory() -> [InstalledApp] {
        let root = "/var/containers/Bundle/Application"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }

        var result: [InstalledApp] = []
        for entry in entries {
            let entryPath = (root as NSString).appendingPathComponent(entry)
            guard let subEntries = try? FileManager.default.contentsOfDirectory(atPath: entryPath) else { continue }
            for sub in subEntries where sub.hasSuffix(".app") {
                let appPath = (entryPath as NSString).appendingPathComponent(sub)
                guard let info = loadInfoPlist(at: appPath) else { continue }
                let bundleID = (info["CFBundleIdentifier"] as? String) ?? sub
                if bundleID.isEmpty { continue }
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? bundleID
                let version = (info["CFBundleShortVersionString"] as? String)
                    ?? (info["CFBundleVersion"] as? String)
                    ?? ""

                result.append(InstalledApp(
                    name: name,
                    bundleID: bundleID,
                    bundlePath: appPath,
                    version: version,
                    isSystem: isSystemApp(bundleID: bundleID),
                    icon: loadAppIcon(at: appPath, from: info)
                ))
            }
        }
        return result
    }

    private func loadInfoPlist(at appPath: String) -> [String: Any]? {
        let infoPath = (appPath as NSString).appendingPathComponent("Info.plist")
        return NSDictionary(contentsOfFile: infoPath) as? [String: Any]
    }

    private func loadAppIcon(at appPath: String, from info: [String: Any]) -> UIImage? {
        let bundle = Bundle(path: appPath)
        return bundle?.icon
    }
}

private extension Bundle {
    /// 读取 App 图标（主图标）
    var icon: UIImage? {
        guard let icons = object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any] else { return nil }
        let primary = (icons["CFBundlePrimaryIcon"] as? [String: Any])
        let files = (primary?["CFBundleIconFiles"] as? [String]) ?? []
        let name = files.first
        guard let name else { return nil }
        return UIImage(named: name) ?? (UIImage(named: name, in: self, compatibleWith: nil))
    }
}