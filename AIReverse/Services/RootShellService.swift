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

    deinit {
        stop()
    }

    var isRunning: Bool { state.running }

    /// 启动 shell。默认尝试 /bin/zsh，失败时回退 /bin/sh
    func start() {
        guard !state.running else { return }
        let candidates = ["/bin/zsh", "/bin/bash", "/bin/sh"]
        for shell in candidates where FileManager.default.isExecutableFile(atPath: shell) {
            if spawn(shell: shell) {
                return
            }
        }
        state.lastError = "未找到可用的 shell（/bin/zsh、/bin/bash、/bin/sh）"
    }

    /// 向 shell 发送一行命令
    func send(_ line: String) {
        guard state.running, masterFD >= 0 else { return }
        var payload = Data(line.utf8)
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(masterFD, base, payload.count)
        }
    }

    /// 停止 shell 进程并清理资源
    func stop() {
        stopReading()
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
        DispatchQueue.main.async {
            self.state = ShellState(running: false, lastError: nil)
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

        let pid = fork()
        if pid < 0 {
            close(master)
            close(slave)
            state.lastError = "fork 失败：\(String(cString: strerror(errno)))"
            return false
        }

        if pid == 0 {
            // 子进程：挂载 PTY 为控制终端并执行 shell
            setsid()
            ioctl(slave, TIOCSCTTY, 0)
            dup2(slave, STDIN_FILENO)
            dup2(slave, STDOUT_FILENO)
            dup2(slave, STDERR_FILENO)
            if slave > STDERR_FILENO {
                close(slave)
            }
            close(master)

            setenv("TERM", "xterm-256color", 1)
            setenv("HOME", workingDirectory, 1)
            setenv("SHELL", shell, 1)
            setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/usr/bin", 1)
            chdir(workingDirectory)

            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(shell),
                strdup("-i"),
                nil
            ]
            execv(shell, &argv)
            _exit(127)
        }

        // 父进程
        close(slave)
        masterFD = master
        childPID = pid
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
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                let text = String(decoding: buffer.prefix(n), as: UTF8.self)
                DispatchQueue.main.async {
                    self.output += Self.clean(text)
                    if self.output.count > 200_000 {
                        self.output = String(self.output.suffix(100_000))
                    }
                }
            } else if n < 0 && errno != EAGAIN {
                self.readSource?.cancel()
                DispatchQueue.main.async {
                    self.state = ShellState(running: false, lastError: nil)
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

    /// 清理 PTY 原始输出中的 ANSI 控制序列，保留可读文本
    private static func clean(_ raw: String) -> String {
        var result = ""
        var index = raw.startIndex
        var skipESC = false
        while index < raw.endIndex {
            let ch = raw[index]
            if skipESC {
                if ch == "m" || ch == "n" || ch == "r" || ch == "H" || ch == "K" || ch == "J" || ch == "G" || ch == "A" || ch == "B" || ch == "C" || ch == "D" || ch == "s" || ch == "u" || ch == "f" || ch == "l" || ch == "h" {
                    skipESC = false
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
