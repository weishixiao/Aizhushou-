import Foundation
import UIKit

// MARK: - 值类型
enum ValueType: String, CaseIterable, Identifiable {
    case byte, int16, uint16, int32, uint32, int64, uint64, float, double, hex
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .byte: return "字节(1B)"
        case .int16: return "短整数(2B有符号)"
        case .uint16: return "短整数(2B无符号)"
        case .int32: return "整数(4B有符号)"
        case .uint32: return "整数(4B无符号)"
        case .int64: return "长整数(8B有符号)"
        case .uint64: return "长整数(8B无符号)"
        case .float: return "浮点数(4B)"
        case .double: return "双精度(8B)"
        case .hex: return "HEX 字节序列"
        }
    }

    var byteCount: Int {
        switch self {
        case .byte: return 1
        case .int16, .uint16: return 2
        case .int32, .uint32, .float: return 4
        case .int64, .uint64, .double: return 8
        case .hex: return 0
        }
    }

    var isFixedWidth: Bool { byteCount > 0 }
}

// MARK: - 扫描过滤器
enum ScanFilter: String, CaseIterable {
    case exact, changed, unchanged, increased, decreased

    var displayName: String {
        switch self {
        case .exact: return "精确匹配"
        case .changed: return "变化了"
        case .unchanged: return "没变化"
        case .increased: return "增加了"
        case .decreased: return "减少了"
        }
    }
}

// MARK: - 内存区域信息
struct MemoryRegion {
    let start: UInt64
    let size: UInt64
    let protection: UInt32
    var end: UInt64 { start + size }
    var canRead: Bool { protection & UInt32(VM_PROT_READ) != 0 }
}

// MARK: - 内存扫描结果
struct MemoryScanResult: Identifiable, Equatable {
    let id = UUID()
    var address: UInt64
    var currentDisplay: String
    var originalDisplay: String
    var isModified: Bool = false

    init(address: UInt64, display: String) {
        self.address = address
        self.currentDisplay = display
        self.originalDisplay = display
    }

    static func == (lhs: MemoryScanResult, rhs: MemoryScanResult) -> Bool {
        lhs.address == rhs.address && lhs.currentDisplay == rhs.currentDisplay
    }
}

// MARK: - 扫描状态
struct ScanState {
    var results: [MemoryScanResult] = []
    var lastBytes: Data?
    var regionCount = 0
    var scannedPages = 0
    var totalBytes = 0
    var valueTypes: [ValueType] = []

    var isEmpty: Bool { results.isEmpty }
}