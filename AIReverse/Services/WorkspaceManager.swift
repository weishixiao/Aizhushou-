import Foundation

/// 工作区目录条目
struct WorkspaceEntry: Identifiable, Equatable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int
    let modifiedAt: Date

    var id: String { path }
}

/// 工作区快照中单个文件的状态
struct FileState: Codable, Equatable {
    var size: Int
    var modifiedAt: Date
    var contentHash: String
}

/// 工作区快照：用于对比计算 git 状态
struct WorkspaceSnapshot: Codable, Equatable {
    var files: [String: FileState]
    var branch: String
    var remoteURL: String?
    var commitHash: String
}

enum WorkspaceError: Error, LocalizedError {
    case emptyPath
    case illegalPath(String)
    case notTextFile(String)
    case readFailed(String, Error)
    case writeFailed(String, Error)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "路径为空"
        case .illegalPath(let p):
            return "非法路径：\(p)"
        case .notTextFile(let p):
            return "不是文本文件：\(p)"
        case .readFailed(let p, let e):
            return "读取失败 \(p): \(e.localizedDescription)"
        case .writeFailed(let p, let e):
            return "写入失败 \(p): \(e.localizedDescription)"
        case .notFound(let p):
            return "文件不存在：\(p)"
        }
    }
}

/// 工作区管理器：管理沙盒内工作区根目录，提供安全的文件访问。
final class WorkspaceManager: ObservableObject {
    @Published private(set) var workspaceRoot: URL?

    static let workspaceSubdir = "Workspace"
    private static let workspaceRootKey = "workspace_root_path"

    private let fileManager = FileManager.default

    init() {
        workspaceRoot = savedRoot() ?? defaultRoot()
        try? ensureWorkspaceExists()
    }

    /// 默认工作区根目录：沙盒 Documents/Workspace
    func defaultRoot() -> URL? {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent(Self.workspaceSubdir, isDirectory: true)
    }

