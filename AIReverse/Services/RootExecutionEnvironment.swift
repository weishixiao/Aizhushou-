import Foundation
import Darwin

/// 根工具可用性检测
enum RootExecutionEnvironment {
    static var supportsRootTools: Bool {
        hasExecutableShell || hasJailbreakIndicators || getuid() == 0
    }

    private static var hasExecutableShell: Bool {
        let shellPaths = [
            "/bin/zsh",
            "/bin/bash",
            "/bin/sh",
            "/var/jb/bin/zsh",
            "/var/jb/bin/bash",
            "/var/jb/bin/sh",
            "/var/jb/usr/bin/zsh",
            "/var/jb/usr/bin/bash",
            "/var/jb/usr/bin/sh",
            "/usr/bin/zsh",
            "/usr/bin/bash",
            "/usr/bin/sh",
            "/usr/local/bin/zsh",
            "/usr/local/bin/bash",
            "/usr/local/bin/sh",
            "/opt/procursus/bin/zsh",
            "/opt/procursus/bin/bash",
            "/opt/procursus/bin/sh"
        ]
        return shellPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var hasJailbreakIndicators: Bool {
        let paths = [
            "/var/jb",
            "/var/jb/usr",
            "/var/jb/Applications/Sileo.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/lib/libjailbreak.dylib",
            "/private/preboot"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
