import Foundation

// MARK: - 进程信息模型
struct ProcessInfo: Identifiable, Equatable {
    let id = UUID()
    var pid: Int32
    var name: String
    var path: String
    var isSystem: Bool
    var state: String = "S"
    var readable: Bool = true

    init(pid: Int32, name: String, path: String, isSystem: Bool) {
        self.pid = pid
        self.name = name
        self.path = path
        self.isSystem = isSystem
    }
}

// MARK: - 进程检查器（枚举所有进程 + task_for_pid 附加）
final class ProcessInspector {
    static let shared = ProcessInspector()
    private init() {}

    /// 枚举所有进程
    func listAllProcesses() -> [ProcessInfo] {
        var result: [ProcessInfo] = []
        guard let pids = listPids() else { return result }

        for pid in pids {
            guard pid > 0 else { continue }
            let info = processFor(pid: pid)
            result.append(info)
        }
        return result
    }

    /// 通过 sysctl 获取所有 PID 列表
    private func listPids() -> [pid_t]? {
        // 先获取所需大小
        var size = size_t(0)
        let mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let kr = sysctl(mib, UInt32(mib.count), nil, &size, nil, 0)
        guard kr == 0 else { return nil }
        guard size > 0 else { return nil }

        // 分配缓冲区
        let entryCount = size / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: Int(entryCount))

        let kr2 = sysctl(mib, UInt32(mib.count), &pids, &size, nil, 0)
        guard kr2 == 0 else { return nil }

        return Array(pids[..<entryCount])
    }

    /// 获取指定 PID 的信息
    func processFor(pid: Int32) -> ProcessInfo {
        let path = processPath(pid: pid)
        let name = processName(from: path)
        let isSystem = isSystemProcess(path: path)
        return ProcessInfo(pid: pid, name: name, path: path, isSystem: isSystem)
    }

    /// 通过 proc_pidpath 获取进程路径
    private func processPath(pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 512)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0, len < buf.count else { return "" }
        return String(cString: buf)
    }

    /// 从路径推导进程名称
    private func processName(from path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let baseName = url.deletingPathExtension().lastPathComponent
        return baseName
    }

    /// 判断是否为系统进程
    private func isSystemProcess(path: String) -> Bool {
        let systemPrefixes = [
            "/System/", "/usr/lib/", "/usr/sbin/", "/sbin/",
            "/usr/sbin/", "/usr/bin/", "/System/Library/",
            "/private/var/", "/bin/"
        ]
        return systemPrefixes.contains { path.hasPrefix($0) }
    }
}
