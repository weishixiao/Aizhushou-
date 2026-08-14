import Foundation

/// 应用分析协调器：负责解压 .tipa/.ipa、定位主二进制、串联各解析器。
final class AppAnalyzer {

    /// 分析一个文件，返回完整分析结果
    func analyze(url: URL, progress: ((String) -> Void)? = nil) async -> AnalysisResult {
        progress?("读取文件...")

        var targetData: Data?
        var fileName = url.lastPathComponent

        // 1. 如果是 .tipa/.ipa，解压并定位 Payload/*.app 内的主二进制数据
        if ["tipa", "ipa"].contains(url.pathExtension.lowercased()) {
            progress?("解压应用包...")
            guard let extracted = extractMainBinary(from: url) else {
                var macho = MachOInfo()
                macho.fileName = fileName
                macho.errorMessage = "无法从应用包中定位主二进制"
                return AnalysisResult(url: url, macho: macho)
            }
            targetData = extracted.data
            fileName = extracted.name
        }
        // 2. 如果是 .app 目录，找主二进制（与目录同名，或 Mach-O 魔数）
        else if url.hasDirectoryPath && url.pathExtension == "app" {
            let fm = FileManager.default
            if let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                let exeName = url.deletingPathExtension().lastPathComponent
                if let exe = entries.first(where: { $0.lastPathComponent == exeName }) {
                    targetData = try? Data(contentsOf: exe)
                    fileName = exe.lastPathComponent
                } else if let exe = entries.first(where: {
                    !$0.lastPathComponent.contains(".")
                        && (try? Data(contentsOf: $0)).map { isMachOMagic($0) } == true
                }) {
                    targetData = try? Data(contentsOf: exe)
                    fileName = exe.lastPathComponent
                }
            }
        }
        // 3. 否则当作裸二进制读取
        else {
            targetData = try? Data(contentsOf: url)
        }

        guard let data = targetData else {
            var macho = MachOInfo()
            macho.fileName = fileName
            macho.errorMessage = "文件读取失败"
            return AnalysisResult(url: url, macho: macho)
        }

        progress?("解析 Mach-O 头...")
        let parser = MachOParser(data: data)
        var macho = parser.parse()
        macho.fileName = fileName

        var classes: [ObjCClassInfo] = []
        var disasm: [DisasmLine] = []

        if macho.errorMessage == nil {
            progress?("解析 ObjC 元数据...")
            let objcParser = ObjCParser(data: data, segments: macho.segments, swapped: false)
            classes = objcParser.parseClasses()
            macho.objcClassCount = classes.count

            progress?("提取字符串...")
            let strExtractor = StringExtractor(data: data)
            macho.strings = strExtractor.extract()

            progress?("反汇编 __text 段...")
            if let text = macho.segments.first(where: { $0.name == "__TEXT" }) {
                let codeStart = Int(text.fileOffset)
                let codeLen = Int(text.fileSize)
                if codeStart >= 0, codeLen > 0, codeStart + codeLen <= data.count {
                    let code = data.subdata(in: codeStart..<(codeStart + codeLen))
                    let disasmEngine = ARM64Disassembler(code: code, baseAddr: text.vmAddr)
                    disasm = disasmEngine.disassemble(maxInstructions: 1500)
                }
            }
        }

        return AnalysisResult(url: url, macho: macho, objcClasses: classes, symbols: macho.symbols, disassembly: disasm)
    }

    /// 从 .tipa/.ipa 中提取主可执行文件数据
    private func extractMainBinary(from url: URL) -> (data: Data, name: String)? {
        guard let zipData = try? Data(contentsOf: url) else { return nil }
        let reader = ZipReader(data: zipData)

        guard let entries = try? reader.readEntries() else { return nil }

        // 收集所有 Payload/*.app/ 的直接子文件（parts.count == 3，不深入子目录）
        // 形如：Payload/Foo.app/Foo
        var directChildren: [(name: String, data: Data)] = []
        var appNames: [String] = []

        for e in entries where !e.name.hasSuffix("/") && e.name.contains(".app/") {
            let parts = e.name.split(separator: "/")
            guard parts.count == 3 else { continue }
            guard let d = e.data else { continue }
            let appName = parts[1].replacingOccurrences(of: ".app", with: "")
            if !appNames.contains(appName) {
                appNames.append(appName)
            }
            directChildren.append((String(parts[2]), d))
        }

        // 1) 优先：与 .app 同名的可执行文件（标准 iOS 布局 Payload/Foo.app/Foo）
        for appName in appNames {
            if let hit = directChildren.first(where: { $0.name == appName }) {
                return (hit.data, hit.name)
            }
        }
        // 2) 其次：文件头是 Mach-O 魔数的直接子文件
        if let hit = directChildren.first(where: { isMachOMagic($0.data) }) {
            return (hit.data, hit.name)
        }
        // 3) 兜底：无扩展名且体积最大的直接子文件
        let noExt = directChildren.filter { !$0.name.contains(".") }
        if let hit = noExt.max(by: { $0.data.count < $1.data.count }) {
            return (hit.data, hit.name)
        }
        return nil
    }

    /// 判断数据是否为 Mach-O 二进制（32/64 位及 fat，含字节交换变体）
    private func isMachOMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [data[data.startIndex], data[data.startIndex + 1], data[data.startIndex + 2], data[data.startIndex + 3]]
        let magic: UInt32 = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        switch magic {
        case 0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA:
            return true
        default:
            return false
        }
    }
}
