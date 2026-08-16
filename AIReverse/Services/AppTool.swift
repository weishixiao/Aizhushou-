import Foundation

/// 列出已安装用户应用的工具（只读）
/// 供 AI 在「进程」分析中枚举本机 App。
final class ListInstalledAppsTool: CodingTool {
    var name: String { "list_installed_apps" }
    var description: String { "列出本机已安装的（用户）应用，排除系统应用。返回应用的名称、bundleID 与路径，用于逆向分析和注入定位。" }
    var isMutating: Bool { false }

    var parameters: [String: Any] {
        ["type": "object", "properties": [:], "required": []]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        let apps = InstalledApps.shared.userApps()
        guard !apps.isEmpty else {
            return ToolResult(success: true, output: "未找到任何用户应用（可能沙盒受限）。")
        }
        var lines = ["已安装的用户应用（\(apps.count) 个）:", ""]
        for app in apps {
            lines.append("▪ \(app.displayName)")
            lines.append("   bundleID: \(app.bundleID)")
            lines.append("   路径: \(app.bundlePath)")
            if !app.version.isEmpty { lines.append("   版本: \(app.version)") }
            lines.append("")
        }
        return ToolResult(success: true, output: lines.joined(separator: "\n"))
    }
}

/// 修改目标应用关键数据（存档 / 配置……）（修改类）
final class ModifyAppDataTool: CodingTool {
    var name: String { "modify_app_data" }
    var description: String { "读取或修改目标应用的本地数据（如偏好设置 plist、存档、计数），需提供 bundleID 与数据路径。属于修改类高风险操作。" }
    var isMutating: Bool { true }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "bundle_id": ["type": "string", "description": "目标应用 bundleID"],
                "action": ["type": "string", "description": "read 或 write"],
                "path": ["type": "string", "description": "相对 Library 的数据文件路径，如 Preferences/xxx.plist"],
                "key": ["type": "string", "description": "要修改的 key（write 时）"],
                "value": ["type": "string", "description": "写入的值（write 时，建议 JSON 字符串）"]
            ],
            "required": ["bundle_id", "action", "path"]
        ]
    }

    func execute(arguments: [String: Any], workspace: WorkspaceManager, github: GitHubAPIClient, repoConfig: GitRepoConfig) async throws -> ToolResult {
        guard let bundleID = arguments["bundle_id"] as? String else {
            return ToolResult(success: false, output: "缺少 bundle_id")
        }
        let action = (arguments["action"] as? String) ?? "read"

        // 定位应用沙盒数据目录
        guard let dataDir = appDataContainer(bundleID: bundleID) else {
            return ToolResult(success: false, output: "找不到 \(bundleID) 的数据容器")
        }
        let relativePath = (arguments["path"] as? String) ?? ""
        let target = (dataDir as NSString).appendingPathComponent(relativePath)

        if action == "write" {
            guard let key = arguments["key"] as? String else {
                return ToolResult(success: false, output: "缺少 key")
            }
            let value = arguments["value"] as? String ?? ""
            do {
                try modifyPlist(key: key, value: value, at: target)
                return ToolResult(success: true, output: "已修改 \(relativePath) 的 \(key) = \(value)")
            } catch {
                return ToolResult(success: false, output: "修改失败：\(error.localizedDescription)")
            }
        } else {
            let content = (try? String(contentsOfFile: target, encoding: .utf8)) ?? "文件不存在或不可读"
            return ToolResult(success: true, output: "=== \(relativePath) ===\n\(String(content.prefix(2000)))")
        }
    }

    /// 从已安装应用反查其数据沙盒目录（/var/mobile/Containers/Data/Application/<UUID>）
    private func appDataContainer(bundleID: String) -> String? {
        let dataRoot = "/var/mobile/Containers/Data/Application"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: dataRoot) else { return nil }
        for dir in dirs {
            let dirPath = (dataRoot as NSString).appendingPathComponent(dir)
            let metaPath = (dirPath as NSString).appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            if let dict = NSDictionary(contentsOfFile: metaPath),
               let id = dict["MCMMetadataIdentifier"] as? String,
               id == bundleID {
                return dirPath
            }
        }
        return nil
    }

    private func modifyPlist(key: String, value: String, at path: String) throws {
        guard var dict = NSMutableDictionary(contentsOfFile: path) else {
            throw InjectionError.failed("无法读取 plist: \(path)")
        }
        // 尝试按 JSON 解析值类型（数字/布尔/字符串）
        if let data = value.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []) {
            dict.setValue(obj, forKey: key)
        } else {
            dict.setValue(value, forKey: key)
        }
        guard dict.write(toFile: path, atomically: true) else {
            throw InjectionError.failed("写入 plist 失败（检查权限）: \(path)")
        }
    }
}