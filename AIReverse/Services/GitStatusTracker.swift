import Foundation

/// 文件变更类型
enum FileChangeType: String {
    case added
    case modified
    case deleted
    case untracked

    var symbol: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .untracked: return "??"
        }
    }
}

/// 单个文件的变更状态
struct FileChange: Equatable {
    let path: String
    let type: FileChangeType
}

/// 轻量 Git 状态跟踪器：
/// 通过对比「上次提交快照」与「当前工作区」计算文件状态，不依赖 git 二进制。
final class GitStatusTracker {

    private let fileManager = FileManager.default

    private var snapshotURL: URL?

    /// 绑定工作区根目录（快照存储于该目录的 .ai_backup/.git-snapshot.json）
    func bind(to workspace: WorkspaceManager) {
        snapshotURL = workspace.workspaceRoot?
            .appendingPathComponent(".ai_backup", isDirectory: true)
            .appendingPathComponent(".git-snapshot.json")
    }

    /// 保存当前快照作为「已提交基线」
    func saveSnapshot(_ snapshot: WorkspaceSnapshot) throws {
        guard let url = snapshotURL else { throw WorkspaceError.emptyPath }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// 读取上次提交基线
    func loadSnapshot() -> WorkspaceSnapshot? {
        guard let url = snapshotURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    /// 对比当前快照与提交基线，返回「已跟踪文件」的变更（modified/deleted）。
    /// 未跟踪文件通过 untrackedFiles 单独计算。
    func diff(current: WorkspaceSnapshot) -> [FileChange] {
        let baseline = loadSnapshot()?.files ?? [:]
        var changes: [FileChange] = []

        // 已删除：基线存在但当前不存在
        for path in baseline.keys where current.files[path] == nil {
            changes.append(FileChange(path: path, type: .deleted))
        }
        // 已修改：基线存在且内容变化
        for (path, state) in current.files {
            if let base = baseline[path], base != state {
                changes.append(FileChange(path: path, type: .modified))
            }
        }
        return changes.sorted { $0.path < $1.path }
    }

    /// 计算「未跟踪文件」：工作区中存在且不在基线中的文件
    func untrackedFiles(workspace: WorkspaceManager, baseline: WorkspaceSnapshot?) -> [String] {
        let base = baseline?.files ?? [:]
        guard let root = workspace.workspaceRoot else { return [] }
        var result: [String] = []
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true { continue }
                let rel = workspace.relativePath(of: url)
                if rel.hasPrefix(".ai_backup") { continue }
                if base[rel] == nil {
                    result.append(rel)
                }
            }
        }
        return result.sorted()
    }
}
