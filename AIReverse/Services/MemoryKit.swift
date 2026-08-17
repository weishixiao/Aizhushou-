import Foundation
import Darwin
import Combine

// ============================================================
// 内存修改工具箱 Swift 封装
//
// 基于 ios_mem_toolkit C 库（Mach VM API），提供：
// - 内存扫描（u8/u16/u32/u64/f32 + AoB + 缩小搜索）
// - 内存读写
// - 代码段 Patch
// - 指针链追踪
//
// 使用方式：
//   let mt = MemoryTool()
//   let results = try await mt.scanU32(value: 1250)
//   // 或异步：mt.asyncScanU32(value: 1250)
// ============================================================

/// 扫描类型
enum MemoryScanType: String, CaseIterable, Identifiable {
    case u8 = "u8"
    case u16 = "u16"
    case u32 = "u32"
    case u64 = "u64"
    case f32 = "f32"
    case aob = "AoB"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .u8: return "8位整数"
        case .u16: return "16位整数"
        case .u32: return "32位整数"
        case .u64: return "64位整数"
        case .f32: return "32位浮点"
        case .aob: return "字节序列(AoB)"
        }
    }
    var size: Int {
        switch self {
        case .u8: return 1
        case .u16: return 2
        case .u32: return 4
        case .u64: return 8
        case .f32: return 4
        case .aob: return 0
        }
    }
}

/// 扫描结果地址
struct ScanResult: Identifiable {
    let id = UUID()
    let address: UInt64
    var currentValue: String
    var label: String = ""
}

/// 内存修改记录
struct MemoryChange: Identifiable {
    let id = UUID()
    let address: UInt64
    let oldValue: String
    let newValue: String
    let timestamp: Date = Date()
}

/// 内存工具箱主类
final class MemoryTool {
    static let shared = MemoryTool()
    private let serialQueue = DispatchQueue(label: "com.aireverse.memory")
    private var ctx = UnsafeMutablePointer<mt_ctx_t>(OpaquePointer(bitPattern: 0))

    @Published var scanResults: [ScanResult] = []
    @Published var scanCount: Int = 0
    @Published var scanType: MemoryScanType = .u32
    @Published var isScanning: Bool = false
    @Published var lastScanValue: String = ""
    @Published var changes: [MemoryChange] = []

    private init() {
        initializeContext()
    }

    /// 初始化 Mach VM 上下文（同进程）
    private func initializeContext() {
        serialQueue.sync {
            let p = UnsafeMutablePointer<mt_ctx_t>.allocate(capacity: 1)
            p.initialize(to: mt_ctx_t())
            mt_init(p, mach_task_self())
            ctx = p
        }
    }

    /// 释放上下文
    func cleanup() {
        serialQueue.sync {
            if let p = UnsafeMutablePointer<mt_ctx_t>(OpaquePointer(bitPattern: Int(bitPattern: ctx))) {
                p.deallocate()
                ctx = UnsafeMutablePointer<mt_ctx_t>(OpaquePointer(bitPattern: 0))
            }
        }
    }

    // MARK: - 同步扫描（在主线程或后台队列调用）

    /// 扫描指定值（同步）
    func scan(_ type: MemoryScanType, value: String) throws -> [UInt64] {
        return try serialQueue.sync {
            try scanSync(type, value: value)
        }
    }

    private func scanSync(_ type: MemoryScanType, value: String) throws -> [UInt64] {
        guard let ctx = ctx else { throw MemoryError.contextNotInitialized }

        switch type {
        case .u8:
            guard let v = UInt8(value) else { throw MemoryError.invalidValue }
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_u8_all(ctx, v, &rs)
            return Array(rs.addrs[0..<rs.count]).map { $0 }

        case .u16:
            guard let v = UInt16(value) else { throw MemoryError.invalidValue }
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_u16_all(ctx, v, &rs)
            return Array(rs.addrs[0..<rs.count]).map { $0 }

        case .u32:
            guard let v = UInt32(value) else { throw MemoryError.invalidValue }
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_u32_all(ctx, v, &rs)
            return Array(rs.addrs[0..<rs.count]).map { $0 }

        case .u64:
            guard let v = UInt64(value) else { throw MemoryError.invalidValue }
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_u64_all(ctx, v, &rs)
            return Array(rs.addrs[0..<rs.count]).map { $0 }

        case .f32:
            guard let v = Float(value) else { throw MemoryError.invalidValue }
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_f32_all(ctx, v, &rs)
            return Array(rs.addrs[0..<rs.count]).map { $0 }

        case .aob:
            let bytes = parseAoB(value)
            if bytes.count < 2 { throw MemoryError.invalidAoB }
            let (pattern, mask, patLen) = buildAoBMask(bytes.0, patMask: bytes.1)
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_aob_all(ctx, pattern, mask, patLen, &rs)
            return Array(rs.addrs[0..<rs.count]).map { $0 }
        }
    }

    // MARK: - 异步扫描

