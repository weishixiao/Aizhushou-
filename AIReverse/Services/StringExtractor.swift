import Foundation

/// 从 Mach-O 二进制的可读字符串区（__cstring / __ustring）提取 ASCII/UTF-8 字符串。
final class StringExtractor {

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    /// 提取可打印字符串（ASCII 可打印字符连续段，长度 >= 4）
    func extract(minLength: Int = 4, maxCount: Int = 5000) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []

        func flush() {
            guard current.count >= minLength else {
                current.removeAll()
                return
            }
            if let s = String(bytes: current, encoding: .utf8), !s.isEmpty {
                result.append(s)
            }
            current.removeAll()
        }

        for byte in data {
            if isPrintable(byte) {
                current.append(byte)
                if current.count > 2048 { flush() }
            } else {
                flush()
            }
            if result.count >= maxCount { break }
        }
        flush()
        return result
    }

    /// 提取常见的 URL / 可疑字符串（含 http/https 等关键词）
    func extractInteresting() -> [String] {
        let all = extract(minLength: 8)
        let keywords = ["http://", "https://", ".guyubao", "token", "secret", "api_", "password",
                        "card", "auth", "key=", "tunnel", "udp://", "tcp://", "ws://"]
        return all.filter { s in
            let lower = s.lowercased()
            return keywords.contains { lower.contains($0) }
        }
    }

    private func isPrintable(_ b: UInt8) -> Bool {
        (b >= 0x20 && b <= 0x7E) || b == 0x09
    }
}
