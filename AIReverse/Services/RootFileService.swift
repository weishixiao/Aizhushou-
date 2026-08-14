import Foundation

/// RootFS 目录浏览条目
struct RootFileEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    let permissions: String
    let isSymlink: Bool

    var displaySize: String {
        guard !isDirectory else { return "DIR" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var permissionText: String {
        permissions.isEmpty ? "?" : permissions
    }
}

/// 文件内容预览结果
struct FileContentPreview {
    enum Kind {
        case text
        case hex
    }
    let kind: Kind
    let content: String
    let truncated: Bool
}

/// RootFS 文件系统浏览服务：遍历全文件系统（依赖 no-sandbox entitlement）
final class RootFileService {

    enum RootFileError: LocalizedError {
        case accessDenied(String)
        var errorDescription: String? {
            switch self {
            case .accessDenied(let path):
                return "无权访问：\(path)"
            }
        }
    }

    private let fm = FileManager.default

    /// 列出目录内容，目录优先，按名称排序
    func listDirectory(at path: String) throws -> [RootFileEntry] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .posixPermissionsKey]
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            throw RootFileError.accessDenied(path)
        }

        let entries = children.map { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let isLink = values?.isSymbolicLink ?? false
            let perms = Self.permissionString(values?.posixPermissions?.intValue ?? 0)
            return RootFileEntry(
                id: child.path,
                name: child.lastPathComponent.isEmpty ? child.path : child.lastPathComponent,
                url: child,
                isDirectory: isDir,
                size: values?.fileSize?.int64Value ?? 0,
                modificationDate: values?.contentModificationDate,
                permissions: perms,
                isSymlink: isLink
            )
        }
        return entries.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// 路径是否存在且可读
    func isAccessible(_ path: String) -> Bool {
        fm.isReadableFile(atPath: path)
    }

    /// 读取文件内容。文本文件返回解码文本；二进制文件返回十六进制预览。
    /// maxBytes 控制最多读取字节数，避免大文件占用过多内存。
    func readFile(at path: String, maxBytes: Int = 1_048_576) throws -> FileContentPreview {
        let url = URL(fileURLWithPath: path)
        guard fm.isReadableFile(atPath: path) else {
            throw RootFileError.accessDenied(path)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw RootFileError.accessDenied(path)
        }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: maxBytes)
        let truncated = data.count >= maxBytes

        if let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains(where: { isControlCharacter($0) }) {
            return FileContentPreview(kind: .text, content: text, truncated: truncated)
        }
        return FileContentPreview(
            kind: .hex,
            content: Self.hexDump(data),
            truncated: truncated
        )
    }

    private func isControlCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// 生成 16 字节一行的十六进制转储
    private static func hexDump(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let slice = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = slice.map { byte -> Character in
                let c = Character(UnicodeScalar(byte))
                return (byte >= 0x20 && byte < 0x7F) ? c : "."
            }
            lines.append(String(format: "%08x  %-47s  %@", offset, hex, String(ascii)))
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    /// 将 POSIX 权限数值转换为 rwx 字符串
    private static func permissionString(_ mode: Int) -> String {
        guard mode != 0 else { return "" }
        var out = ""
        let m = Int(mode)
        out += m & 0o400 != 0 ? "r" : "-"
        out += m & 0o200 != 0 ? "w" : "-"
        out += m & 0o100 != 0 ? "x" : "-"
        out += m & 0o040 != 0 ? "r" : "-"
        out += m & 0o020 != 0 ? "w" : "-"
        out += m & 0o010 != 0 ? "x" : "-"
        out += m & 0o004 != 0 ? "r" : "-"
        out += m & 0o002 != 0 ? "w" : "-"
        out += m & 0o001 != 0 ? "x" : "-"
        return out
    }
}
