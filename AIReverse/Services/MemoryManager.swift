import Foundation

// MARK: - 内存管理器错误
enum MemoryError: LocalizedError {
    case notAttached
    case taskForPidFailed(Int32)
    case regionEnumFailed(String)
    case readFailed(UInt64, String)
    case writeFailed(UInt64, String)
    case invalidValue(String)
    case scanCancelled

    var errorDescription: String? {
        switch self {
        case .notAttached: return "未附加到目标进程"
        case .taskForPidFailed(let kr): return "task_for_pid 失败 (错误码: \(kr))"
        case .regionEnumFailed(let msg): return "内存区域枚举失败: \(msg)"
        case .readFailed(let addr, let msg):
            return "读取内存 0x\(String(addr, radix: 16)) 失败: \(msg)"
        case .writeFailed(let addr, let msg):
            return "写入内存 0x\(String(addr, radix: 16)) 失败: \(msg)"
        case .invalidValue(let msg): return "无效值: \(msg)"
        case .scanCancelled: return "扫描已取消"
        }
    }
}

// MARK: - 内存扫描进度
struct ScanProgress {
    let region: Int
    let totalRegions: Int
    let pagesScanned: Int
    let totalBytes: Int
    var percentage: Double {
        guard totalRegions > 0 else { return 0 }
        return Double(region) / Double(totalRegions) * 100
    }
}

// MARK: - 内存管理器
final class MemoryManager: ObservableObject {
    @Published var isAttached = false
    @Published var targetPid: Int32 = 0
    @Published var targetName = ""
    @Published var scanProgress: ScanProgress?
    @Published var isScanning = false
    @Published var results: [MemoryScanResult] = []
    @Published var freezeAddresses: Set<UInt64> = []

    private var targetTask: mach_port_t = 0
    private var regions: [MemoryRegion] = []
    private var previousState: ScanState = ScanState()
    private var valueTypes: [ValueType] = [.int32, .uint32, .int64, .float, .double]
    private var currentValueType: ValueType = .int32
    private var scanFilter: ScanFilter = .exact
    private let lock = NSLock()
    private let maxRegionSize: UInt64 = 1024 * 1024 * 1024 // 1GB 上限

    // MARK: - 生命周期

    func attach(pid: Int32, processName: String = "") throws {
        if targetTask != 0 { detach() }

        var port: mach_port_t = 0
        let kr = task_for_pid(mach_task_self_, pid, &port)
        if kr != KERN_SUCCESS {
            throw MemoryError.taskForPidFailed(kr)
        }

        lock.lock()
        targetTask = port
        targetPid = pid
        targetName = processName.isEmpty ? "PID:\(pid)" : processName
        lock.unlock()

        isAttached = true
        RuntimeLogger.shared.info("Memory", "已附加到进程 \(processName) (PID: \(pid))")
    }

    func detach() {
        lock.lock()
        defer { lock.unlock() }

        if targetTask != 0 {
            mach_port_deallocate(mach_task_self_, targetTask)
            targetTask = 0
        }
        regions.removeAll()
        results.removeAll()
        previousState = ScanState()
        freezeAddresses.removeAll()
        isAttached = false
        isScanning = false
    }

    func destroy() {
        detach()
    }

    // MARK: - 区域枚举

    func enumerateRegions() throws -> [MemoryRegion] {
        guard targetTask != 0 else { throw MemoryError.notAttached }
        return try scanAllRegions()
    }

