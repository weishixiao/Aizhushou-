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
    private var ctxPtr: OpaquePointer?

    @Published var scanResults: [ScanResult] = []
    @Published var scanCount: Int = 0
    @Published var scanType: MemoryScanType = .u32
    @Published var isScanning: Bool = false
    @Published var lastScanValue: String = ""
    @Published var changes: [MemoryChange] = []

    private init() {
        initializeContext()
    }

    deinit {
        cleanup()
    }

    private func initializeContext() {
        serialQueue.sync {
            let p = UnsafeMutablePointer<mt_ctx_t>.allocate(capacity: 1)
            p.initialize(to: mt_ctx_t())
            mt_init(p, mach_task_self())
            ctxPtr = OpaquePointer(p)
        }
    }

    func cleanup() {
        serialQueue.sync {
            if let p = ctxPtr {
                let ptr = OpaquePointer(p).assumingMemoryBound(to: mt_ctx_t.self)
                ptr.deallocate()
                ctxPtr = nil
            }
        }
    }

    private var ctx: UnsafeMutablePointer<mt_ctx_t>? {
        guard let p = ctxPtr else { return nil }
        return OpaquePointer(p).assumingMemoryBound(to: mt_ctx_t.self)
    }

    // MARK: - 同步扫描

    func scan(_ type: MemoryScanType, value: String) throws -> [UInt64] {
        return try serialQueue.sync { try scanSync(type, value: value) }
    }

    private func scanSync(_ type: MemoryScanType, value: String) throws -> [UInt64] {
        guard let ctx = ctx else { throw MemoryError.contextNotInitialized }

        switch type {
        case .u8:
            let v = try parseUInt8(value)
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_u8_all(ctx, v, &rs)
            return collectResult(&rs)

        case .u16:
            let v = try parseUInt16(value)
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_u16_all(ctx, v, &rs)
            return collectResult(&rs)

        case .u32:
            let v = try parseUInt32(value)
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_u32_all(ctx, v, &rs)
            return collectResult(&rs)

        case .u64:
            let v = try parseUInt64(value)
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_u64_all(ctx, v, &rs)
            return collectResult(&rs)

        case .f32:
            guard let v = Float(value) else { throw MemoryError.invalidValue }
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_f32_all(ctx, v, &rs)
            return collectResult(&rs)

        case .aob:
            let (pattern, mask, patLen) = parseAoB(value)
            if pattern.count < 2 { throw MemoryError.invalidAoB }
            var rs = mt_result_set_t()
            mt_result_init(&rs)
            defer { mt_result_free(&rs) }
            mt_scan_aob_all(ctx, pattern, mask, patLen, &rs)
            return collectResult(&rs)
        }
    }

    // MARK: - 数值解析（支持十进制和十六进制 0x）

    private func parseUInt8(_ value: String) throws -> UInt8 {
        if let v = UInt8(value) { return v }
        guard let v = UInt8(stripHexPrefix(value), radix: 16) else { throw MemoryError.invalidValue }
        return v
    }

    private func parseUInt16(_ value: String) throws -> UInt16 {
        if let v = UInt16(value) { return v }
        guard let v = UInt16(stripHexPrefix(value), radix: 16) else { throw MemoryError.invalidValue }
        return v
    }

    private func parseUInt32(_ value: String) throws -> UInt32 {
        if let v = UInt32(value) { return v }
        guard let v = UInt32(stripHexPrefix(value), radix: 16) else { throw MemoryError.invalidValue }
        return v
    }

    private func parseUInt64(_ value: String) throws -> UInt64 {
        if let v = UInt64(value) { return v }
        guard let v = UInt64(stripHexPrefix(value), radix: 16) else { throw MemoryError.invalidValue }
        return v
    }

    private func stripHexPrefix(_ value: String) -> String {
        let s = value.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
    }

    private func collectResult(_ rs: UnsafeMutablePointer<mt_result_set_t>) -> [UInt64] {
        if rs.pointee.count == 0 { return [] }
        var result = [UInt64]()
        result.reserveCapacity(Int(rs.pointee.count))
        for i in 0..<rs.pointee.count {
            result.append(UInt64(rs.pointee.addrs[Int(i)]))
        }
        return result
    }

    // MARK: - 异步扫描

    func asyncScan(_ type: MemoryScanType, value: String, completion: @escaping (Result<[UInt64], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.isScanning = true
            do {
                let addrs = try self.scan(type, value: value)
                self.scanType = type
                self.lastScanValue = value
                self.scanResults = addrs.map { addr in
                    ScanResult(address: addr, currentValue: self.readValueAt(addr, type: type) ?? "0x\(addr, radix: 16)")
                }
                self.scanCount = addrs.count
                self.isScanning = false
                completion(.success(addrs))
            } catch {
                self.isScanning = false
                completion(.failure(error))
            }
        }
    }

    // MARK: - 缩小搜索

    func narrowSearch(newValue: String) throws -> Int {
        return try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard !scanResults.isEmpty else { throw MemoryError.noResults }

            var rs = mt_result_set_t()
            rs.addrs = UnsafeMutablePointer<mach_vm_address_t>.allocate(capacity: Int(scanResults.count))
            rs.count = UInt64(scanResults.count)
            rs.capacity = UInt64(scanResults.count)
            for i, r in scanResults.enumerated() {
                rs.addrs[Int(i)] = mach_vm_address_t(r.address)
            }

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

            var results = [ScanResult]()
            results.reserveCapacity(Int(count))
            for i in 0..<count {
                results.append(ScanResult(
                    address: UInt64(rs.addrs[Int(i)]),
                    currentValue: readValueAt(UInt64(rs.addrs[Int(i)]), type: scanType) ?? "0x\(rs.addrs[Int(i)], radix: 16)"
                ))
            }
            rs.addrs.deallocate()
            scanResults = results
            scanCount = results.count
            return results.count
        }
    }

    // MARK: - 内存读写

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
            case .aob: break
            }
            return nil
        }
    }

    func writeU32(address: UInt64, value: UInt32) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_write_u32(ctx, mach_vm_address_t(address), value) else {
                throw MemoryError.writeFailed(address)
            }
        }
    }

    func writeU64(address: UInt64, value: UInt64) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_write_u64(ctx, mach_vm_address_t(address), value) else {
                throw MemoryError.writeFailed(address)
            }
        }
    }

    func writeF32(address: UInt64, value: Float) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_write_f32(ctx, mach_vm_address_t(address), value) else {
                throw MemoryError.writeFailed(address)
            }
        }
    }

    func writeU8(address: UInt64, value: UInt8) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_write_u8(ctx, mach_vm_address_t(address), value) else {
                throw MemoryError.writeFailed(address)
            }
        }
    }

    func writeU16(address: UInt64, value: UInt16) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_write_u16(ctx, mach_vm_address_t(address), value) else {
                throw MemoryError.writeFailed(address)
            }
        }
    }

    func writeValue(address: UInt64, value: String) throws {
        let oldValue = readValueAt(address, type: scanType) ?? "unknown"

        switch scanType {
        case .u32:
            let v = try parseUInt32(value)
            try writeU32(address: address, value: v)
        case .u64:
            let v = try parseUInt64(value)
            try writeU64(address: address, value: v)
        case .f32:
            guard let v = Float(value) else { throw MemoryError.invalidValue }
            try writeF32(address: address, value: v)
        case .u8:
            let v = try parseUInt8(value)
            try writeU8(address: address, value: v)
        case .u16:
            let v = try parseUInt16(value)
            try writeU16(address: address, value: v)
        case .aob:
            throw MemoryError.notSupported("AoB 类型不支持直接写入，请先扫描定位")
        }

        let change = MemoryChange(address: address, oldValue: oldValue, newValue: value)
        changes.insert(change, at: 0)
    }

    // MARK: - 指针链追踪

    func followPointer(base: UInt64, offsets: [UInt64]) throws -> UInt64 {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            var outAddr: mach_vm_address_t = 0
            let result = mt_follow_pointer(ctx, mach_vm_address_t(base),
                                            UnsafePointer<uint64_t>(offsets), offsets.count, &outAddr)
            guard result else { throw MemoryError.pointerChainFailed(base) }
            return UInt64(outAddr)
        }
    }

    // MARK: - 代码段 Patch

    func patchReturnZero(address: UInt64) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_patch_return_zero(ctx, mach_vm_address_t(address)) else {
                throw MemoryError.patchFailed(address)
            }
        }
    }

    func patchReturnOne(address: UInt64) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_patch_return_one(ctx, mach_vm_address_t(address)) else {
                throw MemoryError.patchFailed(address)
            }
        }
    }

    func patchNOP(address: UInt64) throws {
        try serialQueue.sync {
            guard let ctx = ctx else { throw MemoryError.contextNotInitialized }
            guard mt_patch_nop(ctx, mach_vm_address_t(address)) else {
                throw MemoryError.patchFailed(address)
            }
        }
    }

    // MARK: - 枚举可读写区域

    /// 通过静态变量桥接 Swift 数组给 C 回调（同步回调，线程安全）
    private static var _regionBuffer: [(UInt64, UInt64)] = []

    private static let regionCallback: @convention(c) (mach_vm_address_t, mach_vm_size_t, UnsafeMutableRawPointer?) -> Void = { addr, size, _ in
        _regionBuffer.append((UInt64(addr), UInt64(size)))
    }

    func enumerateRegions() -> [(address: UInt64, size: UInt64)] {
        return serialQueue.sync {
            guard let ctx = ctx else { return [] }
            _regionBuffer = []
            mt_enumerate_rw_regions(ctx, MemoryTool.regionCallback, nil)
            let result = _regionBuffer
            _regionBuffer = []
            return result.map { (address: $0, size: $1) }
        }
    }

    // MARK: - AoB 解析

    /// 解析 AoB 字符串，如 "FF 00 3A ??"
    /// ?? 表示通配符（忽略该字节），其他必须为两位十六进制
    private func parseAoB(_ input: String) -> (pattern: [UInt8], mask: [UInt8], patLen: UInt) {
        let cleaned = input.trimmingCharacters(in: .whitespaces)
        let tokens = cleaned.split { $0.isWhitespace }.map { String($0) }

        var pattern: [UInt8] = []
        var mask: [UInt8] = []

        for token in tokens {
            let chars = Array(token)
            let byteCount = chars.count / 2
            for i in 0..<byteCount {
                let hexChars = String(chars[i*2...<(i*2+2)])
                if hexChars == "??" {
                    pattern.append(0)
                    mask.append(0)  // 0 = 通配（忽略）
                } else if let v = UInt8(hexChars, radix: 16) {
                    pattern.append(v)
                    mask.append(0xFF)  // 0xFF = 必须匹配
                }
            }
        }
        return (pattern, mask, UInt(pattern.count))
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
        case .invalidAoB: return "无效的 AoB 格式（至少需 2 字节，格式如 FF 00 ??）"
        case .noResults: return "无扫描结果"
        case .writeFailed(let addr): return "写入失败: 0x\(addr, radix: 16)"
        case .notSupported(let msg): return msg
        case .pointerChainFailed(let base): return "指针链追踪失败: 0x\(base, radix: 16)"
        case .patchFailed(let addr): return "代码 Patch 失败: 0x\(addr, radix: 16)"
        }
    }
}