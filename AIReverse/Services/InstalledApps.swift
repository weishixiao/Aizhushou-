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
        guard let workspaceClass = NSClassFromString(className) as? NSObject.Type,
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
                icon: icon(for: app, bundleID: bundleID, bundlePath: appPath)
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

    private func icon(for app: NSObject, bundleID: String, bundlePath: String) -> UIImage? {
        // 1) 优先从 App bundle 路径读取图标（最可靠）
        if !bundlePath.isEmpty {
            if let info = loadInfoPlist(at: bundlePath),
               let img = loadAppIcon(at: bundlePath, from: info) {
                return img
            }
            if let bundle = Bundle(path: bundlePath), let img = bundle.icon {
                return img
            }
        }

        // 2) 尝试 LSApplicationProxy.privateIconForApplication:（部分系统版本可用）
        let selName = "privateIconForApplication:"
        if app.responds(to: NSSelectorFromString(selName)),
           let result = app.perform(NSSelectorFromString(selName), with: bundleID)?.takeUnretainedValue(),
           let img = result as? UIImage {
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
        // 收集候选图标文件名
        var candidates: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            candidates.append(contentsOf: files)
        }
        if let icons = info["CFBundleIcons~ipad"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            candidates.append(contentsOf: files)
        }
        if let name = info["CFBundleIconFile"] as? String {
            candidates.append(name)
        }
        if candidates.isEmpty { return nil }

        // 在 bundle 根目录按文件名匹配（含 @2x/@3x/尺寸后缀）
        if let subpaths = try? FileManager.default.contentsOfDirectory(atPath: appPath) {
            _ = subpaths
            for candidate in candidates {
                let base = (candidate as NSString).deletingPathExtension
                if let img = findImage(in: appPath, base: base) {
                    return img
                }
            }
        }
        return nil
    }

    /// 在 bundle 目录中按基础名查找图片资产（支持 .png/.png@2x/.png@3x）
    private func findImage(in dir: String, base: String) -> UIImage? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        // 先找精确名称
        let exact = (base as NSString).appendingPathExtension("png") ?? ""
        if files.contains(exact), let img = UIImage(contentsOfFile: (dir as NSString).appendingPathComponent(exact)) {
            return img
        }
        // 再找带 scale 后缀
        for f in files {
            if f.hasPrefix(base), f.contains("@"), f.hasSuffix(".png") {
                if let img = UIImage(contentsOfFile: (dir as NSString).appendingPathComponent(f)) {
                    return img
                }
            }
        }
        return nil
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