    private func scanAllRegions() throws -> [MemoryRegion] {
        var found: [MemoryRegion] = []
        var address: mach_vm_address_t = 0
        var size: mach_vm_size_t = 0
        var totalMapped: UInt64 = 0

        let startTime = DispatchTime.now()

        while address < 0x00007FFFFFFFFFFF {
            // 超时检查：超过 30 秒停止
            if DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds > 30_000_000_000 {
                break
            }

            var nestingDepth: uint32_t = 0
            var infoCount: mach_msg_type_number_t = mach_msg_type_number_t(
                MemoryLayout<vm_region_recurse_info_64_t>.size / MemoryLayout<natural_t>.size
            )
            var info = vm_region_recurse_info_64_t(
                protection: 0, max_protection: 0, inheritance: VM_INHERIT_SHARE,
                sharing: MEMORY_OBJECT_COPY_NONE, is_submap: false, is_image: false, behavior: 0
            )
            var newNestingDepth: mach_vm_offset_t = 0

            let kr = mach_vm_region_recurse(
                targetTask,
                &address,
                &size,
                &nestingDepth,
                &info,
                &infoCount,
                &newNestingDepth
            )

            if kr != KERN_SUCCESS {
                break
            }

            let start = UInt64(address)
            let sz = UInt64(size)

            // 跳过过大的区域（防止死循环）
            if sz > maxRegionSize {
                address = start + maxRegionSize
                continue
            }

            if info.is_submap != 0 {
                // 子映射：跳过，vm_region_recurse 会自动深入
                address = start + sz
                continue
            }

            // 仅保留可读区域
            let prot = UInt32(info.protection)
            if prot & UInt32(VM_PROT_READ) != 0 {
                found.append(MemoryRegion(start: start, size: sz, protection: prot))
                totalMapped += sz
            }

            address = start + sz
        }

        lock.lock()
        regions = found
        lock.unlock()

        RuntimeLogger.shared.info("Memory", "枚举到 \(found.count) 个可读内存区域，共 \(totalMapped / 1024 / 1024) MB")
        return found
    }

    // MARK: - 内存读写

    func readMemory(address: UInt64, size: Int) throws -> Data {
        guard targetTask != 0 else { throw MemoryError.notAttached }

        var outBytes = [UInt8](repeating: 0, count: size)
        var outSize: mach_vm_size_t = mach_vm_size_t(size)

        let kr = outBytes.withUnsafeMutableBufferPointer { ptr in
            mach_vm_read_overwrite(
                targetTask,
                mach_vm_address_t(address),
                mach_vm_size_t(size),
                mach_vm_address_t(UInt(bitPattern: ptr.baseAddress!)),
                &outSize
            )
        }

        if kr != KERN_SUCCESS {
            throw MemoryError.readFailed(address, mach_error_string(kr))
        }

        if outSize == 0 {
            throw MemoryError.readFailed(address, "读取了 0 字节")
        }

        return Data(bytes: outBytes, count: Int(outSize))
    }

    func writeMemory(address: UInt64, data: Data) throws {
        guard targetTask != 0 else { throw MemoryError.notAttached }
        guard !data.isEmpty else { return }

        let buffer = data.withUnsafeBytes { pointer in
            pointer.bindMemory(to: UInt8.self).baseAddress!
        }

        let kr = mach_vm_write(
            targetTask,
            mach_vm_address_t(address),
            buffer,
            mach_msg_type_number_t(data.count)
        )

        if kr != KERN_SUCCESS {
            throw MemoryError.writeFailed(address, mach_error_string(kr))
        }
    }

    // MARK: - 扫描

    func firstScan(value: String, type: ValueType, cancelHandler: @escaping () -> Bool = { false }) async throws -> [MemoryScanResult] {
        guard targetTask != 0 else { throw MemoryError.notAttached }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryError.invalidValue("搜索值不能为空")
        }

        currentValueType = type
        scanFilter = .exact

        // 获取内存区域
        if regions.isEmpty {
            try await Task.dispatch(on: .global(qos: .userInitiated)) {
                try self.enumerateRegions()
            }()
        }

        guard !regions.isEmpty else { throw MemoryError.regionEnumFailed("未找到可读内存区域") }

        isScanning = true
        let startTime = DispatchTime.now()

        // 将搜索值转换为字节序列（所有匹配的类型）
        let searchBytes = type == .hex ? hexToData(value) : typeToData(value, type: type)

        var allResults: [MemoryScanResult] = []
        var totalBytesScanned: Int = 0
        var totalPages: Int = 0

