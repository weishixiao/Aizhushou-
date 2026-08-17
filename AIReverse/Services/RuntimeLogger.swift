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

/// 应用运行日志：内存缓存 + 沙盒文件持久化，供设置页查看与清理
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

    /// 记录一条日志（线程安全，UI 更新收敛到主线程）
    func log(_ level: RuntimeLogLevel, _ source: String, _ message: String) {
        let entry = RuntimeLogEntry(level: level, source: source, message: message)
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
