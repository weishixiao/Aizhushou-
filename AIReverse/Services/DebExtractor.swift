import Foundation
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
            return try inflateStream(data, algorithm: COMPRESSION_ZLIB)
        }
        if name.hasSuffix(".bz2") || (data.count > 3 && data[0] == 0x42 && data[1] == 0x5a && data[2] == 0x68) {
            return try inflateStream(data, algorithm: COMPRESSION_BZIP2)
        }
        if name.hasSuffix(".xz") || name.hasSuffix(".zst") || name.hasSuffix(".lzma") {
            throw DebExtractError(message: "deb 使用 \(name) 压缩，本机需安装 dpkg-deb 解压")
        }
        return data
    }

    /// 流式解压 gzip/zlib/bzip2 数据（COMPRESSION_ZLIB 自动识别 gzip 头），
    /// 输出按需分块，避免一次性 buffer 不足导致截断。
    private static func inflateStream(_ data: Data, algorithm: compression_algorithm) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = compression_stream()
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw DebExtractError(message: "初始化解压器失败")
        }
        defer { compression_stream_destroy(&stream) }

        let srcBuffer = [UInt8](data)
        stream.src_ptr = srcBuffer.withUnsafeBufferPointer { $0.baseAddress }
        stream.src_size = srcBuffer.count
        stream.dst_size = 0

        let outputCapacity = 65536
        var output = [UInt8](repeating: 0, count: outputCapacity)
        var result = Data()

        while true {
            if stream.dst_size == 0 {
                stream.dst_ptr = output.withUnsafeMutableBufferPointer { $0.baseAddress }
                stream.dst_size = outputCapacity
            }
            let beforeDst = stream.dst_size
            let status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE)
            let written = beforeDst - stream.dst_size
            if written > 0 {
                result.append(contentsOf: output.prefix(written))
            }
            if status == COMPRESSION_STATUS_END {
                break
            }
            guard status == COMPRESSION_STATUS_OK else {
                throw DebExtractError(message: "解压数据失败 (status=\(status.rawValue))")
            }
        }
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