        for (idx, region) in regions.enumerated() {
            if cancelHandler() {
                isScanning = false
                throw MemoryError.scanCancelled
            }

            // 更新进度
            let progress = ScanProgress(
                region: idx + 1,
                totalRegions: regions.count,
                pagesScanned: totalPages,
                totalBytes: totalBytesScanned
            )
            await MainActor.run { self.scanProgress = progress }

            // 检查区域大小限制
            let regionSize = min(Int(region.size), 1024 * 1024 * 512) // 512MB 上限
            let pages = regionSize / PAGE_SIZE

            totalPages += pages
            totalBytesScanned += regionSize

            // 逐页扫描
            for page in 0..<pages {
                let pageAddr = region.start + UInt64(page) * UInt64(PAGE_SIZE)
                let readSize = min(PAGE_SIZE, regionSize - Int(pageAddr - region.start))

                guard let pageData = try? self.readMemory(address: pageAddr, size: readSize) else {
                    continue
                }

                let matches = findBytes(in: pageData, pattern: searchBytes, offset: pageAddr)
                for m in matches {
                    allResults.append(MemoryScanResult(address: m, display: formatAddress(m)))
                }
            }
        }

        isScanning = false
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let seconds = Double(elapsed) / 1_000_000_000
        RuntimeLogger.shared.info("Memory",
            "首次扫描完成: 找到 \(allResults.count) 个匹配, 扫描 \(totalBytesScanned / 1024 / 1024) MB, 耗时 \(String(format: "%.1f", seconds))s")

        // 保存状态
        lock.lock()
        previousState = ScanState(
            results: allResults,
            lastBytes: searchBytes,
            valueTypes: [type]
        )
        lock.unlock()

