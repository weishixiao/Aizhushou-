import Foundation
import UIKit

enum RuntimeLogLevel: String, Codable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

struct RuntimeLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let level: RuntimeLogLevel
    let source: String
    let message: String

    init(level: RuntimeLogLevel, source: String, message: String, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.level = level
        self.source = source
        self.message = message
    }
}

/// 应用运行日志：内存缓存 + 沙盒文件持久化，供设置页查看与清理。
///
/// 安全：所有日志在写入内存与磁盘前统一经过 `sanitize()` 脱敏，
/// 避免 API Key、GitHub/Gitee token、URL 内嵌凭证等信息持久化到
/// sandbox/Documents/Logs/runtime.log（越狱设备上可被其他 root 进程读取）。
final class RuntimeLogger: ObservableObject {

    static let shared = RuntimeLogger()

    @Published private(set) var entries: [RuntimeLogEntry] = []

    private let maxInMemoryEntries = 300
    private let maxFileSize: Int64 = 2 * 1024 * 1024
    private let directoryName = "Logs"
    private let fileName = "runtime.log"
    private let dateFormatter: DateFormatter
    private let lock = NSLock()

    private init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter = formatter
        restoreFromDisk()
    }

    var logFileURL: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 记录一条日志（线程安全，UI 更新收敛到主线程，先脱敏再落盘）
    func log(_ level: RuntimeLogLevel, _ source: String, _ message: String) {
        let safeMessage = RuntimeLogger.sanitize(message)
        let entry = RuntimeLogEntry(level: level, source: source, message: safeMessage)
        lock.lock()
        var snapshot = entries
        snapshot.append(entry)
        if snapshot.count > maxInMemoryEntries {
            snapshot.removeFirst(snapshot.count - maxInMemoryEntries)
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.entries = snapshot
            self.lock.unlock()
        }
        appendToFile(entry)
    }

    func info(_ source: String, _ message: String) {
        log(.info, source, message)
    }

    func warning(_ source: String, _ message: String) {
        log(.warning, source, message)
    }

    func error(_ source: String, _ message: String) {
        log(.error, source, message)
    }

    /// 记录底层错误（Error 类型），自动带上类型与描述
    func recordError(_ source: String, _ error: Error) {
        log(.error, source, "\(error.localizedDescription) [\(type(of: error))]")
    }

    /// 清空内存与磁盘日志
    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.entries = []
        }
        if let url = logFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 导出为纯文本（用于复制分享）
    var exportText: String {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.map { entry in
            "[\(dateFormatter.string(from: entry.date))] [\(entry.level.rawValue)] [\(entry.source)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    // MARK: - 脱敏

    private static let sensitivePatterns: [(NSRegularExpression, String)] = {
        func regex(_ p: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            // Bearer <token>
            (regex(#"(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}(?=[\s"'\],;]|$)""#), "$1***"),
            // Authorization: token ...
            (regex(#"([Aa]uthorization[:=]\s*(?:token|basic)\s+)[A-Za-z0-9._~+/=-]{8,}""#), "$1***"),
            // x-api-key: <key>
            (regex(#"([Xx]-[Aa]pi-[Kk]ey[:=]\s*)[A-Za-z0-9._~+/=-]{4,}""#), "$1***"),
            // github_pat_ / ghp_ / gho_ / ghu_ / ghp 等 GitHub token 形态
            (regex(#"(github_pat_[A-Za-z0-9_]{10,}|gh[pousr]_[A-Za-z0-9]{20,})""#), "***"),
            // 常见 API key 参数形态：?key= / ?token= / &access_token= / x-api-token
            (regex(#"([?&](?:api[_-]?key|access_token|client_secret|token|secret|apikey)=)[^&\s"']+""#), "$1***"),
            // URL 内嵌凭证 http://user:pass@host
            (regex(#"([a-z][a-z0-9+.-]*://)[^/@\s]+:[^/@\s]*@"#), "$1***:***@"),
            // 长 hex 形态（可能是 key）
            (regex(#"\b[0-9a-f]{32,64}\b""#), "***"),
        ]
    }()

    /// 对日志文本做脱敏；空串或长度过大直接原样短路，避免无谓开销。
    static func sanitize(_ text: String) -> String {
        guard !text.isEmpty, text.count <= 4096 else { return text }
        var out = text
        let ns = out as NSString
        let range = NSRange(location: 0, length: ns.length)
        for (pattern, replacement) in sensitivePatterns {
            out = pattern.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: replacement)
        }
        return out
    }

    // MARK: - 文件持久化

    private func appendToFile(_ entry: RuntimeLogEntry) {
        let line = "[\(dateFormatter.string(from: entry.date))] [\(entry.level.rawValue)] [\(entry.source)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        guard let fileURL = logFileURL else { return }
        do {
            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: fileURL.path) {
                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                if size + Int64(data.count) > maxFileSize {
                    try fm.removeItem(at: fileURL)
                }
            }
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 文件写入失败时只降级为内存日志，不再递归记录，避免死循环
        }
    }

    private func restoreFromDisk() {
        guard let fileURL = logFileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let restored = lines.prefix(maxInMemoryEntries).compactMap { line -> RuntimeLogEntry? in
            guard let (levelText, rest) = parseLevel(from: line),
                  let level = RuntimeLogLevel(rawValue: levelText) else {
                return nil
            }
            guard let (dateText, sourceText, message) = parseHeader(from: rest) else { return nil }
            return RuntimeLogEntry(
                level: level,
                source: sourceText,
                message: message,
                date: dateFormatter.date(from: dateText) ?? Date()
            )
        }
        entries = restored
    }

    private func parseLevel(from line: String) -> (String, String)? {
        guard line.hasPrefix("[") else { return nil }
        guard let end = line.firstIndex(of: "]") else { return nil }
        let start = line.index(after: line.startIndex)
        let levelText = String(line[start..<end])
        let rest = String(line[line.index(after: end)...])
        return (levelText, rest)
    }

    private func parseHeader(from text: String) -> (String, String, String)? {
        let parts = text.split(separator: Character("]"), maxSplits: 3).map { String($0) }
        guard parts.count >= 3 else { return nil }
        let dateText = String(parts[0].dropFirst())
        let sourceText = String(parts[1].dropFirst())
        let message = parts[2].hasPrefix(" ") ? String(parts[2].dropFirst()) : parts[2]
        return (dateText, sourceText, message)
    }
}
