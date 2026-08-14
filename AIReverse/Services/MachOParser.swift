import Foundation

enum MachOParseError: Error, LocalizedError {
    case notMachO
    case truncated
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .notMachO:
            return "文件不是有效的 Mach-O 二进制"
        case .truncated:
            return "文件被截断，数据不完整"
        case .readFailed(let msg):
            return msg
        }
    }
}

/// Mach-O / Fat 二进制解析器（纯 Swift 实现）
final class MachOParser {

    // Magic 常量
    static let MH_MAGIC: UInt32 = 0xFEEDFACE
    static let MH_CIGAM: UInt32 = 0xCEFAEDFE
    static let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    static let MH_CIGAM_64: UInt32 = 0xCFFAEDFE
    static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    static let FAT_CIGAM: UInt32 = 0xBEBAFECA

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    private func read<T>(_ type: T.Type, at offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else { return nil }
        var value: T = data.withUnsafeBytes { buf in
            buf.load(fromByteOffset: offset, as: T.self)
        }
        return value
    }

    private func readU32(_ offset: Int) -> UInt32? {
        read(UInt32.self, at: offset)
    }

    func parse() -> MachOInfo {
        var info = MachOInfo()
        guard data.count >= 4 else {
            info.errorMessage = "文件过小"
            return info
        }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        switch magic {
        case Self.FAT_MAGIC, Self.FAT_CIGAM:
            info.isFat = true
            parseFat(&info, magic: magic)
        case Self.MH_MAGIC_64, Self.MH_CIGAM_64:
            info.isFat = false
            var arch = ArchInfo()
            arch.cpuType = "arm64"
            parseThin64(&info, baseOffset: 0, arch: &arch)
        case Self.MH_MAGIC, Self.MH_CIGAM:
            info.errorMessage = "仅支持 64 位 Mach-O"
            return info
        default:
            info.errorMessage = "不是 Mach-O 文件（magic: 0x\(String(magic, radix: 16))）"
            return info
        }
        return info
    }

    private func isSwapped(_ magic: UInt32) -> Bool {
        magic == Self.MH_CIGAM_64 || magic == Self.FAT_CIGAM || magic == Self.MH_CIGAM
    }

    private func toHost(_ value: UInt32, swapped: Bool) -> UInt32 {
        swapped ? CFSwapInt32(value) : value
    }

    private func toHost64(_ value: UInt64, swapped: Bool) -> UInt64 {
        swapped ? CFSwapInt64(value) : value
    }

    // MARK: - Fat 文件

    private func parseFat(_ info: inout MachOInfo, magic: UInt32) {
        let swapped = (magic == Self.FAT_CIGAM)
        guard let countRaw = readU32(4) else {
            info.errorMessage = "Fat 头损坏"
            return
        }
        let count = Int(toHost(countRaw, swapped: swapped))
        var offset = 8
        for i in 0..<count {
            guard offset + 20 <= data.count else {
                info.errorMessage = "Fat arch 表损坏"
                return
            }
            let cpuType = toHost(readU32(offset) ?? 0, swapped: swapped)
            let cpuSubtype = toHost(readU32(offset + 4) ?? 0, swapped: swapped)
            let archOffset = UInt64(toHost(readU32(offset + 8) ?? 0, swapped: swapped))
            let archSize = UInt64(toHost(readU32(offset + 12) ?? 0, swapped: swapped))

            var arch = ArchInfo()
            arch.cpuType = cpuName(cpuType)
            arch.cpuSubtype = "0x\(String(cpuSubtype, radix: 16))"
            arch.offset = archOffset
            arch.size = archSize
            info.architectures.append(arch)

            // 解析第一个 arm64 切片（通常是最主要的目标）
            if cpuType == 0x0100000C /* CPU_TYPE_ARM64 */ && info.header.isEmpty {
                parseThin64(&info, baseOffset: Int(archOffset), arch: &arch)
            }
            offset += 20
        }
        if info.header.isEmpty, info.architectures.first != nil {
            let firstOffset = info.architectures[0].offset
            var firstArch = info.architectures[0]
            parseThin64(&info, baseOffset: Int(firstOffset), arch: &firstArch)
            info.architectures[0] = firstArch
        }
    }

    private func cpuName(_ type: UInt32) -> String {
        switch type {
        case 7: return "i386"
        case 0x01000007: return "x86_64"
        case 12: return "arm"
        case 0x0100000C: return "arm64"
        default: return "cpu_\(type)"
        }
    }

    // MARK: - 64 位 Mach-O

