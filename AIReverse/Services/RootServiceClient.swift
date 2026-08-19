import Foundation
import Darwin

/// 与 RootService 后台服务通信的 Socket 客户端。
///
/// 架构说明（适配 iOS17 RootHide/Relaxin）：
/// - 主 App（mobile 身份）：正常桌面打开，显示 SwiftUI 界面
/// - RootService（root 身份）：独立 C 二进制，通过 NewTerm 手动启动
/// - 通信方式：UNIX 本地域 Socket（/var/mobile/Library/aireverse_service.sock）
///
/// 【安全加固说明】
/// 为了避免破坏既有调用方（InjectionManager / MutatingTools 等调用 `execute("CMD_SHELL ...")` 返回 String），
/// 本类保留原有公开方法签名（connect / sendCommand / disconnect / execute -> String / isServiceRunning），
/// 仅做两项向后兼容的加固：
///  1. 若已配置共享密钥（Keychain `aireverse.service.secret`），在连接后自动完成 AUTH 握手，
///     密钥不一致则抛错，不向下游返回不可信结果；
///  2. 新增 `executeStructured(_:) -> CommandResult`，用于需要读取真实退出码的新路径。
/// 未配置密钥时保持旧行为（兼容旧 RootService 二进制），由服务端选择是否强制鉴权。
final class RootServiceClient {
    static let shared = RootServiceClient()

    private let socketPath = "/var/mobile/Library/aireverse_service.sock"
    private var fd: Int32 = -1
    private let bufferSize = 65536
    /// 已完成 AUTH 握手
    private var authed = false

    /// 可选结果结构（供新路径使用）
    struct CommandResult {
        let exitCode: Int
        let output: String
        var success: Bool { exitCode == 0 }
    }

    private init() {}

    /// 是否已连接
    var isConnected: Bool { fd > 0 }

    /// 从 Keychain 读取共享密钥（未配置返回空串）
    private var serviceSecret: String {
        KeychainStore.shared.read("aireverse.service.secret") ?? ""
    }

