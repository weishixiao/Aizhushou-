import Foundation

/// 纯 Swift 的 Mach-O 编辑器
///
/// 用于在 arm64 / fat(arm64) 二进制中注入 LC_LOAD_DYLIB 加载命令，
/// 完全替代外部工具 insert_dylib / jtool，适配无 Procursus 工具的精简越狱环境。
///
/// 原理（参考 TrollStore / insert_dylib）：
/// 1. 在 load commands 区域找到 LC_CODE_SIGNATURE（或末尾），在其前插入新的 dylib_command
/// 2. 更新 mach_header 的 ncmds / sizeofcmds
/// 3. 所有绝对文件偏移（segment fileoff、linkedit 数据偏移、签名偏移等）整体 +delta
/// 4. 仅 __TEXT（fileoff==0）段内 section 的 offset 需要 +delta
enum MachOEditorError: LocalizedError {
    case invalidMachO(String)
    case alreadyInjected

    var errorDescription: String? {
        switch self {
        case .invalidMachO(let msg):
            return "无效的 Mach-O：\(msg)"
        case .alreadyInjected:
            return "该 dylib 已注入"
        }
    }
}

enum MachOEditor {

    // MARK: - 常量

    private static let MH_MAGIC_64: UInt32 = 0xfeedfacf
    private static let FAT_MAGIC: UInt32 = 0xcafebabe
    private static let CPU_TYPE_ARM64: Int32 = 0x0100000C

    private static let LC_LOAD_DYLIB: UInt32 = 0xC
    private static let LC_SYMTAB: UInt32 = 0x2
    private static let LC_DYSYMTAB: UInt32 = 0xB
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1D
    private static let LC_SEGMENT_SPLIT_INFO: UInt32 = 0x1E
    private static let LC_DYLD_INFO: UInt32 = 0x22
    private static let LC_FUNCTION_STARTS: UInt32 = 0x26
    private static let LC_DATA_IN_CODE: UInt32 = 0x29
    private static let LC_DYLIB_CODE_SIGN_DRS: UInt32 = 0x2B
    private static let LC_ENCRYPTION_INFO_64: UInt32 = 0x2C
    private static let LC_LINKER_OPTIMIZATION_HINT: UInt32 = 0x2E
    private static let LC_DYLD_EXPORTS_TRIE: UInt32 = 0x33
    private static let LC_DYLD_CHAINED_FIXUPS: UInt32 = 0x34

    // MARK: - 对外接口

    /// 检查二进制是否已包含目标 dylib 的 LC_LOAD_DYLIB
    static func containsDylib(_ dylibPath: String, in data: Data) throws -> Bool {
        let magic = try readU32(data, 0)
        if magic == MH_MAGIC_64 {
            return try containsDylib(inThin: data, dylibPath: dylibPath)
        }
        if try readBigU32(data, 0) == FAT_MAGIC {
            return try containsDylib(inFat: data, dylibPath: dylibPath)
        }
        throw MachOEditorError.invalidMachO("无法识别的魔数 0x\(String(magic, radix: 16))")
    }

    /// 注入 LC_LOAD_DYLIB，返回补丁后的完整二进制数据。
    /// - 若已注入相同 dylib，抛 MachOEditorError.alreadyInjected
    /// - 支持 thin arm64 与 fat（fat 内所有 arm64/arm64e slice 统一注入）
    static func patchData(_ original: Data, dylibPath: String) throws -> Data {
        let magic = try readU32(original, 0)
        if magic == MH_MAGIC_64 {
            return try patchThinArm64(original, dylibPath: dylibPath)
        }
        if try readBigU32(original, 0) == FAT_MAGIC {
            return try patchFat(original, dylibPath: dylibPath)
        }
        throw MachOEditorError.invalidMachO("无法识别的魔数 0x\(String(magic, radix: 16))")
    }

    // MARK: - Fat 处理

