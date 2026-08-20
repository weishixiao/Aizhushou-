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
        guard let count = getPidCount() else { return result }

        guard count > 0 else { return result }

        var pids = [pid_t](repeating: 0, count: Int(count) + 1)
        let actualCount = getPidCount(into: &pids)
        let total = min(Int(actualCount), pids.count - 1)

        for i in 0..<total {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let procInfo = resolveProcess(pid: pid)
            result.append(procInfo)
        }
        return result
    }

    /// 获取指定 PID 的信息
    func processFor(pid: Int32) -> ProcessInfo? {
        var nameBuf = [CChar](repeating: 0, count: 256)
        let nameLen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        let name = nameLen > 0 ? String(cString: nameBuf) : ""

        var pathBuf = [CChar](repeating: 0, count: MAXPATHLEN)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path = pathLen > 0 ? String(cString: pathBuf) : ""

        let isSystem = path.hasPrefix("/System/") ||
                        path.hasPrefix("/usr/lib/") ||
                        path.hasPrefix("/usr/sbin/") ||
                        path.hasPrefix("/sbin/")

        return ProcessInfo(pid: pid, name: name, path: path, isSystem: isSystem)
    }

    private func resolveProcess(pid: Int32) -> ProcessInfo {
        var nameBuf = [CChar](repeating: 0, count: 256)
        let nameLen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        let name = nameLen > 0 ? String(cString: nameBuf) : ""

        var pathBuf = [CChar](repeating: 0, count: MAXPATHLEN)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path = pathLen > 0 ? String(cString: pathBuf) : ""

        let isSystem = path.hasPrefix("/System/") ||
                        path.hasPrefix("/usr/lib/") ||
                        path.hasPrefix("/usr/sbin/") ||
                        path.hasPrefix("/sbin/")

        return ProcessInfo(pid: pid, name: name, path: path, isSystem: isSystem)
    }

    private func getPidCount() -> Int32? {
        var count: Int32 = 0
        let kr = sysctl(_psargs: ["kern.proc.pidcount"], value: &count)
        return kr == 0 ? count : nil
    }

    private func getPidCount(into buffer: inout [pid_t]) -> Int32 {
        var size = MemoryLayout<pid_t>.size * buffer.count
        var kr: Int32 = 0
        let mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        kr = sysctl(_psargs: mib, oldp: &buffer, oldlenp: &size)
        return kr == 0 ? Int32(size / MemoryLayout<pid_t>.size) : 0
    }
}