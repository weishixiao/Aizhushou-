import Foundation
import zlib

/// 纯 Swift 的 ZIP 读取器：解析中央目录，提取指定条目。
/// 支持 store(0) 与 deflate(8) 两种压缩方法，不依赖 /usr/bin/unzip。
final class ZipReader {

    struct Entry {
        var name: String
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
        var method: UInt16
        var data: Data?
    }

    enum ZipError: Error {
        case notZip
        case corrupted(String)
        case unsupportedMethod(UInt16)
    }

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    /// 读取全部条目元数据（含解压后的数据）
    func readEntries() throws -> [Entry] {
        guard let eocd = findEOCD() else { throw ZipError.notZip }
        let cdOffset = Int(readU32(at: eocd + 16) ?? 0)
        let cdSize = Int(readU32(at: eocd + 12) ?? 0)
        let cdCount = Int(readU16(at: eocd + 10) ?? 0)

        var entries: [Entry] = []
        var cursor = cdOffset
        for _ in 0..<cdCount {
            guard cursor + 46 <= data.count,
                  readU32(at: cursor) == 0x02014B50 else {
                throw ZipError.corrupted("中央目录条目损坏")
            }
            let method = readU16(at: cursor + 10) ?? 0
            let compressedSize = Int(readU32(at: cursor + 20) ?? 0)
            let uncompressedSize = Int(readU32(at: cursor + 24) ?? 0)
            let nameLen = Int(readU16(at: cursor + 28) ?? 0)
            let extraLen = Int(readU16(at: cursor + 30) ?? 0)
            let commentLen = Int(readU16(at: cursor + 32) ?? 0)
            let localOffset = Int(readU32(at: cursor + 42) ?? 0)

            let nameStart = cursor + 46
            guard nameStart + nameLen <= data.count else { throw ZipError.corrupted("文件名越界") }
            let nameBytes = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(bytes: nameBytes, encoding: .utf8) ?? ""

            var entry = Entry(name: name,
                              compressedSize: compressedSize,
                              uncompressedSize: uncompressedSize,
                              localHeaderOffset: localOffset,
                              method: method)
            entry.data = extractData(for: entry)
            entries.append(entry)

            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// 读取某个条目
    func entry(named name: String) -> Entry? {
        guard let entries = try? readEntries() else { return nil }
        return entries.first { $0.name == name || $0.name.hasSuffix(name) }
    }

    private func extractData(for entry: Entry) -> Data? {
        // local file header: sig(4) ver(2) flag(2) method(2) time(2) date(2) crc(4) csize(4) usize(4) nameLen(2) extraLen(2)
        let base = entry.localHeaderOffset
        guard base >= 0, base + 30 <= data.count else { return nil }
        let nameLen = Int(readU16(at: base + 26) ?? 0)
        let extraLen = Int(readU16(at: base + 28) ?? 0)
        let payloadStart = base + 30 + nameLen + extraLen
        guard payloadStart + entry.compressedSize <= data.count else { return nil }

        let raw = data.subdata(in: payloadStart..<(payloadStart + entry.compressedSize))

        switch entry.method {
        case 0: // stored
            return raw
        case 8: // deflate
            return inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    private func inflate(_ input: Data, expectedSize: Int) -> Data? {
        // ZIP 内是 raw deflate（无 zlib 头）。用系统 zlib 的 windowBits=-15 直接解 raw deflate，
        // 避免 Compression 框架对 zlib 包裹的依赖（之前补假头/假 adler 在真机上不稳定）。
        var zstream = z_stream()
        var initStatus: Int32 = Z_STREAM_ERROR
        let streamSize = Int32(MemoryLayout<z_stream>.size)
        let windowBits: Int32 = -MAX_WBITS

        ZLIB_VERSION.withCString { versionPtr in
            input.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                zstream.next_in = UnsafeMutablePointer<UInt8>(mutating: base.assumingMemoryBound(to: UInt8.self))
                zstream.avail_in = uInt(input.count)
                initStatus = inflateInit2_(&zstream, windowBits, versionPtr, streamSize)
            }
        }
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&zstream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)

        // 循环解压：耗尽输入或到达流尾时结束
        while true {
            var ret: Int32 = Z_OK
            var bytesWritten = 0
            let before = Int(zstream.avail_in)
            let bufSize = buffer.count
            buffer.withUnsafeMutableBytes { dst -> Void in
                guard let base = dst.baseAddress else { return }
                zstream.next_out = base.assumingMemoryBound(to: UInt8.self)
                zstream.avail_out = uInt(bufSize)
                ret = zlib.inflate(&zstream, Z_NO_FLUSH)
                bytesWritten = bufSize - Int(zstream.avail_out)
            }
            guard ret == Z_OK || ret == Z_STREAM_END else { return nil }
            output.append(buffer, count: bytesWritten)

            if ret == Z_STREAM_END || bytesWritten == 0 {
                break
            }
            let consumed = before - Int(zstream.avail_in)
            if consumed == 0 || zstream.avail_in == 0 {
                break
            }
        }
        return output
    }

    // MARK: - 二进制读取辅助

    private func findEOCD() -> Int? {
        // EOCD signature 0x06054B50，在文件尾部 64KB+22 范围内
        let searchLen = min(data.count, 65536 + 22)
        let start = data.count - searchLen
        guard start >= 0 else { return nil }
        for i in stride(from: data.count - 22, through: start, by: -1) {
            if readU32(at: i) == 0x06054B50 {
                return i
            }
        }
        return nil
    }

    private func readU16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) }
    }

    private func readU32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
    }
}