    /// 异步扫描（返回 Future，适合 SwiftUI 使用）
    @discardableResult
    func asyncScan(_ type: MemoryScanType, value: String, completion: @escaping (Result<[UInt64], Error>) -> Void) -> String {
        let taskId = UUID().uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            self.isScanning = true
            do {
                let results = try self.scan(type, value: value)
                self.scanType = type
                self.lastScanValue = value
                self.scanResults = results.map { addr in
                    ScanResult(address: addr, currentValue: self.readValueAt(addr, type: type) ?? "0x\(addr)")
                }
                self.scanCount = results.count
                self.isScanning = false
                completion(.success(results))
            } catch {
                self.isScanning = false
                completion(.failure(error))
            }
        }
        return taskId
    }

    // MARK: - 缩小搜索

    /// 在已有结果集上缩小搜索
    func narrowSearch(newValue: String) throws -> Int {
        return try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard !scanResults.isEmpty else { throw MemoryError.noResults }

            var rs = mt_result_set_t()
            rs.addrs = [mach_vm_address_t](scanResults.map { $0.address })
            rs.count = UInt64(scanResults.count)
            rs.capacity = UInt64(scanResults.count)

            let count: size_t
            switch scanType {
            case .u32:
                guard let v = UInt32(newValue) else { throw MemoryError.invalidValue }
                count = mt_narrow_search_u32(ctx, &rs, v)
            case .f32:
                guard let v = Float(newValue) else { throw MemoryError.invalidValue }
                count = mt_narrow_search_f32(ctx, &rs, v)
            default:
                throw MemoryError.notSupported("缩小搜索仅支持 u32 / f32")
            }

            scanResults = (0..<count).map { i in
                ScanResult(address: rs.addrs[i], currentValue: readValueAt(UInt64(rs.addrs[i]), type: scanType) ?? "0x\(rs.addrs[i])")
            }
            scanCount = count
            return count
        }
    }

    // MARK: - 内存读写

    /// 读取地址处的值（按类型解析为字符串）
    func readValueAt(_ address: UInt64, type: MemoryScanType) -> String? {
        guard let ctx = ctx else { return nil }
        return serialQueue.sync {
            switch type {
            case .u8:
                var v: UInt8 = 0
                if mt_read_u8(ctx, mach_vm_address_t(address), &v) { return "\(v)" }
            case .u16:
                var v: UInt16 = 0
                if mt_read_u16(ctx, mach_vm_address_t(address), &v) { return "\(v)" }
            case .u32:
                var v: UInt32 = 0
                if mt_read_u32(ctx, mach_vm_address_t(address), &v) { return "\(v)" }
            case .u64:
                var v: UInt64 = 0
                if mt_read_u64(ctx, mach_vm_address_t(address), &v) { return "\(v)" }
            case .f32:
                var v: Float = 0
                if mt_read_f32(ctx, mach_vm_address_t(address), &v) { return String(format: "%.4f", v) }
            case .aob:
                break
            }
            return nil
        }
    }

    /// 批量读取多个地址
    func batchReadAddresses(_ addresses: [UInt64]) -> [ScanResult] {
        guard let ctx = ctx else { return [] }
        return serialQueue.sync {
            addresses.map { addr in
                var v: UInt64 = 0
                let ok = mt_read_u64(ctx, mach_vm_address_t(addr), &v)
                let display = ok ? "\(v)" : "0x\(addr)"
                return ScanResult(address: addr, currentValue: display)
            }
        }
    }

    /// 写入 u32
    func writeU32(address: UInt64, value: UInt32) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_write_u32(ctx, mach_vm_address_t(address), value) else {
                throw MemoryError.writeFailed(address)
            }
        }
    }

    /// 写入 u64
    func writeU64(address: UInt64, value: UInt64) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_write_u64(ctx, mach_vm_address_t(address), value) else {
                throw MemoryError.writeFailed(address)
            }
        }
    }

    /// 写入 f32
    func writeF32(address: UInt64, value: Float) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_write_f32(ctx, mach_vm_address_t(address), value) else {
                throw MemoryError.writeFailed(address)
            }
        }
    }

    /// 通用写入（按扫描类型判断）
    func writeValue(address: UInt64, value: String) throws {
        let oldValue = readValueAt(address, type: scanType) ?? "unknown"

        switch scanType {
        case .u32:
            guard let v = UInt32(value) else { throw MemoryError.invalidValue }
            try writeU32(address: address, value: v)
        case .u64:
            guard let v = UInt64(value) else { throw MemoryError.invalidValue }
            try writeU64(address: address, value: v)
        case .f32:
            guard let v = Float(value) else { throw MemoryError.invalidValue }
            try writeF32(address: address, value: v)
        case .u8:
            guard let v = UInt8(value) else { throw MemoryError.invalidValue }
            try serialQueue.sync {
                guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
                guard mt_write_u8(ctx, mach_vm_address_t(address), v) else {
                    throw MemoryError.writeFailed(address)
                }
            }
        case .u16:
            guard let v = UInt16(value) else { throw MemoryError.invalidValue }
            try serialQueue.sync {
                guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
                guard mt_write_u16(ctx, mach_vm_address_t(address), v) else {
                    throw MemoryError.writeFailed(address)
                }
            }
        case .aob:
            throw MemoryError.notSupported("AoB 类型不支持直接写入，请先扫描定位")
        }

        let change = MemoryChange(address: address, oldValue: oldValue, newValue: value)
        changes.insert(change, at: 0)
    }

    // MARK: - 指针链追踪

    /// 从 base 地址跟踪指针链
    func followPointer(base: UInt64, offsets: [UInt64]) throws -> UInt64 {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            var outAddr: mach_vm_address_t = 0
            let result = mt_follow_pointer(ctx, mach_vm_address_t(base),
                                            offsets, offsets.count, &outAddr)
            guard result else { throw MemoryError.pointerChainFailed(base) }
            return UInt64(outAddr)
        }
    }

    // MARK: - 代码段 Patch

    /// 保存原始指令
    func saveInstructions(address: UInt64, count: Int) throws -> [UInt32] {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            var saved = [UInt32](repeating: 0, count: count)
            guard mt_patch_save(ctx, mach_vm_address_t(address), UInt(count), &saved) else {
                throw MemoryError.patchFailed(address)
            }
            return saved
        }
    }

    /// Patch return zero（MOV X0,#0; RET）
    func patchReturnZero(address: UInt64) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_patch_return_zero(ctx, mach_vm_address_t(address)) else {
                throw MemoryError.patchFailed(address)
            }
        }
    }

    /// Patch return one
    func patchReturnOne(address: UInt64) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_patch_return_one(ctx, mach_vm_address_t(address)) else {
                throw MemoryError.patchFailed(address)
            }
        }
    }

    /// Patch NOP
    func patchNOP(address: UInt64) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_patch_nop(ctx, mach_vm_address_t(address)) else {
                throw MemoryError.patchFailed(address)
            }
        }
    }

    // MARK: - 枚举可读写区域

    /// 枚举所有可读写内存区域（用于分析进程内存布局）
    func enumerateRegions() -> [(address: UInt64, size: UInt64)] {
        guard let ctx = ctx else { return [] }
        var regions: [(UInt64, UInt64)] = []
        serialQueue.sync {
            mt_enumerate_rw_regions(ctx, { addr, size, userData in
                let arr = UnsafeMutablePointer<[(UInt64, UInt64)]>(userData!)
                arr!.pointee.append((UInt64(addr), UInt64(size)))
            }, &regions)
        }
        return regions
    }

    // MARK: - AoB 解析

    private func parseAoB(_ input: String) -> ([UInt8], [UInt8]) {
        // 支持格式: "FF 00 ?" 或 "FF00?" 或 "FF 00 ???"
        let cleaned = input.trimmingCharacters(in: .whitespaces)
        let tokens = cleaned.split { $0.isWhitespace }.map { String($0) }

        var pattern: [UInt8] = []
        var mask: [UInt8] = []

        for token in tokens {
            let chars = Array(token)
            let byteCount = chars.count / 2
            for i in 0..<byteCount {
                let hexChars = String(chars[i*2...(i*2+1)])
                if hexChars == "??" {
                    pattern.append(0)
                    mask.append(0)  // 通配
                } else {
                    if let v = UInt8(hexChars, radial: 16) {
                        pattern.append(v)
                        mask.append(0xFF)
                    }
                }
            }
        }
        return (pattern, mask)
    }

    private func buildAoBMask(_ pattern: [UInt8], patMask: [UInt8]) -> ([UInt8], [UInt8], UInt) {
        var outMask = [UInt8](repeating: 0, count: pattern.count)
        for i in 0..<pattern.count {
            if patMask[i] != 0 {
                outMask[i] = 0xFF
            }
        }
        return (pattern, outMask, UInt(pattern.count))
    }
}

/// 内存工具箱错误
enum MemoryError: Error, LocalizedError {
    case contextNotInitialized
    case invalidValue
    case invalidAoB
    case noResults
    case writeFailed(UInt64)
    case notSupported(String)
    case pointerChainFailed(UInt64)
    case patchFailed(UInt64)

    var errorDescription: String? {
        switch self {
        case .contextNotInitialized: return "Mach VM 上下文未初始化"
        case .invalidValue: return "无效的值"
        case .invalidAoB: return "无效的 AoB 格式"
        case .noResults: return "无扫描结果"
        case .writeFailed(let addr): return "写入失败: 0x\(addr)"
        case .notSupported(let msg): return msg
        case .pointerChainFailed(let base): return "指针链追踪失败: 0x\(base)"
        case .patchFailed(let addr): return "代码 Patch 失败: 0x\(addr)"
        }
    }
}

// UInt8 十六进制解析扩展
extension UInt8 {
    init?(_ hex: String, radial: Int) {
        guard let v = UInt8(hex, radix: radial) else { return nil }
        self = v
    }
}