    private static func containsDylib(inFat data: Data, dylibPath: String) throws -> Bool {
        let archs = try fatArchs(data)
        for arch in archs {
            let slice = try sliceData(data, arch.offset, arch.size)
            if let magic = try? readU32(slice, 0), magic == MH_MAGIC_64 {
                if try containsDylib(inThin: slice, dylibPath: dylibPath) {
                    return true
                }
            }
        }
        return false
    }

    private static func patchFat(_ original: Data, dylibPath: String) throws -> Data {
        let archs = try fatArchs(original)
        guard !archs.isEmpty else {
            throw MachOEditorError.invalidMachO("fat 无架构")
        }

        var patchedSlices: [Int: Data] = [:]
        var rawSlices: [Int: Data] = [:]
        for (index, arch) in archs.enumerated() {
            let slice = try sliceData(original, arch.offset, arch.size)
            if arch.cputype == CPU_TYPE_ARM64 {
                let patched = try patchThinArm64(slice, dylibPath: dylibPath)
                patchedSlices[index] = patched
            } else {
                rawSlices[index] = slice
            }
        }
        guard !patchedSlices.isEmpty else {
            throw MachOEditorError.invalidMachO("fat 中未找到 arm64 slice")
        }

        // 重建 fat 文件：header + 依次写入各 slice（偏移重新累计）
        let headerSize = 8 + archs.count * 20
        var output = Data(capacity: headerSize + archs.reduce(0) { $0 + ($1.size) })
        appendBigU32(&output, FAT_MAGIC)
        appendBigU32(&output, UInt32(archs.count))

        var cursor = headerSize
        for (index, arch) in archs.enumerated() {
            let data = patchedSlices[index] ?? rawSlices[index]!
            appendBigU32(&output, UInt32(bitPattern: arch.cputype))
            appendBigU32(&output, UInt32(bitPattern: arch.cpusubtype))
            appendBigU32(&output, UInt32(cursor))
            appendBigU32(&output, UInt32(data.count))
            appendBigU32(&output, arch.align)
            cursor += data.count
        }
        for (index, arch) in archs.enumerated() {
            let data = patchedSlices[index] ?? rawSlices[index]!
            output.append(data)
        }
        return output
    }

    private struct FatArch {
        let cputype: Int32
        let cpusubtype: Int32
        let offset: Int
        let size: Int
        let align: UInt32
    }

