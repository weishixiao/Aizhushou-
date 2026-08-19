import Foundation

/// 已安装应用信息模型
struct InstalledApp: Identifiable, Equatable {
    let id = UUID()
    let displayName: String
    let bundleID: String
    let bundlePath: String
    let version: String
    let iconData: Data?
}

/// 已安装应用枚举器
final class InstalledApps {
    static let shared = InstalledApps()
    private init() {}

    /// 获取用户已安装的应用列表（排除系统应用）
    func userApps() -> [InstalledApp] {
        var apps: [InstalledApp] = []
        let applicationsDir = "/var/containers/Bundle/Application"

        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: applicationsDir) else {
            return apps
        }

        for dir in dirs {
            let dirPath = (applicationsDir as NSString).appendingPathComponent(dir)
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { continue }

            for item in items where item.hasSuffix(".app") {
                let appPath = (dirPath as NSString).appendingPathComponent(item)
                let infoPlistPath = (appPath as NSString).appendingPathComponent("Info.plist")

                guard let info = NSDictionary(contentsOfFile: infoPlistPath) else { continue }

                let bundleID = info["CFBundleIdentifier"] as? String ?? ""
                let version = info["CFBundleShortVersionString"] as? String ?? ""
                let executable = info["CFBundleExecutable"] as? String ?? ""

                // 排除系统应用（com.apple 开头）
                guard !bundleID.hasPrefix("com.apple") else { continue }

                // 检查是否需要跳过
                if shouldSkipBundleID(bundleID) { continue }

                let iconData = loadIcon(from: appPath, info: info)

                apps.append(InstalledApp(
                    displayName: executable,
                    bundleID: bundleID,
                    bundlePath: appPath,
                    version: version,
                    iconData: iconData
                ))
            }
        }

        return apps.sorted { $0.displayName < $1.displayName }
    }

    /// 内部过滤 —— 去掉系统、空白白名、framework 等不需要显示的 bundle id
    private func shouldSkipBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return true }
        guard !bundleID.hasPrefix("com.apple.") else { return true }
        let lower = bundleID.lowercased()
        if lower.contains("springboard") { return true }
        if lower.contains("framework") { return true }
        if lower.contains("dyld") { return true }
        return false
    }

    /// 加载应用图标
    private func loadIcon(from appPath: String, info: NSDictionary) -> Data? {
        var iconName = info["CFBundleIconFile"] as? String
        if iconName == nil, let icons = info["CFBundleIcons"] as? [String: Any] {
            if let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = icons["CFBundleIconFiles"] as? [String], !files.isEmpty {
                iconName = files.last
            }
        }

        guard let name = iconName else { return nil }
        let iconPath = (appPath as NSString).appendingPathComponent("\(name)@2x.png")
        if let data = FileManager.default.contents(atPath: iconPath) { return data }

        // 尝试其他尺寸
        for suffix in ["@3x.png", "@2x.png", ".png"] {
            let path = (appPath as NSString).appendingPathComponent("\(name)\(suffix)")
            if let data = FileManager.default.contents(atPath: path) { return data }
        }

        return nil
    }
}
