import Foundation
import Darwin

/// 与 RootService 后台服务通信的 Socket 客户端。
///
/// 架构说明（适配 iOS17 RootHide/Relaxin）：
/// - 主 App（mobile 身份）：正常桌面打开，显示 SwiftUI 界面
/// - RootService（root 身份）：独立 C 二进制，通过 NewTerm 手动启动
/// - 通信方式：UNIX 本地域 Socket（/var/mobile/Library/aireverse_service.sock）
///
/// 所有高权限操作（task_for_pid、Frida 附加、进程遍历、代码注入、Mach-O 解析）
/// 都由 RootService 以 root 身份执行，主 App 通过 Socket 发送指令并接收结果。
final class RootServiceClient {
    static let shared = RootServiceClient()

    private let socketPath = "/var/mobile/Library/aireverse_service.sock"
    private var fd: Int32 = -1
    private let bufferSize = 65536

    private init() {}

    /// 是否已连接
    var isConnected: Bool { fd > 0 }

    /// 连接 RootService
    func connect() throws {
        if fd > 0 { return }
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw RootServiceError.socketCreateFailed(errno)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            strcpy(ptr, socketPath)
        }
        let len = MemoryLayout<sockaddr_un>.stride
        let ret = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(sock, sockaddrPtr, socklen_t(len))
            }
        }
        guard ret == 0 else {
            close(sock)
            throw RootServiceError.connectFailed(errno)
        }
        fd = sock
    }

    /// 发送指令并等待返回结果
    @discardableResult
    func sendCommand(_ command: String) throws -> String {
        guard fd > 0 else { throw RootServiceError.notConnected }

        // 发送指令
        let cmdData = command.data(using: .utf8)!
        let writeLen = cmdData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, cmdData.count)
        }
        guard writeLen == cmdData.count else {
            throw RootServiceError.writeFailed(errno)
        }

        // 读取返回
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let readLen = read(fd, &buffer, bufferSize)
        guard readLen > 0 else {
            throw RootServiceError.readFailed(errno)
        }
        return String(bytes: buffer[0..<readLen], encoding: .utf8) ?? ""
    }

    /// 关闭连接
    func disconnect() {
        if fd > 0 {
            close(fd)
            fd = -1
        }
    }

    /// 检查 RootService 是否在运行
    var isServiceRunning: Bool {
        do {
            try connect()
            let reply = try sendCommand("CMD_PING")
            disconnect()
            return reply == "PONG"
        } catch {
            return false
        }
    }

    /// 尝试连接并发送单条指令（自动连接/断开）
    @discardableResult
    func execute(_ command: String) throws -> String {
        try connect()
        let result = try sendCommand(command)
        disconnect()
        return result
    }
}

enum RootServiceError: LocalizedError {
    case socketCreateFailed(Int32)
    case connectFailed(Int32)
    case notConnected
    case writeFailed(Int32)
    case readFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreateFailed(let e):
            return "创建 Socket 失败 (errno=\(e))"
        case .connectFailed(let e):
            return "无法连接 RootService，请先在 NewTerm 中启动服务\n(错误码: \(e))"
        case .notConnected:
            return "未连接 RootService"
        case .writeFailed(let e):
            return "写入 Socket 失败 (errno=\(e))"
        case .readFailed(let e):
            return "读取 Socket 返回失败 (errno=\(e))"
        }
    }
}