    private func parseThin64(_ info: inout MachOInfo, baseOffset: Int, arch: inout ArchInfo) {
        guard baseOffset + 32 <= data.count else {
            info.errorMessage = "Mach-O 头越界"
            return
        }
        let magicRaw = readU32(baseOffset) ?? 0
        let swapped = isSwapped(magicRaw)
        let ncmds = Int(toHost(readU32(baseOffset + 16) ?? 0, swapped: swapped))

        info.header = "Mach-O 64-bit (\(arch.cpuType))  ncmds=\(ncmds)"
        var offset = baseOffset + 32

        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else {
                info.errorMessage = "Load command 越界"
                return
            }
            let cmd = toHost(readU32(offset) ?? 0, swapped: swapped)
            let cmdsize = Int(toHost(readU32(offset + 4) ?? 0, swapped: swapped))
            guard cmdsize >= 8, offset + cmdsize <= data.count else {
                info.errorMessage = "Load command 尺寸非法"
                return
            }

            parseLoadCommand(cmd, cmdsize: cmdsize, at: offset, swapped: swapped, info: &info)
            offset += cmdsize
        }
    }

    private func parseLoadCommand(_ cmd: UInt32, cmdsize: Int, at offset: Int, swapped: Bool, info: inout MachOInfo) {
        switch cmd {
        case 0x19: // LC_SEGMENT_64
            if let namePtr = readSegmentName(offset) {
                let vmaddr = toHost64(readSegmentField(offset, fieldOffset: 24) ?? 0, swapped: swapped)
                let fileoff = toHost64(readSegmentField(offset, fieldOffset: 40) ?? 0, swapped: swapped)
                let filesize = toHost64(readSegmentField(offset, fieldOffset: 48) ?? 0, swapped: swapped)
                var seg = SegmentInfo()
                seg.name = namePtr
                seg.vmAddr = vmaddr
                seg.fileOffset = fileoff
                seg.fileSize = filesize
                info.segments.append(seg)
            }
        case 0x2: // LC_SYMTAB
            let symoff = Int(toHost32(offset + 8, swapped: swapped) ?? 0)
            let nsyms = Int(toHost32(offset + 12, swapped: swapped) ?? 0)
            let stroff = Int(toHost32(offset + 16, swapped: swapped) ?? 0)
            info.symbolCount = nsyms
            if nsyms > 0 && info.symbols.isEmpty {
                parseSymbols(symoff, nsyms: nsyms, stroff: stroff, swapped: swapped, into: &info)
            }
        case 0xC: // LC_LOAD_DYLIB
            if let name = readDylibName(offset, cmdsize: cmdsize) {
                info.loadCommands.append("LC_LOAD_DYLIB \(name)")
            }
        default:
            info.loadCommands.append("cmd 0x\(String(cmd, radix: 16)) (size \(cmdsize))")
        }
    }

    private func readSegmentName(_ offset: Int) -> String? {
        guard offset >= 0, offset + 24 <= data.count else { return nil }
        let chars = (8..<24).compactMap { i -> UInt8? in
            let b = data[offset + i]
            return b == 0 ? nil : b
        }
        return String(bytes: chars, encoding: .utf8)
    }

    private func readSegmentField(_ offset: Int, fieldOffset: Int) -> UInt64? {
        let abs = offset + fieldOffset
        guard abs >= 0, abs + 8 <= data.count else { return nil }
        var value = data.withUnsafeBytes { buf in
            buf.load(fromByteOffset: abs, as: UInt64.self)
        }
        return value
    }

    private func toHost32(_ offset: Int, swapped: Bool) -> UInt32? {
        guard let v = readU32(offset) else { return nil }
        return toHost(v, swapped: swapped)
    }

    private func readDylibName(_ offset: Int, cmdsize: Int) -> String? {
        // LC_LOAD_DYLIB 结构：cmd(4) cmdsize(4) 依赖名偏移(4) 时间戳(4) 当前版本(4) 兼容版本(4) 然后字符串
        let nameOffset = offset + 24
        guard nameOffset < data.count else { return nil }
        let end = min(offset + cmdsize, data.count)
        var chars: [UInt8] = []
        var i = nameOffset
        while i < end {
            let b = data[i]
            if b == 0 { break }
            chars.append(b)
            i += 1
        }
        return String(bytes: chars, encoding: .utf8)
    }

    // MARK: - 符号表

    private func parseSymbols(_ symoff: Int, nsyms: Int, stroff: Int, swapped: Bool, into info: inout MachOInfo) {
        // nlist_64: strx(4) type(1) sect(1) desc(2) value(8) = 16 字节
        guard symoff >= 0, symoff + nsyms * 16 <= data.count else { return }
        var symbols: [SymbolEntry] = []
        let maxSymbols = min(nsyms, 5000)
        for i in 0..<maxSymbols {
            let base = symoff + i * 16
            guard base + 16 <= data.count else { break }
            let strx = Int(toHost32(base, swapped: swapped) ?? 0)
            let type = data[base + 4]
            let value = toHost64(readSegmentField(base, fieldOffset: 8) ?? 0, swapped: swapped)

            // 解析符号名（strtab）
            if let name = stringAtStroff(strx, stroff: stroff) {
                var sym = SymbolEntry()
                sym.name = name
                sym.address = value
                sym.type = symbolTypeString(type)
                symbols.append(sym)
            }
        }
        info.symbols = symbols
    }

    private func stringAtStroff(_ strx: Int, stroff: Int) -> String? {
        guard strx >= 0 else { return nil }
        let fileOffset = stroff + strx
        guard fileOffset >= 0, fileOffset < data.count else { return nil }
        var chars: [UInt8] = []
        var i = fileOffset
        while i < data.count {
            let b = data[i]
            if b == 0 { break }
            chars.append(b)
            i += 1
            if chars.count > 512 { break }
        }
        return String(bytes: chars, encoding: .utf8)
    }

    private func symbolTypeString(_ type: UInt8) -> String {
        let nType = type & 0x0E
        switch nType {
        case 0x02: return "SECT"
        case 0x01: return "UNDF"
        case 0x04: return "ABS"
        default: return "type\(type)"
        }
    }
}
