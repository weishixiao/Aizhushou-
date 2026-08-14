import Foundation

struct PackageScanReport {
    let fileName: String
    let fileExtension: String
    let fileSize: Int64
    let scannedBytes: Int
    let totalStrings: Int
    let categories: [PackageScanCategory]

    var summaryMarkdown: String {
        var lines: [String] = [
            "本地可疑信息扫描完成：\(fileName)",
            "- 文件类型：.\(fileExtension)",
            "- 文件大小：\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))",
            "- 扫描范围：\(ByteCountFormatter.string(fromByteCount: Int64(scannedBytes), countStyle: .file))",
            "- 可读字符串：\(totalStrings) 条"
        ]

        if categories.isEmpty {
            lines.append("- 未发现明显可疑信息。")
        } else {
            lines.append("\n可疑信息分类：")
            for category in categories {
                lines.append("- \(category.title)：\(category.totalCount) 条")
                for sample in category.matches.prefix(5) {
                    lines.append("  - \(sample)")
                }
            }
        }

        lines.append("\n提示：该扫描只做本地静态信息归类，用于安全自检和加固建议。")
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

        return PackageScanReport(
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            fileSize: size,
            scannedBytes: data.count,
            totalStrings: strings.count,
            categories: categories
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
            ("URL / 接口域名", { containsAny($0, ["http://", "https://", "api.", ".com/", ".cn/", ".net/"]) }, false),
            ("认证 / Token / Key", { containsAny($0, ["token", "apikey", "api_key", "secret", "bearer", "authorization", "password", "passwd"]) }, true),
            ("登录 / 账号", { containsAny($0, ["login", "signin", "signup", "account", "username", "phone", "captcha", "oauth"]) }, false),
            ("支付 / 订阅", { containsAny($0, ["pay", "payment", "purchase", "subscribe", "subscription", "receipt", "iap", "alipay", "wechatpay"]) }, false),
            ("越狱 / Root 检测", { containsAny($0, ["jailbreak", "cydia", "substrate", "frida", "root", "magisk", "xposed"]) }, false),
            ("SSL / 证书", { containsAny($0, ["ssl", "tls", "certificate", "cert", "pinning", "trust", "x509", "publickey"]) }, false),
            ("加密 / 哈希", { containsAny($0, ["aes", "rsa", "sha1", "sha256", "md5", "crypto", "encrypt", "decrypt", "hmac"]) }, false),
            ("路径 / 配置文件", { containsAny($0, ["/var/", "/tmp/", "/private/", "plist", ".json", ".db", ".sqlite", ".conf"]) }, false),
            ("动态库 / Framework", { containsAny($0, [".dylib", ".framework", "@rpath", "@loader_path", "@executable_path"]) }, false)
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
