import Foundation

/// Objective-C 运行时元数据解析器。
/// 依赖 MachOParser 先解析出 segments（用于 vmaddr → file offset 换算）。
final class ObjCParser {

    private let data: Data
    private let segments: [SegmentInfo]
    private let swapped: Bool

    init(data: Data, segments: [SegmentInfo], swapped: Bool) {
        self.data = data
        self.segments = segments
        self.swapped = swapped
    }

    /// 将 vmaddr 转换为文件偏移；失败返回 nil
    private func fileOffset(for vmaddr: UInt64) -> Int? {
        for seg in segments {
            let vmSize = max(seg.vmSize, seg.fileSize)
            if vmaddr >= seg.vmAddr && vmaddr < seg.vmAddr + vmSize {
                return Int(vmaddr - seg.vmAddr + seg.fileOffset)
            }
        }
        return nil
    }

    private func readU32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var v = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        if swapped { v = CFSwapInt32(v) }
        return v
    }

    private func readU64(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(data[offset + i]) << (i * 8)
        }
        if swapped { v = CFSwapInt64(v) }
        return v
    }

    private func cString(at offset: Int, limit: Int = 512) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var chars: [UInt8] = []
        var i = offset
        while i < data.count, chars.count < limit {
            let b = data[i]
            if b == 0 { break }
            chars.append(b)
            i += 1
        }
        return String(bytes: chars, encoding: .utf8)
    }

    // MARK: - 主入口

    /// 返回所有 ObjC 类及其方法
    func parseClasses() -> [ObjCClassInfo] {
        parseClassesDirect()
    }

    // MARK: - 直接解析

    /// 通过解析 section 表定位 __objc_classlist，逐个解析类对象。
    private func parseClassesDirect() -> [ObjCClassInfo] {
        // 解析 section 表
        guard let section = findObjCClassListSection() else { return [] }
        let base = section.fileOffset
        let byteCount = Int(section.size)
        guard byteCount > 0, byteCount % 8 == 0 else { return [] }
        let count = byteCount / 8
        var result: [ObjCClassInfo] = []

        for i in 0..<min(count, 3000) {
            let ptrOffset = base + i * 8
            guard ptrOffset >= 0, ptrOffset + 8 <= data.count else { break }
            guard let classAddr = readU64(ptrOffset) else { break }
            if classAddr == 0 { continue }
            if let cls = parseClass(at: classAddr) {
                result.append(cls)
            }
        }
        return result
    }

    /// 完整解析 Load Commands 中的 section_64 表，定位 __objc_classlist。
    private func findObjCClassListSection() -> (fileOffset: Int, size: UInt64)? {
        guard data.count >= 4 else { return nil }
        var offset = 0
        if data.count >= 8 {
            let magic = readU32Raw(0) ?? 0
            if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
                // fat：找到 arm64 slice，重新定位
                let fatSwapped = magic == 0xBEBAFECA
                func fatHost(_ v: UInt32) -> UInt32 { fatSwapped ? CFSwapInt32(v) : v }
                let count = Int(fatHost(readU32Raw(4) ?? 0))
                for i in 0..<count {
                    let base = 8 + i * 20
                    let cpu = readU32Raw(base + 0) ?? 0
                    let c = fatHost(cpu)
                    if c == 0x0100000C {
                        offset = Int(fatHost(readU32Raw(base + 8) ?? 0))
                        break
                    }
                }
            }
        }

        guard offset + 32 <= data.count else { return nil }
        let sliceMagic = readU32Raw(offset) ?? 0
        let isSwapped = (sliceMagic == 0xCFFAEDFE) // MH_CIGAM_64
        func host(_ v: UInt32) -> UInt32 { isSwapped ? CFSwapInt32(v) : v }
        func host64(_ v: UInt64) -> UInt64 { isSwapped ? CFSwapInt64(v) : v }
        let ncmds = Int(host(readU32Raw(offset + 16) ?? 0))
        var cursor = offset + 32

        for _ in 0..<ncmds {
            guard cursor + 8 <= data.count else { break }
            let cmd = host(readU32Raw(cursor) ?? 0)
            let cmdsize = Int(host(readU32Raw(cursor + 4) ?? 0))
            guard cmdsize >= 8, cursor + cmdsize <= data.count else { break }

            if cmd == 0x19 { // LC_SEGMENT_64
                var segCursor = cursor + 72 // segment_command_64 头（8+16+8*4+8*4 = 72）
                let nsects = Int(host(readU32Raw(cursor + 64) ?? 0))
                for _ in 0..<nsects {
                    guard segCursor + 80 <= data.count else { break }
                    // section_64: sectname[16] segname[16] addr(8) size(8) offset(4) ... 
                    let sectName = asciiString(at: segCursor, len: 16)
                    if sectName == "__objc_classlist" {
                        let size = host64(readU64Raw(segCursor + 40) ?? 0)
                        let fileOff = Int(host(readU32Raw(segCursor + 48) ?? 0))
                        return (fileOff, size)
                    }
                    segCursor += 80
                }
            }
            cursor += cmdsize
        }
        return nil
    }

    private func readU32Raw(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func readU64Raw(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << (i * 8)
        }
        return value
    }

    private func asciiString(at offset: Int, len: Int) -> String {
        guard offset >= 0, offset + len <= data.count else { return "" }
        let bytes = (0..<len).compactMap { i -> UInt8? in
            let b = data[offset + i]
            return b == 0 ? nil : b
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - class_ro_t 解析

    /// 解析单个 objc_class：通过 class 指针读取其 data(ro) 得到类名、方法列表
    private func parseClass(at classAddr: UInt64) -> ObjCClassInfo? {
        // objc_class 布局(64位, 无 isa 标志)：isa(8) superclass(8) cache(8) vtable(8) data(8) => data 在 +32
        guard let classFileOffset = fileOffset(for: classAddr) else { return nil }
        let dataPtrOffset = classFileOffset + 32
        guard let dataPtr = readU64(dataPtrOffset) else { return nil }

        // 对于真机 arm64，dataPtr 低 3 位可能带标志；抹掉
        let roPtr = dataPtr & ~UInt64(7)
        guard let roOffset = fileOffset(for: roPtr) else { return nil }

        var cls = ObjCClassInfo()
        cls.address = classAddr

        // class_ro_t: flags(4) instanceStart(4) instanceSize(4) reserved(4) ivarLayout(8) name(8) baseMethods(8) ...
        if let namePtr = readU64(roOffset + 32), let nameOff = fileOffset(for: namePtr), let name = cString(at: nameOff) {
            cls.name = name
        } else {
            cls.name = "class_0x\(String(classAddr, radix: 16))"
        }

        // baseMethods
        if let methodsPtr = readU64(roOffset + 40) {
            cls.methods = parseMethodList(at: methodsPtr)
        }

        // superclass
        let superPtr = readU64(classFileOffset + 8) ?? 0
        if superPtr != 0, let so = fileOffset(for: superPtr) {
            // 尝试读取父类名（递归一层即可）
            let sData = readU64(so + 32) ?? 0
            if let sRO = fileOffset(for: sData & ~UInt64(7)), let sNamePtr = readU64(sRO + 32), let sNameOff = fileOffset(for: sNamePtr) {
                cls.superclassName = cString(at: sNameOff) ?? ""
            }
        }

        return cls
    }

    private func parseMethodList(at listPtr: UInt64) -> [ObjCMethod] {
        guard let off = fileOffset(for: listPtr) else { return [] }
        // method_list_t: entsize(4) count(4)
        let entsizeRaw = readU32(off) ?? 16
        let count = Int(readU32(off + 4) ?? 0)
        // entsize 高位为 flags，取低 16 位
        let entsize = Int(entsizeRaw & 0xFFFF)
        guard entsize >= 24, count > 0, count < 5000 else { return [] }

        var methods: [ObjCMethod] = []
        for i in 0..<count {
            let entry = off + 8 + i * entsize
            guard entry >= 0, entry + 24 <= data.count else { break }
            let namePtr = readU64(entry + 0) ?? 0
            let typePtr = readU64(entry + 8) ?? 0
            let imp = readU64(entry + 16) ?? 0

            var m = ObjCMethod()
            if let nameOff = fileOffset(for: namePtr) {
                m.selector = cString(at: nameOff) ?? "?"
            } else {
                m.selector = "sel_0x\(String(namePtr, radix: 16))"
            }
            if let typeOff = fileOffset(for: typePtr) {
                m.typeEncoding = cString(at: typeOff) ?? ""
            }
            m.imp = imp
            methods.append(m)
        }
        return methods
    }
}
