import Foundation

/// 根工具可用性检测
enum RootExecutionEnvironment {
    static var supportsRootTools: Bool {
        let shellPaths = [
            "/bin/zsh",
            "/bin/bash",
            "/bin/sh",
            "/var/jb/bin/zsh",
            "/var/jb/bin/bash",
            "/var/jb/bin/sh"
        ]
        return shellPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
