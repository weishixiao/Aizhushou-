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
        if !macho.strings.isEmpty {
            text += "\n\n=== 提取的字符串（前 100 条）===\n"
            text += macho.strings.prefix(100).joined(separator: "\n")
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