        results = allResults
        return allResults
    }

    func nextScan(value: String, filter: ScanFilter, type: ValueType,
                  cancelHandler: @escaping () -> Bool = { false }) async throws -> [MemoryScanResult] {
        guard !previousState.results.isEmpty else {
            throw MemoryError.invalidValue("没有上一次扫描结果，请先执行首次扫描")
        }

        currentValueType = type
        scanFilter = filter

        var filtered: [MemoryScanResult] = []
        let startTime = DispatchTime.now()

        for (idx, result) in previousState.results.enumerated() {
            if idx % 100 == 0 && cancelHandler() {
                throw MemoryError.scanCancelled
            }

            guard let currentBytes = try? readMemory(address: result.address, size: type.byteCount),
                  currentBytes.count == type.byteCount else { continue }

            let newValue = parseBytes(currentBytes, type: type)
            let displayValue = displayValue(newValue, type: type)

            let (keep, newDisplay) = filterResult(result: result, type: type, value: value, filter: filter, currentBytes: currentBytes, newValue: newValue, displayValue: displayValue)

            if keep {
                filtered.append(MemoryScanResult(address: result.address, display: newDisplay))
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
        let seconds = Double(elapsed) / 1_000_000_000
        RuntimeLogger.shared.info("Memory",
            "后续扫描(\(filter.displayName)): \(filtered.count) 个结果, 耗时 \(String(format: "%.1f", seconds))s")

        lock.lock()
        previousState = ScanState(
            results: filtered,
            lastBytes: nil,
            valueTypes: [type]
        )
        lock.unlock()

        results = filtered
        return filtered
    }

    // MARK: - 写入

    func writeValue(address: UInt64, value: String, type: ValueType) throws -> String {
        guard targetTask != 0 else { throw MemoryError.notAttached }

        let data = type == .hex ? hexToData(value) : typeToData(value, type: type)
        guard let data = data else { throw MemoryError.invalidValue("无法将 \"\(value)\" 转换为 \(type.displayName)") }

        // 读取旧值
        let oldData = try readMemory(address: address, size: data.count)
        let oldValue = displayBytes(oldData, type: type)

        // 写入新值
        try writeMemory(address: address, data: data)

        // 记录修改
        ModificationTracker.shared.addMemoryModification(address: address, oldValue: oldValue, newValue: value)

        return displayBytes(data, type: type)
    }

    // MARK: - 冻结

    func freeze(address: UInt64) {
        freezeAddresses.insert(address)
        RuntimeLogger.shared.info("Memory", "冻结地址 0x\(String(address, radix: 16))")
    }

    func unfreeze(address: UInt64) {
        freezeAddresses.remove(address)
    }

    // MARK: - 私有辅助

    private func findBytes(in data: Data, pattern: Data, offset: UInt64) -> [UInt64] {
        guard !pattern.isEmpty else { return [] }
        guard data.count >= pattern.count else { return [] }

        var matches: [UInt64] = []
        let d = data
        let p = pattern

        for i in 0...Int(d.count - p.count) {
            var found = true
            for j in 0..<p.count {
                if d[i + j] != p[j] {
                    found = false
                    break
                }
            }
            if found {
                matches.append(offset + UInt64(i))
            }
        }
        return matches
    }

    private func filterResult(result: MemoryScanResult, type: ValueType, value: String, filter: ScanFilter, currentBytes: Data, newValue: String?, displayValue: String) -> (Bool, String) {
        switch filter {
        case .exact:
            let targetBytes = type == .hex ? hexToData(value) : typeToData(value, type: type)
            if let tb = targetBytes, currentBytes == tb {
                return (true, displayValue)
            }
            return (false, displayValue)

        case .changed:
            let currentStr = displayBytes(currentBytes, type: type)
            if currentStr != result.originalDisplay {
                return (true, currentStr)
            }
            return (false, displayValue)

        case .unchanged:
            let currentStr = displayBytes(currentBytes, type: type)
            if currentStr == result.originalDisplay {
                return (true, currentStr)
            }
            return (false, displayValue)

        case .increased:
            let cv = parseValue(result.originalDisplay, type: type)
            let nv = parseValue(displayValue, type: type)
            if let cv, let nv, nv > cv {
                return (true, displayValue)
            }
            return (false, displayValue)

        case .decreased:
            let cv = parseValue(result.originalDisplay, type: type)
            let nv = parseValue(displayValue, type: type)
            if let cv, let nv, nv < cv {
                return (true, displayValue)
            }
            return (false, displayValue)
        }
    }

    // MARK: - 值类型转换

    private func typeToData(_ value: String, type: ValueType) -> Data? {
        switch type {
        case .byte:
            guard let v = UInt8(value) else { return nil }
            return Data([v])
        case .int16:
            guard let v = Int16(value) else { return nil }
            return v.littleEndian.dataBytes
        case .uint16:
            guard let v = UInt16(value) else { return nil }
            return v.littleEndian.dataBytes
        case .int32:
            guard let v = Int32(value) else { return nil }
            return v.littleEndian.dataBytes
        case .uint32:
            guard let v = UInt32(value) else { return nil }
            return v.littleEndian.dataBytes
        case .int64:
            guard let v = Int64(value) else { return nil }
            return v.littleEndian.dataBytes
        case .uint64:
            guard let v = UInt64(value) else { return nil }
            return v.littleEndian.dataBytes
        case .float:
            guard let v = Float(value) else { return nil }
            return v.littleEndian.dataBytes
        case .double:
            guard let v = Double(value) else { return nil }
            return v.littleEndian.dataBytes
        case .hex:
            return hexToData(value)
        }
    }

    private func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: "")
        let upper = cleaned.uppercased()
        guard upper.count.isMultiple-of(2) else { return nil }

        var bytes: [UInt8] = []
        for i in stride(from: 0, to: upper.count, by: 2) {
            let byteString = String(upper[upper.index(upper.startIndex, offsetBy: i)..<upper.index(upper.startIndex, offsetBy: i + 2)])
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    private func parseBytes(_ data: Data, type: ValueType) -> String? {
        switch type {
        case .byte:
            guard data.count == 1 else { return nil }
            return String(data[0])
        case .int16:
            guard data.count == 2 else { return nil }
            return String(Int16(littleEndian: data.loadUnaligned(as: UInt16.self)))
        case .uint16:
            guard data.count == 2 else { return nil }
            return String(UInt16(littleEndian: data.loadUnaligned(as: UInt16.self)))
        case .int32:
            guard data.count == 4 else { return nil }
            return String(Int32(littleEndian: data.loadUnaligned(as: UInt32.self)))
        case .uint32:
            guard data.count == 4 else { return nil }
            return String(UInt32(littleEndian: data.loadUnaligned(as: UInt32.self)))
        case .int64:
            guard data.count == 8 else { return nil }
            return String(Int64(littleEndian: data.loadUnaligned(as: UInt64.self)))
        case .uint64:
            guard data.count == 8 else { return nil }
            return String(UInt64(littleEndian: data.loadUnaligned(as: UInt64.self)))
        case .float:
            guard data.count == 4 else { return nil }
            return String(Float(littleEndian: data.loadUnaligned(as: UInt32.self)))
        case .double:
            guard data.count == 8 else { return nil }
            return String(Double(littleEndian: data.loadUnaligned(as: UInt64.self)))
        case .hex:
            return data.hexString
        }
    }

    private func parseValue(_ str: String, type: ValueType) -> Double? {
        switch type {
        case .byte: return Double(UInt8(str) ?? 0)
        case .int16: return Double(Int16(str) ?? 0)
        case .uint16: return Double(UInt16(str) ?? 0)
        case .int32: return Double(Int32(str) ?? 0)
        case .uint32: return Double(UInt32(str) ?? 0)
        case .int64: return Double(Int64(str) ?? 0)
        case .uint64: return Double(UInt64(str) ?? 0)
        case .float: return Double(Float(str) ?? 0)
        case .double: return Double(str) ?? 0
        case .hex: return nil
        }
    }

    private func displayValue(_ value: String?, type: ValueType) -> String {
        guard let value = value else { return "?" }
        return value
    }

    private func displayBytes(_ data: Data, type: ValueType) -> String {
        switch type {
        case .byte:
            guard data.count == 1 else { return data.hexString }
            return String(data[0])
        case .int16:
            guard data.count == 2 else { return data.hexString }
            return String(Int16(littleEndian: data.loadUnaligned(as: UInt16.self)))
        case .uint16:
            guard data.count == 2 else { return data.hexString }
            return String(UInt16(littleEndian: data.loadUnaligned(as: UInt16.self)))
        case .int32:
            guard data.count == 4 else { return data.hexString }
            return String(Int32(littleEndian: data.loadUnaligned(as: UInt32.self)))
        case .uint32:
            guard data.count == 4 else { return data.hexString }
            return String(UInt32(littleEndian: data.loadUnaligned(as: UInt32.self)))
        case .int64:
            guard data.count == 8 else { return data.hexString }
            return String(Int64(littleEndian: data.loadUnaligned(as: UInt64.self)))
        case .uint64:
            guard data.count == 8 else { return data.hexString }
            return String(UInt64(littleEndian: data.loadUnaligned(as: UInt64.self)))
        case .float:
            guard data.count == 4 else { return data.hexString }
            return String(Float(littleEndian: data.loadUnaligned(as: UInt32.self)))
        case .double:
            guard data.count == 8 else { return data.hexString }
            return String(Double(littleEndian: data.loadUnaligned(as: UInt64.self)))
        case .hex:
            return data.hexString
        }
    }

    private func formatAddress(_ addr: UInt64) -> String {
        "0x\(String(addr, radix: 16).uppercased())"
    }
}

// MARK: - Data 扩展
extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    func loadUnaligned<T>(as type: T.Type) -> T {
        withUnsafeBytes { $0.load(as: T.self) }
    }
}

extension BinaryInteger {
    var littleEndian: Self { self.littleEndian }
    var dataBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}

extension Task where Success == Never, Failure == Never {
    static func dispatch<T>(on queue: DispatchQueue, _ operation: @escaping () async throws -> T) async rethrows -> T {
        try await Task { try await operation() }.value
    }
}