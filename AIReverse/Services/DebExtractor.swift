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
        let raw = try decompressTar(data: dataTar.data, name: dataTar.name)
        let files = try extractTar(raw)
        for file in files {
            try writeTarFile(file, into: dir)
        }
        return findDylibs(in: dir)
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
            return try inflateGzip(data)
        }
        if name.hasSuffix(".xz") || name.hasSuffix(".zst") || name.hasSuffix(".lzma") {
            throw DebExtractError(message: "deb 使用 \(name) 压缩，本机需安装 dpkg-deb 解压")
        }
        return data
    }

    private static func inflateGzip(_ data: Data) throws -> Data {
        if let raw = try? inflateZlib(data, algorithm: COMPRESSION_ZLIB), !raw.isEmpty {
            return raw
        }
        // 剥离 gzip 头后用 raw deflate 重试
        if let stripped = stripGzipHeader(data),
           let raw = try? inflateZlib(stripped, algorithm: COMPRESSION_RAW), !raw.isEmpty {
            return raw
        }
        throw DebExtractError(message: "gzip 数据解压失败")
    }

    private static func inflateZlib(_ data: Data, algorithm: compression_algorithm) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var capacity = max(data.count * 4, 65536)
        let maxCapacity = 512 * 1024 * 1024
        while capacity < maxCapacity {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let base = src.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dst, capacity,
                    base.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, algorithm
                )
            }
            if written > 0 {
                return Data(bytes: dst, count: written)
            }
            capacity *= 2
        }
        throw DebExtractError(message: "数据解压超过 512MB 上限")
    }

    /// RFC1952 gzip 头剥离（FLG/FEXTRA/FNAME/FCOMMENT/FHCRC）
    private static func stripGzipHeader(_ data: Data) -> Data? {
        guard data.count >= 10, data[0] == 0x1f, data[1] == 0x8b else { return nil }
        var offset = 10
        let flags = data[3]
        if flags & 0x04 != 0 {
            guard data.count >= offset + 2 else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 {
            offset += 2
        }
        guard offset <= data.count else { return nil }
        return data.subdata(in: offset..<data.count)
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
            case 0x6c: // GNU 长文件名（LongLink）
                pendingLongName = String(decoding: fileData, as: UTF8.self)
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
