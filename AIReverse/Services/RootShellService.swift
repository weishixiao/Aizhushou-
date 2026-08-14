import Foundation
import Darwin

/// 真实 root shell 服务：通过 PTY + fork + exec 启动交互式 shell
///
/// 运行前提（与工程 entitlements 匹配）：
/// - 设备已越狱或通过 TrollStore 安装（带 no-sandbox / platform-application 权限）
/// - 启动后可直接执行 `root` 权限命令，输入输出经由伪终端交互
final class RootShellService: ObservableObject {

    struct ShellState {
        var running = false
        var lastError: String?
    }

    @Published private(set) var output = ""
    @Published private(set) var state = ShellState()
    @Published var workingDirectory = "/var/root"

    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "rootshell.read", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "rootshell.io")

    deinit {
        stopReading()
        teardownProcess()
    }

    var isRunning: Bool { state.running }

    /// 启动 shell。默认尝试 /bin/zsh，失败时回退 /bin/sh
    func start() {
        guard !state.running else { return }
        let candidates = [
            "/var/jb/usr/bin/zsh",
            "/var/jb/usr/bin/bash",
            "/var/jb/usr/bin/sh",
            "/var/jb/bin/zsh",
            "/var/jb/bin/bash",
            "/var/jb/bin/sh",
            "/opt/procursus/bin/zsh",
            "/opt/procursus/bin/bash",
            "/opt/procursus/bin/sh",
            "/usr/local/bin/zsh",
            "/usr/local/bin/bash",
            "/usr/local/bin/sh",
            "/usr/bin/zsh",
            "/usr/bin/bash",
            "/usr/bin/sh",
            "/bin/zsh",
            "/bin/bash",
            "/bin/sh"
        ]
        for shell in candidates where FileManager.default.isExecutableFile(atPath: shell) {
            if spawn(shell: shell) {
                return
            }
        }
        state.lastError = "未找到可用的 shell。已尝试 rootless、Procursus 与系统常见路径。"
    }

    /// 向 shell 发送一行命令
    func send(_ line: String) {
        guard state.running else { return }
        var payload = Data(line.utf8)
        payload.append(0x0A)
        ioQueue.sync {
            guard masterFD >= 0 else { return }
            payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let total = payload.count
                var written = 0
                while written < total {
                    let n = write(masterFD, base + written, total - written)
                    if n > 0 {
                        written += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    /// 停止 shell 进程并清理资源
    func stop() {
        stopReading()
        teardownProcess()
        DispatchQueue.main.async { [weak self] in
            self?.state = ShellState(running: false, lastError: nil)
        }
    }

    /// 仅清理子进程与文件描述符，不触碰 UI 状态（可在 deinit 中安全调用）
    private func teardownProcess() {
        ioQueue.sync {
            let pid = childPID
            let fd = masterFD
            childPID = 0
            masterFD = -1
            if fd >= 0 {
                close(fd)
            }
            if pid > 0 {
                kill(pid, SIGHUP)
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    waitpid(pid, &status, 0)
                }
            }
        }
    }

    // MARK: - Private

    private func spawn(shell: String) -> Bool {
        var master: Int32 = -1
        var slave: Int32 = -1

        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            state.lastError = "posix_openpt 失败：\(String(cString: strerror(errno)))"
            return false
        }
        guard grantpt(master) == 0, unlockpt(master) == 0,
              let slaveName = ptsname(master) else {
            close(master)
            state.lastError = "PTY 初始化失败：\(String(cString: strerror(errno)))"
            return false
        }
        slave = open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            state.lastError = "打开 PTY 从设备失败：\(String(cString: strerror(errno)))"
            return false
        }

        setenv("TERM", "xterm-256color", 1)
        setenv("HOME", workingDirectory, 1)
        setenv("SHELL", shell, 1)
        setenv("PATH", "/var/jb/usr/bin:/var/jb/bin:/opt/procursus/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/usr/bin", 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        if slave > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, slave)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var pid: pid_t = 0
        let pathC = strdup(shell)
        let argI = strdup("-i")
        let argv: [UnsafeMutablePointer<CChar>?] = [pathC, argI, nil]
        let spawnResult = argv.withUnsafeBufferPointer { argvPtr -> Int32 in
            posix_spawn(&pid, shell, &actions, &attr, argvPtr.baseAddress, nil)
        }

        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(slave)
        free(pathC)
        free(argI)

        if spawnResult != 0 {
            close(master)
            state.lastError = "posix_spawn 失败：\(String(cString: strerror(spawnResult)))"
            return false
        }

        masterFD = master
        childPID = pid
        setWindowSize(master: master)
        state = ShellState(running: true, lastError: nil)
        startReading()
        return true
    }

    private func startReading() {
        stopReading()
        let fd = masterFD
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = self.ioQueue.sync { () -> Int in
                guard self.masterFD == fd else { return -2 }
                return read(fd, &buffer, buffer.count)
            }
            if n > 0 {
                let text = String(decoding: buffer.prefix(n), as: UTF8.self)
                DispatchQueue.main.async {
                    self.output += Self.clean(text)
                    if self.output.count > 200_000 {
                        self.output = String(self.output.suffix(100_000))
                    }
                }
            } else if n == 0 {
                self.readSource?.cancel()
                self.teardownProcess()
                DispatchQueue.main.async {
                    self.state = ShellState(running: false, lastError: "shell 已退出")
                }
            } else if n == -2 || (n < 0 && errno != EAGAIN) {
                self.readSource?.cancel()
                let err = errno
                self.teardownProcess()
                DispatchQueue.main.async {
                    self.state = ShellState(running: false, lastError: n == -2 ? "终端已关闭" : "读取终端失败：\(String(cString: strerror(err)))")
                }
            }
        }
        source.resume()
        readSource = source
    }

    private func stopReading() {
        readSource?.cancel()
        readSource = nil
    }

    /// 设置 PTY 从设备的窗口尺寸，使 shell 的终端尺寸正确
    private func setWindowSize(master: Int32) {
        var ws = winsize()
        ws.ws_row = 24
        ws.ws_col = 80
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0
        ioctl(master, TIOCSWINSZ, &ws)
    }

    /// 清理 PTY 原始输出中的 ANSI 控制序列，保留可读文本
    private static func clean(_ raw: String) -> String {
        var result = ""
        var index = raw.startIndex
        var skipESC = false
        while index < raw.endIndex {
            let ch = raw[index]
            if skipESC {
                if ch == "m" || ch == "n" || ch == "r" || ch == "H" || ch == "K" || ch == "J" || ch == "G" || ch == "A" || ch == "B" || ch == "C" || ch == "D" || ch == "s" || ch == "u" || ch == "f" || ch == "l" || ch == "h" || ch == "P" || ch == "X" || ch == "@" || ch == "`" {
                    skipESC = false
                } else if ch == "[" {
                    // CSI 序列可能包含多个中间字节，继续等待终止字符
                }
                index = raw.index(after: index)
                continue
            }
            if ch == "\u{1B}" {
                skipESC = true
                index = raw.index(after: index)
                continue
            }
            if ch == "\u{7F}" || ch == "\r" {
                index = raw.index(after: index)
                continue
            }
            result.append(ch)
            index = raw.index(after: index)
        }
        return result
    }
}
