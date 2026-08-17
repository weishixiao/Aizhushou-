import Foundation
import zlib
import Compression

struct DebExtractError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 纯 Swift 实现的 .deb 解压器
///
/// 不依赖 python3 / dpkg-deb / ar 等外部命令，适配 iOS 越狱精简环境。
/// 支持 ar 归档 + gzip/裸 tar 的 data.tar 提取，递归收集 .dylib 文件。
/// 不支持 xz/zstd 压缩时抛出错误，由调用方回退到 dpkg-deb。
enum DebExtractor {

    /// 解压 deb 并返回其中所有 .dylib 文件的绝对路径
    static func extractDylibs(from debURL: URL, into dir: URL) throws -> [String] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Data(contentsOf: debURL)
        let members = try parseAr(data)
        guard let dataTar = members.first(where: { $0.name.hasPrefix("data.tar") }) else {
            throw DebExtractError(message: "deb 包中未找到 data.tar 归档成员")
        }
        RuntimeLogger.shared.info("deb", "找到 data.tar 成员：\(dataTar.name)（\(dataTar.data.count) 字节）")
        let raw = try decompressTar(data: dataTar.data, name: dataTar.name)
        RuntimeLogger.shared.info("deb", "data.tar 解压完成：\(raw.count) 字节")
        let files = try extractTar(raw)
        RuntimeLogger.shared.info("deb", "tar 解析出 \(files.count) 个文件")
        for file in files {
            try writeTarFile(file, into: dir)
        }
        let dylibs = findDylibs(in: dir)
        RuntimeLogger.shared.info("deb", "找到 \(dylibs.count) 个 .dylib 文件")
        return dylibs
    }

    // MARK: - ar 归档解析

    private static func parseAr(_ data: Data) throws -> [(name: String, data: Data)] {
        guard data.count >= 8, data.prefix(8) == Data("!<arch>\n".utf8) else {
            throw DebExtractError(message: "无效的 ar 归档（缺少 !<arch> 签名）")
        }
        var offset = 8
        var members: [(String, Data)] = []
        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<(offset + 60))
            let nameField = String(decoding: header.prefix(16), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sizeField = String(decoding: header.subdata(in: 48..<58), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let size = Int(sizeField) else { break }
            offset += 60
            guard offset + size <= data.count else {
                throw DebExtractError(message: "ar 成员数据越界（归档损坏）")
            }
            let memberData = data.subdata(in: offset..<(offset + size))
            var realName = nameField
            var realData = memberData
            if nameField.hasPrefix("#1/"), let len = Int(nameField.dropFirst(3)), len <= memberData.count {
                // BSD ar 扩展：长文件名存放在数据区头部
                realName = String(decoding: memberData.prefix(len), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                realData = memberData.dropFirst(len)
            }
            if !realName.isEmpty && realName != "/" && realName != "//" {
                members.append((realName, realData))
            }
            offset += size
            if size % 2 != 0 { offset += 1 }
        }
        return members
    }

    // MARK: - 压缩解压

    private static func decompressTar(data: Data, name: String) throws -> Data {
        if name.hasSuffix(".gz") || (data.count > 2 && data[0] == 0x1f && data[1] == 0x8b) {
            return try zlibInflate(data)
        }
        if name.hasSuffix(".lzma") || (data.count > 1 && data[0] == 0x5d) {
            return try lzmaDecompress(data)
        }
        if name.hasSuffix(".xz") {
            throw DebExtractError(message: "deb 使用 xz 压缩（data.tar.xz），暂不支持，请使用 gzip 压缩的 deb")
        }
        if name.hasSuffix(".bz2") {
            throw DebExtractError(message: "deb 使用 bzip2 压缩（data.tar.bz2），暂不支持，请使用 gzip 压缩的 deb")
        }
        if name.hasSuffix(".zst") {
            throw DebExtractError(message: "deb 使用 zstd 压缩（data.tar.zst），暂不支持，请使用 gzip 压缩的 deb")
        }
        return data
    }

    /// 用 libcompression 流式解压 LZMA-alone（.lzma 格式，含 13 字节头），
    /// 完整输出到结束标记，避免单次缓冲解压截断。
    private static func lzmaDecompress(_ data: Data) throws -> Data {
        guard data.count >= 13 else {
            throw DebExtractError(message: "LZMA 数据过短（缺少头部）")
        }
        var dummyIn: UInt8 = 0
        var dummyOut: UInt8 = 0
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer(&dummyOut),
            dst_size: 0,
            src_ptr: UnsafePointer(&dummyIn),
            src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
        guard initStatus != COMPRESSION_STATUS_ERROR else {
            throw DebExtractError(message: "LZMA 解压器初始化失败")
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 262144
        var dst = [UInt8](repeating: 0, count: chunkSize)
        var output = Data()
        let src = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UnsafePointer<UInt8> in
            raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        }
        var srcIndex = 0
        var status: compression_status = COMPRESSION_STATUS_OK
        repeat {
            stream.src_ptr = src.advanced(by: srcIndex)
            stream.src_size = data.count - srcIndex
            stream.dst_ptr = dst.withUnsafeMutableBufferPointer { $0.baseAddress! }
            stream.dst_size = chunkSize
            status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let written = chunkSize - Int(stream.dst_size)
            if written > 0 {
                output.append(contentsOf: dst.prefix(written))
            }
            let prevSrcIndex = srcIndex
            srcIndex = data.count - Int(stream.src_size)
            if written == 0 && srcIndex == prevSrcIndex { break }
        } while status == COMPRESSION_STATUS_OK
        guard status == COMPRESSION_STATUS_END else {
            throw DebExtractError(message: "LZMA 解压失败（status=\(status.rawValue)）")
        }
        return output
    }

    /// 用 libz 流式解压 gzip/zlib（windowBits=47 自动识别 gzip 头），完整输出，避免截断。
    private static func zlibInflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let srcPtr = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UnsafePointer<Bytef>? in
            raw.baseAddress?.assumingMemoryBound(to: Bytef.self)
        }
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcPtr)
        stream.avail_in = uInt(data.count)

        let initStatus = inflateInit2_(&stream, 47, "1.2.11", Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw DebExtractError(message: "初始化解压器失败 (zlib status=\(initStatus))")
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 65536
        var out = [Bytef](repeating: 0, count: chunkSize)
        var result = Data()
        var status: Int32 = Z_OK
        repeat {
            stream.next_out = out.withUnsafeMutableBufferPointer { $0.baseAddress }
            stream.avail_out = uInt(chunkSize)
            status = inflate(&stream, Z_NO_FLUSH)
            guard status == Z_OK || status == Z_STREAM_END else {
                throw DebExtractError(message: "解压数据失败 (zlib status=\(status))")
            }
            let written = chunkSize - Int(stream.avail_out)
            if written > 0 {
                result.append(contentsOf: out.prefix(written))
            }
        } while status != Z_STREAM_END
        return result
    }

    // MARK: - tar 解析（ustar + GNU LongLink）

    private static func extractTar(_ data: Data) throws -> [(path: String, data: Data)] {
        var files: [(String, Data)] = []
        var offset = 0
        var pendingLongName: String?
        let count = data.count
        while offset + 512 <= count {
            let block = data.subdata(in: offset..<(offset + 512))
            if block.allSatisfy({ $0 == 0 }) { break }
            let name = tarString(block, offset: 0, length: 100)
            let size = Int(tarString(block, offset: 124, length: 12), radix: 8) ?? 0
            let typeFlag = block[156]
            let prefix = tarString(block, offset: 345, length: 155)
            let fullName = prefix.isEmpty ? name : "\(prefix)/\(name)"
            offset += 512
            guard offset + size <= count else {
                throw DebExtractError(message: "tar 成员数据越界（归档损坏）")
            }
            let fileData = data.subdata(in: offset..<(offset + size))
            offset += size
            if size % 512 != 0 { offset += 512 - (size % 512) }

            switch typeFlag {
            case 0x4c: // GNU 长文件名（LongLink，typeflag 'L'）
                let nameBytes = fileData.prefix { $0 != 0 }
                pendingLongName = String(decoding: nameBytes, as: UTF8.self)
            case 0x78, 0x67: // PAX / GNU 扩展头，忽略
                break
            case 0x30, 0x00: // 普通文件
                let finalName = pendingLongName ?? fullName
                pendingLongName = nil
                if !finalName.isEmpty {
                    files.append((finalName, fileData))
                }
            default:
                pendingLongName = nil
            }
        }
        return files
    }

    private static func tarString(_ block: Data, offset: Int, length: Int) -> String {
        let start = min(offset, block.count)
        let end = min(offset + length, block.count)
        let bytes = block[start..<end]
        let truncated = bytes.prefix { $0 != 0 }
        return String(decoding: truncated, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 写出

    private static func writeTarFile(_ file: (path: String, data: Data), into dir: URL) throws {
        let components = file.path.split(separator: Character("/")).map(String.init)
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
        guard !components.isEmpty else { return }
        var target = dir
        for component in components.dropLast() {
            target = target.appendingPathComponent(component)
        }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let dest = target.appendingPathComponent(components.last ?? "")
        try file.data.write(to: dest)
    }

    private static func findDylibs(in dir: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "dylib" {
            result.append(url.path)
        }
        return result
    }
}