    private static func fatArchs(_ data: Data) throws -> [FatArch] {
        guard data.count >= 8 else { throw MachOEditorError.invalidMachO("文件过短") }
        let count = Int(try readBigU32(data, 4))
        guard data.count >= 8 + count * 20 else { throw MachOEditorError.invalidMachO("fat 头损坏") }
        var result: [FatArch] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let base = 8 + i * 20
            result.append(FatArch(
                cputype: Int32(bitPattern: try readBigU32(data, base)),
                cpusubtype: Int32(bitPattern: try readBigU32(data, base + 4)),
                offset: Int(try readBigU32(data, base + 8)),
                size: Int(try readBigU32(data, base + 12)),
                align: try readBigU32(data, base + 16)
            ))
        }
        return result
    }

    // MARK: - Thin arm64 处理

    private static func containsDylib(inThin data: Data, dylibPath: String) throws -> Bool {
        let (ncmds, sizeofcmds) = try headerInfo(data)
        var offset = 32
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= data.count else { throw MachOEditorError.invalidMachO("load commands 越界") }
            let cmd = try readU32(data, offset)
            let cmdsize = Int(try readU32(data, offset + 4))
            guard cmdsize >= 8, offset + cmdsize <= 32 + Int(sizeofcmds) else {
                throw MachOEditorError.invalidMachO("load command 尺寸异常")
            }
            if cmd == LC_LOAD_DYLIB {
                let nameOffset = Int(try readU32(data, offset + 8))
                let nameStart = offset + nameOffset
                guard nameStart < offset + cmdsize else { throw MachOEditorError.invalidMachO("dylib name 越界") }
                let name = readCString(data, nameStart, limit: offset + cmdsize)
                if name == dylibPath {
                    return true
                }
            }
            offset += cmdsize
        }
        return false
    }

    private static func patchThinArm64(_ original: Data, dylibPath: String) throws -> Data {
        guard original.count >= 32 else { throw MachOEditorError.invalidMachO("文件过短") }
        guard try readU32(original, 0) == MH_MAGIC_64 else {
            throw MachOEditorError.invalidMachO("不是 arm64 Mach-O")
        }
        let already = try containsDylib(inThin: original, dylibPath: dylibPath)
        guard !already else {
            throw MachOEditorError.alreadyInjected
        }

        var (ncmds, sizeofcmds) = try headerInfo(original)
        guard 32 + Int(sizeofcmds) <= original.count else {
            throw MachOEditorError.invalidMachO("load commands 区域越界")
        }

        // 计算新 dylib_command 尺寸（24 字节头 + 路径字符串，8 字节对齐）
        let pathBytes = Array(dylibPath.utf8)
        let nameLen = pathBytes.count + 1
        let cmdSize = (24 + nameLen + 7) & ~7
        let delta = cmdSize

        // 确定插入点：LC_CODE_SIGNATURE 之前，否则 load commands 末尾
        var insertAt = 32 + Int(sizeofcmds)
        var offset = 32
        for _ in 0..<Int(ncmds) {
            let cmd = try readU32(original, offset)
            let cmdsize = Int(try readU32(original, offset + 4))
            if cmd == LC_CODE_SIGNATURE {
                insertAt = offset
                break
            }
            offset += cmdsize
        }

        // 拷贝 load commands 区域并对绝对偏移打补丁
        let cmdsDataStart = 32
        let cmdsLen = Int(sizeofcmds)
        var cmds = original.subdata(in: cmdsDataStart..<(cmdsDataStart + cmdsLen))
        try patchLoadCommandOffsets(&cmds, ncmds: Int(ncmds), delta: delta)

        // 构造新的 dylib_command
        var dylibCmd = Data(capacity: cmdSize)
        appendU32(&dylibCmd, LC_LOAD_DYLIB)
        appendU32(&dylibCmd, UInt32(cmdSize))
        appendU32(&dylibCmd, 24)
        appendU32(&dylibCmd, 2)
        appendU32(&dylibCmd, 0x10000)
        appendU32(&dylibCmd, 0x10000)
        dylibCmd.append(contentsOf: pathBytes)
        dylibCmd.append(0)
        while dylibCmd.count < cmdSize { dylibCmd.append(0) }

        // 重建：header + 前段 cmds + 新 command + 后段 cmds + 原始数据（整体后移 delta）
        var output = Data(capacity: original.count + delta)
        var header = original.subdata(in: 0..<32)
        setU32(&header, 16, ncmds + 1)
        setU32(&header, 20, UInt32(Int(sizeofcmds) + delta))
        output.append(header)
        output.append(cmds.subdata(in: 0..<(insertAt - cmdsDataStart)))
        output.append(dylibCmd)
        output.append(cmds.subdata(in: (insertAt - cmdsDataStart)..<cmdsLen))
        output.append(original.subdata(in: (cmdsDataStart + cmdsLen)..<original.count))
        return output
    }

    // MARK: - Load command 绝对偏移修正

    private static func patchLoadCommandOffsets(_ cmds: inout Data, ncmds: Int, delta: Int) {
        var offset = 0
        for _ in 0..<ncmds {
            guard offset + 8 <= cmds.count else { break }
            let cmd = (try? readU32(cmds, offset)) ?? 0
            let cmdsize = Int((try? readU32(cmds, offset + 4)) ?? 0)
            guard cmdsize >= 8, offset + cmdsize <= cmds.count else { break }

            switch cmd {
            case LC_SYMTAB:
                addU32(&cmds, offset + 8, delta)    // symoff
                addU32(&cmds, offset + 16, delta)   // stroff
            case LC_DYSYMTAB:
                addU32(&cmds, offset + 32, delta)   // tocoff
                addU32(&cmds, offset + 40, delta)   // modtaboff
                addU32(&cmds, offset + 48, delta)   // extrefsymoff
                addU32(&cmds, offset + 56, delta)   // indirectsymoff
                addU32(&cmds, offset + 64, delta)   // extreloff
                addU32(&cmds, offset + 72, delta)   // locreloff
            case LC_DYLD_INFO:
                addU32(&cmds, offset + 8, delta)    // rebase_off
                addU32(&cmds, offset + 16, delta)   // bind_off
                addU32(&cmds, offset + 24, delta)   // weak_bind_off
                addU32(&cmds, offset + 32, delta)   // lazy_bind_off
                addU32(&cmds, offset + 40, delta)   // export_off
            case LC_SEGMENT_64:
                let fileoff = (try? readU64(cmds, offset + 40)) ?? 0
                if fileoff == 0 {
                    // __TEXT：段内容后移，filesize 与所有 section offset 增加
                    addU64(&cmds, offset + 48, delta)   // filesize
                    let nsects = Int((try? readU32(cmds, offset + 64)) ?? 0)
                    var s = offset + 72
                    for _ in 0..<nsects where s + 80 <= cmds.count {
                        addU32(&cmds, s + 48, delta)    // section.offset（uint32）
                        s += 80
                    }
                } else {
                    addU64(&cmds, offset + 40, delta)   // fileoff
                }
            case LC_CODE_SIGNATURE,
                 LC_SEGMENT_SPLIT_INFO,
                 LC_FUNCTION_STARTS,
                 LC_DATA_IN_CODE,
                 LC_DYLIB_CODE_SIGN_DRS,
                 LC_LINKER_OPTIMIZATION_HINT,
                 LC_DYLD_EXPORTS_TRIE,
                 LC_DYLD_CHAINED_FIXUPS:
                addU32(&cmds, offset + 8, delta)    // dataoff
            case LC_ENCRYPTION_INFO_64:
                let cryptoff = (try? readU32(cmds, offset + 8)) ?? 0
                if cryptoff != 0 {
                    addU32(&cmds, offset + 8, delta)    // cryptoff
                }
            default:
                break
            }
            offset += cmdsize
        }
    }

    // MARK: - 字节序读写

    private static func headerInfo(_ data: Data) throws -> (UInt32, UInt32) {
        guard data.count >= 32 else { throw MachOEditorError.invalidMachO("文件过短") }
        let ncmds = try readU32(data, 16)
        let sizeofcmds = try readU32(data, 20)
        return (ncmds, sizeofcmds)
    }

    private static func readU32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw MachOEditorError.invalidMachO("读取越界") }
        return data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    private static func readU64(_ data: Data, _ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { throw MachOEditorError.invalidMachO("读取越界") }
        return data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }

    private static func readBigU32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw MachOEditorError.invalidMachO("读取越界") }
        return data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
    }

    private static func setU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    private static func addU32(_ data: inout Data, _ offset: Int, _ delta: Int) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        let old = (try? readU32(data, offset)) ?? 0
        setU32(&data, offset, UInt32(Int(old) + delta))
    }

    private static func addU64(_ data: inout Data, _ offset: Int, _ delta: Int) {
        guard offset >= 0, offset + 8 <= data.count else { return }
        let old = (try? readU64(data, offset)) ?? 0
        var v = (old + UInt64(delta)).littleEndian
        Swift.withUnsafeBytes(of: &v) { bytes in
            data.replaceSubrange(offset..<(offset + 8), with: bytes)
        }
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendBigU32(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readCString(_ data: Data, _ start: Int, limit: Int) -> String {
        var end = start
        while end < limit && data[end] != 0 { end += 1 }
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    private static func sliceData(_ data: Data, _ offset: Int, _ size: Int) throws -> Data {
        guard offset >= 0, size >= 0, offset + size <= data.count else {
            throw MachOEditorError.invalidMachO("slice 越界")
        }
        return data.subdata(in: offset..<(offset + size))
    }
}
