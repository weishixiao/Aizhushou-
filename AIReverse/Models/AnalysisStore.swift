import Foundation

struct AnalysisResult {
    var url: URL
    var macho: MachOInfo
    var objcClasses: [ObjCClassInfo] = []
    var symbols: [SymbolEntry] = []
    var disassembly: [DisasmLine] = []
    var date = Date()

    var summary: String {
        var lines: [String] = []
        lines.append("文件: \(url.lastPathComponent)")
        lines.append("架构: \(macho.architectures.map(\.cpuType).joined(separator: ", "))")
        lines.append("ObjC 类: \(macho.objcClassCount)  符号: \(macho.symbolCount)  字符串: \(macho.strings.count)")
        return lines.joined(separator: "\n")
    }

    /// 供聊天助手作为上下文注入的完整分析文本
    var contextText: String {
        var text = summary
        let dylibs = macho.loadCommands.filter { $0.contains("DYLIB") }
        if !dylibs.isEmpty {
            text += "\n\n=== 动态库相关命令（前 80 条）===\n"
            text += dylibs.prefix(80).joined(separator: "\n")
        }
        let interestingStrings = prioritizedStrings.filter(isInterestingReverseString)
        if !interestingStrings.isEmpty {
            text += "\n\n=== 可疑/关键字符串（前 120 条）===\n"
            text += interestingStrings.prefix(120).joined(separator: "\n")
        }
        let keySymbols = symbols.filter { isInterestingReverseString($0.name) }
        if !keySymbols.isEmpty {
            text += "\n\n=== 关键符号（前 120 条）===\n"
            text += keySymbols.prefix(120).map {
                String(format: "0x%08llX %@ %@", $0.address, $0.type, $0.name)
            }.joined(separator: "\n")
        }
        if !macho.strings.isEmpty {
            text += "\n\n=== 提取的字符串（前 100 条）===\n"
            text += prioritizedStrings.prefix(100).joined(separator: "\n")
        }
        if !objcClasses.isEmpty {
            text += "\n\n=== ObjC 类与关键方法（前 50 个类）===\n"
            text += objcClasses.prefix(50).map { cls in
                var line = "\(cls.name)"
                if !cls.superclassName.isEmpty { line += " : \(cls.superclassName)" }
                let methods = cls.methods.prefix(15).map(\.selector).joined(separator: ", ")
                if !methods.isEmpty { line += "  [\(methods)]" }
                return line
            }.joined(separator: "\n")
        }
        if !disassembly.isEmpty {
            text += "\n\n=== __text 反汇编片段（前 300 行）===\n"
            text += disassembly.prefix(300).map {
                String(format: "0x%08llX: %@", $0.address, $0.text)
            }.joined(separator: "\n")
        }
        return text
    }

    private var prioritizedStrings: [String] {
        macho.strings.sorted { left, right in
            let leftScore = reverseSignalScore(left)
            let rightScore = reverseSignalScore(right)
            if leftScore == rightScore { return left.count < right.count }
            return leftScore > rightScore
        }
    }

    private func isInterestingReverseString(_ value: String) -> Bool {
        reverseSignalScore(value) > 0
    }

    private func reverseSignalScore(_ value: String) -> Int {
        let lower = value.lowercased()
        let weightedKeywords: [(String, Int)] = [
            ("http://", 8), ("https://", 8), ("api", 5), ("token", 6), ("secret", 6),
            ("password", 6), ("auth", 5), ("login", 4), ("sign", 4), ("encrypt", 5),
            ("decrypt", 5), ("key", 4), ("jailbreak", 7), ("cydia", 7), ("substrate", 7),
            ("frida", 7), ("ptrace", 7), ("sysctl", 6), ("ssl", 5), ("certificate", 5),
            ("pinning", 6), ("sqlite", 4), ("webview", 4), ("scheme", 3), ("callback", 3)
        ]
        return weightedKeywords.reduce(0) { score, item in
            lower.contains(item.0) ? score + item.1 : score
        }
    }
}

struct DisasmLine {
    var address: UInt64 = 0
    var bytes: [UInt8] = []
    var text: String = ""
}

/// 已导入沙盒的文件记录（持久化）
struct ImportedFile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: URL
    var date = Date()
}

final class AnalysisStore: ObservableObject {
    @Published var results: [AnalysisResult] = []
    @Published var activeResult: AnalysisResult?
    @Published var importedFiles: [ImportedFile] = []

    private let storageKey = "ai_imported_files_v1"

    init() {
        loadImportedFiles()
    }

    func add(_ result: AnalysisResult) {
        results.append(result)
        activeResult = result
    }

    func clear() {
        results.removeAll()
        activeResult = nil
    }

    /// 把文件复制进沙盒并记录；已存在同名文件则直接复用
    func importFile(from source: URL) throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("ImportedFiles", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let dest = dir.appendingPathComponent(source.lastPathComponent)
        if !fm.fileExists(atPath: dest.path) {
            try fm.copyItem(at: source, to: dest)
        }

        let record = ImportedFile(name: source.lastPathComponent, url: dest)
        if !importedFiles.contains(where: { $0.url == dest }) {
            importedFiles.insert(record, at: 0)
            saveImportedFiles()
        }
        return dest
    }

    func loadImportedFile(_ file: ImportedFile) {
        // 沙盒内文件通常仍存在；若被系统清理则尝试重新读
        guard fm.fileExists(atPath: file.url.path) else { return }
        // 重新触发一次分析由调用方处理；这里仅记录最近使用的文件
        if let idx = importedFiles.firstIndex(where: { $0.id == file.id }) {
            importedFiles.remove(at: idx)
            importedFiles.insert(file, at: 0)
            saveImportedFiles()
        }
    }

    func removeImportedFile(_ file: ImportedFile) {
        importedFiles.removeAll { $0.id == file.id }
        if activeResult?.url == file.url {
            activeResult = nil
        }
        // 删除沙盒副本
        if fm.fileExists(atPath: file.url.path) {
            try? fm.removeItem(at: file.url)
        }
        saveImportedFiles()
    }

    private let fm = FileManager.default

    private func loadImportedFiles() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ImportedFile].self, from: data) else { return }
        importedFiles = decoded
    }

    private func saveImportedFiles() {
        if let data = try? JSONEncoder().encode(importedFiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