    /// 连接 RootService（若配置了密钥则自动尝试 AUTH 握手）
    func connect() throws {
        if fd > 0 {
            // 已连接但尚未握手且配置了密钥 → 补握手
            if !authed {
                let secret = serviceSecret
                if !secret.isEmpty {
                    try performAuth(secret)
                }
            }
            return
        }
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
            let error = RootServiceError.connectFailed(errno)
            RuntimeLogger.shared.warning("RootService", "\(error.localizedDescription)\nsocket路径: \(socketPath)")
            // 附加提示信息
            if errno == 2 {
                RuntimeLogger.shared.warning("RootService", "提示：root_service 二进制可能未编译或未安装\n在 NewTerm 中执行: cd /path/to/root_service && bash build.sh")
            }
            throw error
        }
        fd = sock
        // 若配置了密钥，握手；未配置则维持旧行为。握手失败会抛错并清理连接。
        let secret = serviceSecret
        if !secret.isEmpty {
            try performAuth(secret)
        }
    }

    /// 发送 AUTH 握手帧并校验服务端响应
    private func performAuth(_ secret: String) throws {
        guard fd > 0 else { throw RootServiceError.notConnected }
        let authData = ("AUTH \(secret)\n").data(using: .utf8)!
        _ = try rawSend(authData)
        let reply = try rawRead()
        guard reply.hasPrefix("AUTH_OK") else {
            disconnect()
            throw RootServiceError.authFailed
        }
        authed = true
    }

    /// 发送指令并等待返回结果（旧协议：直接返回服务端输出文本）
    @discardableResult
    func sendCommand(_ command: String) throws -> String {
        guard fd > 0 else { throw RootServiceError.notConnected }
        let reply = try rawSendAndRead(command.data(using: .utf8)!)
        // 若服务端返回 EXIT 协议，剥离首行后返回正文（兼容加固版服务端）
        if reply.hasPrefix("EXIT ") {
            return stripExitLine(reply)
        }
        return reply
    }

    /// 关闭连接
    func disconnect() {
        if fd > 0 {
            close(fd)
            fd = -1
        }
        authed = false
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

    /// 尝试连接并发送单条指令（自动连接/断开，旧接口，返回字符串）
    @discardableResult
    func execute(_ command: String) throws -> String {
        try connect()
        let result = try sendCommand(command)
        disconnect()
        return result
    }

    // MARK: - 进程管理命令

    /// 获取运行中进程列表
    func listProcesses() throws -> String {
        return try execute("CMD_PROCESS_LIST")
    }

    // MARK: - Frida 命令

    /// 检查 Frida 状态
    func checkFrida() throws -> String {
        return try execute("CMD_FRIDA_CHECK")
    }

    /// 启动 frida-server
    func startFrida() throws -> String {
        return try execute("CMD_FRIDA_START")
    }

    /// 执行 Frida 脚本
    func execFrida(target: String, scriptPath: String) throws -> String {
        return try execute("CMD_FRIDA_EXEC \(target) \(scriptPath)")
    }

    // MARK: - 抓包命令

    /// 启动抓包
    func startPcap(interface: String, filter: String) throws -> String {
        return try execute("CMD_PCAP_START \(interface) \(filter)")
    }

    /// 停止抓包
    func stopPcap() throws -> String {
        return try execute("CMD_PCAP_STOP")
    }

    /// 列出抓包文件
    func listPcapFiles() throws -> String {
        return try execute("CMD_PCAP_LIST")
    }

    // MARK: - 文件读写命令

    /// 读取文件（用于存档修改）
    func readFile(_ path: String) throws -> String {
        return try execute("CMD_FILE_READ \(path)")
    }

    /// 写入文件（base64 编码内容）
    func writeFile(_ path: String, base64Content: String) throws -> String {
        return try execute("CMD_FILE_WRITE \(path) \(base64Content)")
    }

    /// 新增：执行并返回结构化退出码（用于需要真实成败判断的新路径）
    @discardableResult
    func executeStructured(_ command: String) throws -> CommandResult {
        try connect()
        let reply = try rawSendAndRead(command.data(using: .utf8)!)
        disconnect()
        if reply.hasPrefix("EXIT ") {
            return CommandResult(exitCode: extractExitCode(reply), output: stripExitLine(reply))
        }
        // 旧服务端 / 无 EXIT 帧：退出码未知，按 -1 处理（不要默认 0）
        return CommandResult(exitCode: -1, output: reply)
    }

    // MARK: - 低层 IO

    @discardableResult
    private func rawSend(_ data: Data) throws -> Int {
        guard fd > 0 else { throw RootServiceError.notConnected }
        let writeLen = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, data.count)
        }
        guard writeLen == data.count else {
            throw RootServiceError.writeFailed(errno)
        }
        return writeLen
    }

    private func rawRead() throws -> String {
        guard fd > 0 else { throw RootServiceError.notConnected }
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let readLen = read(fd, &buffer, bufferSize)
        guard readLen > 0 else {
            throw RootServiceError.readFailed(errno)
        }
        return String(bytes: buffer[0..<readLen], encoding: .utf8) ?? ""
    }

    private func rawSendAndRead(_ data: Data) throws -> String {
        _ = try rawSend(data)
        return try rawRead()
    }

    /// 从 "EXIT <code>\n<body>" 剥离第一行，返回 body
    private func stripExitLine(_ reply: String) -> String {
        guard let nl = reply.firstIndex(of: "\n") else { return "" }
        return String(reply[reply.index(after: nl)...])
    }

    /// 解析 "EXIT <code>" 的退出码
    private func extractExitCode(_ reply: String) -> Int {
        let firstLine = reply.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let digits = firstLine.dropFirst("EXIT ".count)
        return Int(digits.trimmingCharacters(in: .whitespaces)) ?? -1
    }
}

enum RootServiceError: LocalizedError {
    case socketCreateFailed(Int32)
    case connectFailed(Int32)
    case notConnected
    case writeFailed(Int32)
    case readFailed(Int32)
    case authFailed

    var errorDescription: String? {
        switch self {
        case .socketCreateFailed(let e):
            return "创建 Socket 失败 (\(errnoName(e)), errno=\(e))"
        case .connectFailed(let e):
            return "无法连接 RootService (\(errnoName(e)), errno=\(e))\nsocket: /var/mobile/Library/aireverse_service.sock\n请先在 NewTerm 中启动服务"
        case .notConnected:
            return "未连接 RootService"
        case .writeFailed(let e):
            return "写入 Socket 失败 (\(errnoName(e)), errno=\(e))"
        case .readFailed(let e):
            return "读取 Socket 返回失败 (\(errnoName(e)), errno=\(e))"
        case .authFailed:
            return "RootService 鉴权失败（共享密钥不匹配或服务端要求鉴权）"
        }
    }

    /// 将 errno 转换为可读名称
    private func errnoName(_ e: Int32) -> String {
        switch e {
        case 2:     return "ENOENT（服务未运行）"
        case 111:   return "ECONNREFUSED（连接被拒绝）"
        case 110:   return "ETIMEDOUT（连接超时）"
        case 13:    return "EACCES（权限不足）"
        case 1:     return "EPERM（操作不允许）"
        case 11:    return "EAGAIN（资源暂不可用）"
        default:    return "未知错误"
        }
    }
}
