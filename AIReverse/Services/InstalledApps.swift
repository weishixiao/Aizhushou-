import Foundation
import UIKit

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

    /// 系统应用 Bundle ID 前缀黑名单
    private let systemBundlePrefixes = [
        "com.apple.",
        "com.iphone.",
        "com.google.ios.",
        "com.facebook.",
        "com.amazon.",
        "com.microsoft.",
        "com.netflix.",
        "com.spotify.",
        "com.instagram.",
        "com.whatsapp.",
        "com.twitter.",
        "com.linkedin.",
        "com.snapchat.",
        "com.tiktok.",
        "com.discord.",
        "com.slack.",
        "com.zoom.",
        "com.ubercab.",
        "com.lyft.",
        "com.airbnb.",
        "com.booking.",
        "com.yelp.",
    ]

    /// 系统应用名称黑名单
    private let systemAppNames = [
        "SpringBoard", "Preferences", "MobileSafari", "Camera", "Photos",
        "Maps", "Clock", "Weather", "News", "Tips", "FindMy",
        "MobileStore", "Music", "Videos", "Podcasts", "Books",
        "Calculator", "Contacts", "Reminders", "Stocks", "VoiceMemos",
        "Files", "Measure", "Shortcuts", "Translate", "Compass",
        "FaceTime", "Messages", "Phone", "Mail", "Notes", "Calendar",
        "Health", "Wallet", "Watch", "Home", "ScreenTime",
        "AppStore", "iTunesStore", "iBooks", "GameCenter", "Fitness",
        "Magnifier", "Twitter", "Facebook", "Instagram", "YouTube",
        "Netflix", "Spotify", "WhatsApp", "Telegram", "Discord",
    ]

    /// 获取用户已安装的应用列表（仅用户应用）
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

                // 获取应用显示名称（优先 CFBundleDisplayName → CFBundleName → CFBundleExecutable）
                let displayName = appDisplayName(from: info, executable: executable)

                // 多级过滤：跳过系统应用
                if isSystemApp(bundleID: bundleID, executable: executable) { continue }

                let iconData = loadIcon(from: appPath, info: info)

                apps.append(InstalledApp(
                    displayName: displayName,
                    bundleID: bundleID,
                    bundlePath: appPath,
                    version: version,
                    iconData: iconData
                ))
            }
        }

        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// 判断是否为系统应用
    private func isSystemApp(bundleID: String, executable: String) -> Bool {
        // 空检查
        guard !bundleID.isEmpty, !executable.isEmpty else { return true }

        // Bundle ID 前缀匹配
        for prefix in systemBundlePrefixes {
            if bundleID.hasPrefix(prefix) { return true }
        }

        // 应用名称匹配
        if systemAppNames.contains(executable) { return true }

        // 其他系统特征
        let lowerBundleID = bundleID.lowercased()
        if lowerBundleID.contains("springboard") { return true }
        if lowerBundleID.contains("dyld") { return true }
        if lowerBundleID.contains("daemon") { return true }
        if lowerBundleID.contains("framework") { return true }
        if lowerBundleID.contains("privateframework") { return true }
        if lowerBundleID.contains("mobilegestalt") { return true }

        return false
    }

    /// 获取应用显示名称（优先级：CFBundleDisplayName > CFBundleName > CFBundleExecutable）
    private func appDisplayName(from info: NSDictionary, executable: String) -> String {
        // 优先使用 CFBundleDisplayName（用户可见的显示名称）
        if let displayName = info["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        // 其次使用 CFBundleName（应用名称）
        if let name = info["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        // 最后回退到可执行文件名
        return executable
    }

    /// 加载应用图标（优化版）
    private func loadIcon(from appPath: String, info: NSDictionary) -> Data? {
        // 方法1: 从 CFBundleIcons 获取现代图标配置
        if let iconData = loadModernIcon(from: appPath, info: info) {
            return iconData
        }

        // 方法2: 从 CFBundleIconFiles 获取
        if let iconData = loadIconFiles(from: appPath, info: info) {
            return iconData
        }

        // 方法3: 从 CFBundleIconFile 获取传统图标
        if let iconData = loadLegacyIcon(from: appPath, info: info) {
            return iconData
        }

        // 方法4: 遍历 .app 目录查找图标文件
        if let iconData = scanForIcons(in: appPath) {
            return iconData
        }

        return nil
    }

    /// 加载现代图标配置 (iOS 5.0+)
    private func loadModernIcon(from appPath: String, info: NSDictionary) -> Data? {
        guard let icons = info["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else {
            return nil
        }

        // 优先获取大尺寸图标
        let sortedFiles = files.sorted { $0.count > $1.count }
        for name in sortedFiles {
            for suffix in ["@3x.png", "@2x.png", ".png", "@3x", "@2x", ""] {
                let iconPath = (appPath as NSString).appendingPathComponent("\(name)\(suffix)")
                if let data = FileManager.default.contents(atPath: iconPath) {
                    return data
                }
            }
        }
        return nil
    }

    /// 从 CFBundleIconFiles 加载图标
    private func loadIconFiles(from appPath: String, info: NSDictionary) -> Data? {
        guard let files = info["CFBundleIconFiles"] as? [String], !files.isEmpty else {
            return nil
        }

        let sortedFiles = files.sorted { $0.count > $1.count }
        for name in sortedFiles {
            for suffix in ["@3x.png", "@2x.png", ".png", "@3x", "@2x", ""] {
                let iconPath = (appPath as NSString).appendingPathComponent("\(name)\(suffix)")
                if let data = FileManager.default.contents(atPath: iconPath) {
                    return data
                }
            }
        }
        return nil
    }

    /// 加载传统图标 (CFBundleIconFile)
    private func loadLegacyIcon(from appPath: String, info: NSDictionary) -> Data? {
        guard let iconName = info["CFBundleIconFile"] as? String else { return nil }

        for suffix in ["@3x.png", "@2x.png", ".png", "@3x", "@2x", ""] {
            let iconPath = (appPath as NSString).appendingPathComponent("\(iconName)\(suffix)")
            if let data = FileManager.default.contents(atPath: iconPath) {
                return data
            }
        }
        return nil
    }

    /// 扫描应用目录查找图标文件
    private func scanForIcons(in appPath: String) -> Data? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: appPath) else {
            return nil
        }

        // 优先查找 Car 文件 (Assets.car)
        let carFiles = items.filter { $0.lowercased().hasSuffix(".car") }
        if !carFiles.isEmpty {
            // Assets.car 无法直接读取，继续查找其他图标
        }

        // 查找 AppIcon 或 Icon 开头的 PNG 文件
        let iconPatterns = ["AppIcon", "Icon", "icon", "appicon"]
        for pattern in iconPatterns {
            let matchedFiles = items.filter { $0.hasPrefix(pattern) && $0.lowercased().hasSuffix(".png") }
            for file in matchedFiles {
                let iconPath = (appPath as NSString).appendingPathComponent(file)
                if let data = FileManager.default.contents(atPath: iconPath) {
                    return data
                }
            }
        }

        // 查找任何 PNG 图标文件（40x40 以上）
        let pngFiles = items.filter { $0.lowercased().hasSuffix(".png") }.sorted { $0.count > $1.count }
        for file in pngFiles {
            let iconPath = (appPath as NSString).appendingPathComponent(file)
            if let data = FileManager.default.contents(atPath: iconPath),
               let image = UIImage(data: data),
               image.size.width >= 40 {
                return data
            }
        }

        return nil
    }
}
