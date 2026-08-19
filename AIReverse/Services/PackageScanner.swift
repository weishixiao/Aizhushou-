import Foundation

struct PackageScanReport {
    let fileName: String
    let fileExtension: String
    let fileSize: Int64
    let scannedBytes: Int
    let totalStrings: Int
    let categories: [PackageScanCategory]
    let fileTypeDescription: String
    let isBinary: Bool
    let entitlements: [String]
    let urlSchemes: [String]
    let permissions: [String]

    var summaryMarkdown: String {
        var lines: [String] = [
            "📁 文件扫描报告：\(fileName)",
            "- 文件类型：.\(fileExtension)（\(fileTypeDescription)）",
            "- 文件大小：\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))",
            "- 扫描范围：\(ByteCountFormatter.string(fromByteCount: Int64(scannedBytes), countStyle: .file))",
            "- 可读字符串：\(totalStrings) 条",
            "- 二进制格式：\(isBinary ? "是" : "否")"
        ]

        // URL Schemes
        if !urlSchemes.isEmpty {
            lines.append("\n🔗 发现的 URL Schemes：")
            for scheme in urlSchemes.prefix(10) {
                lines.append("  - \(scheme)")
            }
        }

        // 权限信息
        if !permissions.isEmpty {
            lines.append("\n🔐 发现的权限声明：")
            for perm in permissions.prefix(10) {
                lines.append("  - \(perm)")
            }
        }

        // Entitlements
        if !entitlements.isEmpty {
            lines.append("\n📋 发现的 Entitlements：")
            for ent in entitlements.prefix(8) {
                lines.append("  - \(ent)")
            }
        }

        // 可疑信息分类
        if categories.isEmpty {
            lines.append("\n✅ 未发现明显可疑信息。")
        } else {
            lines.append("\n⚠️ 可疑信息分类：")
            for category in categories {
                lines.append("- \(category.title)：\(category.totalCount) 条")
                for sample in category.matches.prefix(5) {
                    lines.append("  - \(sample)")
                }
            }
        }

        lines.append("\n💡 提示：此扫描为本地静态分析，用于安全自检和代码审查辅助。")
        return lines.joined(separator: "\n")
    }
}

struct PackageScanCategory {
    let title: String
    let totalCount: Int
    let matches: [String]
}

final class PackageScanner {
    private let maxBytes = 20 * 1024 * 1024
    private let minStringLength = 4

    func scan(url: URL) throws -> PackageScanReport {
        let data = try readPrefix(url)
        let strings = extractStrings(from: data)
        let categories = buildCategories(from: strings)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        let ext = url.pathExtension.lowercased()
        let fileType = fileTypeDescription(for: ext)
        let isBinary = isBinaryFile(data: data, extension: ext)
        let urlSchemes = extractURLSchemes(from: strings)
        let permissions = extractPermissions(from: strings)
        let entitlements = extractEntitlements(from: strings)

        return PackageScanReport(
            fileName: url.lastPathComponent,
            fileExtension: ext,
            fileSize: size,
            scannedBytes: data.count,
            totalStrings: strings.count,
            categories: categories,
            fileTypeDescription: fileType,
            isBinary: isBinary,
            entitlements: entitlements,
            urlSchemes: urlSchemes,
            permissions: permissions
        )
    }