    /// 创建默认工作区目录
    func ensureWorkspaceExists() throws {
        guard let root = workspaceRoot else { throw WorkspaceError.emptyPath }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 创建默认工作区目录并返回其 URL
    func ensureWorkspaceExistsAndReturnRoot() throws -> URL {
        guard let root = workspaceRoot else { throw WorkspaceError.emptyPath }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 切换工作区根目录（例如打开本地仓库目录）
    func setWorkspace(_ url: URL) throws {
        let dir = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.notFound(dir.path)
        }
        workspaceRoot = dir.standardizedFileURL
        UserDefaults.standard.set(dir.standardizedFileURL.path, forKey: Self.workspaceRootKey)
    }

    private func savedRoot() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.workspaceRootKey), !path.isEmpty else {
            return nil
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// 解析相对路径为工作区内的绝对 URL，拒绝路径逃逸。
    func resolve(_ relativePath: String) throws -> URL {
        guard let root = workspaceRoot else { throw WorkspaceError.emptyPath }
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.emptyPath }
        // 拒绝绝对路径
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            throw WorkspaceError.illegalPath(trimmed)
        }
        // 标准化后确认仍位于工作区内
        let full = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard full.path.hasPrefix(rootPath + "/") || full.path == rootPath else {
            throw WorkspaceError.illegalPath(trimmed)
        }
        // 逐段校验，拒绝 ".." 与符号链接逃逸
        for comp in (trimmed as NSString).pathComponents {
            if comp == ".." || comp == "." {
                throw WorkspaceError.illegalPath(trimmed)
            }
        }
        let resolved = full.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(rootPath + "/") || resolved.path == rootPath else {
            throw WorkspaceError.illegalPath(trimmed)
        }
        return resolved
    }

    /// 枚举目录内容（空路径表示根目录）
    func listFiles(relativeTo dir: String = "") throws -> [WorkspaceEntry] {
        guard let root = workspaceRoot else { throw WorkspaceError.emptyPath }
        let dirURL: URL
        if dir.trimmingCharacters(in: .whitespaces).isEmpty {
            dirURL = root
        } else {
            dirURL = try resolve(dir)
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir) else {
            throw WorkspaceError.notFound(dir)
        }
        guard isDir.boolValue else {
            throw WorkspaceError.notTextFile(dir)
        }
        let entries = try fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        )
        return entries
            .map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let rel = relativePath(of: url)
                return WorkspaceEntry(
                    name: url.lastPathComponent,
                    path: rel,
                    isDirectory: values?.isDirectory ?? false,
                    size: values?.fileSize ?? 0,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// 读取文本文件
    func readText(_ relativePath: String) throws -> String {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw WorkspaceError.notFound(relativePath)
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // 尝试按二进制读取再判断
            throw WorkspaceError.readFailed(relativePath, error)
        }
    }

    /// 读取文本文件的指定行范围
    func readText(_ relativePath: String, startLine: Int, endLine: Int) throws -> String {
        let full = try readText(relativePath)
        let lines = full.components(separatedBy: "\n")
        guard startLine >= 1, endLine >= startLine, endLine <= lines.count else {
            return full
        }
        return Array(lines[(startLine - 1)..<endLine]).joined(separator: "\n")
    }

    /// 写入文本文件（原子写入 + 备份）
    func writeText(_ relativePath: String, content: String) throws {
        guard let root = workspaceRoot else { throw WorkspaceError.emptyPath }
        let url = try resolve(relativePath)
        try backup(relativePath: relativePath, from: url)
        do {
            let tempURL = url.appendingPathExtension("tmp")
            try content.data(using: .utf8)?.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            throw WorkspaceError.writeFailed(relativePath, error)
        }
        _ = root
    }

    /// 在写入前备份原文件到 .ai_backup/
    private func backup(relativePath: String, from url: URL) throws {
        guard let root = workspaceRoot, fileManager.fileExists(atPath: url.path) else { return }
        let backupDir = root.appendingPathComponent(".ai_backup", isDirectory: true)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let backupURL = backupDir.appendingPathComponent(relativePath.replacingOccurrences(of: "/", with: "__"))
        try? fileManager.removeItem(at: backupURL)
        try fileManager.copyItem(at: url, to: backupURL)
    }

    /// 判断是否为文本文件（按内容启发式判断）
    func isTextFile(_ relativePath: String) -> Bool {
        guard let url = try? resolve(relativePath) else { return false }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        let sample = data.prefix(2048)
        for byte in sample {
            if byte == 0 { return false }
        }
        return true
    }

    /// 计算相对路径
    func relativePath(of url: URL) -> String {
        guard let root = workspaceRoot else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    /// 将外部文件导入工作区（复制到目标相对路径，目录自动创建）
    func importFile(from sourceURL: URL, to relativePath: String) throws {
        guard let root = workspaceRoot else { throw WorkspaceError.emptyPath }
        let dest = try resolve(relativePath)
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: dest.path) {
            _ = try fileManager.replaceItemAt(dest, withItemAt: sourceURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: dest)
        }
    }

    /// 读取工作区内文件原始数据（用于导出下载）
    func readData(_ relativePath: String) throws -> Data {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw WorkspaceError.notFound(relativePath)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw WorkspaceError.readFailed(relativePath, error)
        }
    }

    /// 在工作区创建目录
    func createDirectory(_ relativePath: String) throws {
        let dest = try resolve(relativePath)
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    /// 删除工作区内文件或目录（相对路径）
    func deleteItem(_ relativePath: String) throws {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw WorkspaceError.notFound(relativePath)
        }
        try fileManager.removeItem(at: url)
    }

    /// 生成工作区快照
    func snapshot(branch: String = "main", remoteURL: String? = nil, commitHash: String = "") -> WorkspaceSnapshot {
        var files: [String: FileState] = [:]
        guard let root = workspaceRoot else {
            return WorkspaceSnapshot(files: [:], branch: branch, remoteURL: remoteURL, commitHash: commitHash)
        }
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                if values?.isDirectory == true { continue }
                let rel = relativePath(of: url)
                if rel.hasPrefix(".ai_backup") { continue }
                let hash = contentHash(at: url)
                files[rel] = FileState(
                    size: values?.fileSize ?? 0,
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    contentHash: hash
                )
            }
        }
        return WorkspaceSnapshot(files: files, branch: branch, remoteURL: remoteURL, commitHash: commitHash)
    }

    /// 快速内容哈希
    private func contentHash(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        var hash = UInt64(5381)
        for byte in data.prefix(1024 * 1024) {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx-%d", hash, data.count)
    }
}