    private func readPrefix(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if #available(iOS 13.4, *) {
            return try handle.read(upToCount: maxBytes) ?? Data()
        }
        return handle.readData(ofLength: maxBytes)
    }

    private func extractStrings(from data: Data) -> [String] {
        var results: [String] = []
        var buffer = [UInt8]()

        func flush() {
            guard buffer.count >= minStringLength else {
                buffer.removeAll()
                return
            }
            if let text = String(bytes: buffer, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    results.append(trimmed)
                }
            }
            buffer.removeAll()
        }

        for byte in data {
            if byte >= 0x20 && byte <= 0x7E {
                buffer.append(byte)
            } else {
                flush()
            }
        }
        flush()

        return Array(Set(results)).sorted { $0.count > $1.count }
    }

    private func buildCategories(from strings: [String]) -> [PackageScanCategory] {
        let rules: [(String, (String) -> Bool, Bool)] = [
            ("URL / 接口域名", { containsAny($0, ["http://", "https://", "api.", ".com/", ".cn/", ".net/", ".org/", "www."]) }, false),
            ("认证 / Token / Key", { containsAny($0, ["token", "apikey", "api_key", "secret", "bearer", "authorization", "password", "passwd", "access_token", "refresh_token"]) }, true),
            ("登录 / 账号", { containsAny($0, ["login", "signin", "signup", "account", "username", "phone", "captcha", "oauth", "openid"]) }, false),
            ("支付 / 订阅", { containsAny($0, ["pay", "payment", "purchase", "subscribe", "subscription", "receipt", "iap", "alipay", "wechatpay", "in_app"]) }, false),
            ("SSL / 证书", { containsAny($0, ["ssl", "tls", "certificate", "cert", "pinning", "trust", "x509", "publickey", "keystore"]) }, false),
            ("加密 / 哈希", { containsAny($0, ["aes", "rsa", "sha1", "sha256", "md5", "crypto", "encrypt", "decrypt", "hmac", "cipher"]) }, false),
            ("数据库 / 存储", { containsAny($0, ["sqlite", "coredata", "realm", "fmdb", "database", "db_name", "persist"]) }, false),
            ("网络请求", { containsAny($0, ["urlsession", "afnetworking", "alamofire", "nsurl", "request", "endpoint"]) }, false),
            ("调试 / 日志", { containsAny($0, ["debug", "verbose", "log_", "nslog", "print", "console", "crashlytics", "bugly"]) }, false),
            ("动态库 / Framework", { containsAny($0, [".framework", "@rpath", "@loader_path", "@executable_path", "dylib", "dynamic"]) }, false)
        ]

        return rules.compactMap { rule in
            let title = rule.0
            let matcher = rule.1
            let shouldRedact = rule.2
            let rawMatches = strings.filter(matcher)
            let samples = rawMatches
                .prefix(5)
                .map { shouldRedact ? redact($0) : shorten($0) }
            guard !samples.isEmpty else { return nil }
            return PackageScanCategory(title: title, totalCount: rawMatches.count, matches: Array(samples))
        }
    }

    /// 提取 URL Schemes
    private func extractURLSchemes(from strings: [String]) -> [String] {
        var schemes: Set<String> = []
        let pattern = #"CFBundleURLSchemes"#
        for (index, str) in strings.enumerated() {
            if str.contains(pattern), index + 1 < strings.count {
                let nextStr = strings[index + 1]
                if nextStr.count < 50 && !nextStr.contains(" ") {
                    schemes.insert(nextStr)
                }
            }
        }
        // 也查找常见的 scheme 格式
        for str in strings {
            let lower = str.lowercased()
            if lower.hasPrefix("fb") && lower.count < 20 { schemes.insert(str) }
            if lower.hasPrefix("twitter") { schemes.insert(str) }
            if lower.hasPrefix("weixin") || lower.hasPrefix("wx") { schemes.insert(str) }
            if lower.hasPrefix("alipay") || lower.hasPrefix("alipays") { schemes.insert(str) }
        }
        return Array(schemes).sorted()
    }

    /// 提取权限声明
    private func extractPermissions(from strings: [String]) -> [String] {
        let permissionKeywords = [
            "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
            "NSLocationWhenInUseUsageDescription", "NSLocationAlwaysUsageDescription",
            "NSPhotoLibraryUsageDescription", "NSContactsUsageDescription",
            "NSBluetoothUsageDescription", "NSFaceIDUsageDescription",
            "NSUserTrackingUsageDescription", "NSAppleMusicUsageDescription",
            "motion", "healthkit", "homekit", "siri"
        ]
        return permissionKeywords.filter { keyword in
            strings.contains { $0.contains(keyword) }
        }
    }

    /// 提取 Entitlements
    private func extractEntitlements(from strings: [String]) -> [String] {
        let entitlementPatterns = [
            "com.apple.security",
            "com.apple.developer",
            "application-identifier",
            "keychain-access-groups",
            "aps-environment",
            "com.apple.private"
        ]
        return strings.filter { str in
            entitlementPatterns.contains { str.contains($0) }
        }.prefix(10).map { String($0) }
    }

    /// 判断是否为二进制文件
    private func isBinaryFile(data: Data, extension ext: String) -> Bool {
        let binaryExtensions = ["ipa", "apk", "dylib", "framework", "car"]
        if binaryExtensions.contains(ext) { return true }
        // 检查文件头
        guard data.count > 4 else { return false }
        let header = data.prefix(4)
        // Mach-O 魔数
        let machO: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]
        let machO2: [UInt8] = [0xFE, 0xED, 0xFA, 0xCF]
        let elf: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]
        let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let headerBytes = Array(header)
        return headerBytes == machO || headerBytes == machO2 || headerBytes == elf || headerBytes == zip
    }

    /// 文件类型描述
    private func fileTypeDescription(for ext: String) -> String {
        switch ext {
        case "ipa": return "iOS 应用包"
        case "apk": return "Android 应用包"
        case "deb": return "Debian 软件包"
        case "dylib": return "动态链接库"
        case "framework": return "iOS Framework"
        case "car": return "Asset Catalog"
        case "plist": return "属性列表"
        case "json": return "JSON 数据"
        case "xml": return "XML 文档"
        case "mobileprovision": return "描述文件"
        case "cer", "p12": return "证书文件"
        default: return "未知类型"
        }
    }

    private func redact(_ value: String) -> String {
        let shortened = shorten(value)
        guard shortened.count > 12 else { return "[已脱敏]" }
        return String(shortened.prefix(6)) + "...[已脱敏]..." + String(shortened.suffix(4))
    }

    private func shorten(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > 160 else { return singleLine }
        return String(singleLine.prefix(160)) + "..."
    }
}

private func containsAny(_ value: String, _ needles: [String]) -> Bool {
    let lowercased = value.lowercased()
    return needles.contains { lowercased.contains($0.lowercased()) }
}
