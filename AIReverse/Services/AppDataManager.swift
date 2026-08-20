import Foundation

// MARK: - 应用数据容器信息
struct AppDataInfo: Identifiable, Equatable {
    let id = UUID()
    var bundleID: String
    var displayName: String
    var containerUUID: String
    var dataPath: String      // Data 容器
    var libraryPath: String   // Library 容器
    var bundlePath: String    // .app Bundle

    init(bundleID: String, displayName: String, containerUUID: String, dataPath: String, libraryPath: String, bundlePath: String) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.containerUUID = containerUUID
        self.dataPath = dataPath
        self.libraryPath = libraryPath
        self.bundlePath = bundlePath
    }

    static func == (lhs: AppDataInfo, rhs: AppDataInfo) -> Bool {
        lhs.bundleID == rhs.bundleID
    }
}

// MARK: - 文件信息
struct DataFileInfo: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modificationDate: Date

    static func == (lhs: DataFileInfo, rhs: DataFileInfo) -> Bool {
        lhs.path == rhs.path
    }
}

// MARK: - 文件编辑模式
enum FileEditMode: String {
    case text = "text"
    case hex = "hex"
}

// MARK: - 应用数据管理器
final class AppDataManager: ObservableObject {
    @Published var appsData: [AppDataInfo] = []
    @Published var selectedApp: AppDataInfo?
    @Published var fileEntries: [DataFileInfo] = []
    @Published var currentPath = ""
    @Published var fileContent = ""
    @Published var fileEditMode: FileEditMode = .text
    @Published var isBusy = false
    @Published var searchResults: [DataFileInfo] = []

    private let lock = NSLock()

    // MARK: - 初始化

    init() {}

    // MARK: - 列出所有 App 数据

    func refreshAllAppsData() {
        isBusy = true
        Task {
            let infoList = await findAllAppsData()
            await MainActor.run {
                self.appsData = infoList.sorted { $0.displayName < $1.displayName }
                self.isBusy = false
            }
        }
    }

    func selectApp(_ app: AppDataInfo) {
        selectedApp = app
        currentPath = app.dataPath
        fileEntries = []
        fileContent = ""
        listFiles(path: app.dataPath)
    }

    /// 通过名称或 Bundle ID 模糊查找并选中 App
    func selectAppByName(_ nameOrID: String) {
        Task {
            if appsData.isEmpty {
                refreshAllAppsData()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await MainActor.run {
                if let app = appsData.first(where: {
                    $0.displayName.localizedCaseInsensitiveContains(nameOrID) ||
                    $0.bundleID.localizedCaseInsensitiveContains(nameOrID)
                }) {
                    selectApp(app)
                } else if let first = appsData.first {
                    selectApp(first)
                }
            }
        }
    }

    // MARK: - 文件浏览

    func listFiles(path: String) {
        currentPath = path
        Task {
            let entries = await enumerateDirectory(path: path)
            await MainActor.run {
                self.fileEntries = entries.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
        }
    }

    func goUp() {
        guard !currentPath.isEmpty, currentPath != "/" else { return }
        let url = URL(fileURLWithPath: currentPath)
        listFiles(path: url.deletingLastPathComponent().path)
    }

    func goHome() {
        if let app = selectedApp {
            listFiles(path: app.dataPath)
        }
    }

    // MARK: - 文件读写

    func readFileContent(path: String, mode: FileEditMode = .text) async throws -> (content: String, mode: FileEditMode) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        let detectedMode: FileEditMode
        if mode == .text {
            // 检测是否为文本文件
            let isText = isTextData(data)
            detectedMode = isText ? .text : .hex
        } else {
            detectedMode = mode
        }

        let contentStr: String
        switch detectedMode {
        case .text:
            contentStr = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? ""
        case .hex:
            contentStr = formatHexView(data, width: 16)
        }

        return (content: contentStr, mode: detectedMode)
    }

    func writeFileContent(path: String, content: String, mode: FileEditMode) async throws {
        let data: Data
        switch mode {
        case .text:
            data = content.data(using: .utf8) ?? Data()
        case .hex:
            let hexData = hexViewToData(content)
            data = hexData ?? Data()
        }

        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        // 记录修改
        let oldLen = fileContent.count
        let newLen = content.count
        ModificationTracker.shared.addFileModification(
            path: path,
            oldValue: "长度: \(oldLen)",
            newValue: "长度: \(newLen)"
        )

        fileContent = content
    }

    // MARK: - 文件搜索

    func searchInFiles(basePath: String, pattern: String, maxResults: Int = 200) async -> [DataFileInfo] {
        var results: [DataFileInfo] = []
        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "com.ai.reverser.search")

        queue.async {
            var entries: [DataFileInfo] = []
            self.recursiveSearch(directory: basePath, pattern: pattern, maxResults: maxResults, results: &entries)
            semaphore.signal()
            results = entries
        }
        semaphore.wait()

        searchResults = results
        return results
    }

    // MARK: - Bundle 签名

    func reSignBundle(bundlePath: String) async -> Bool {
        let result = ShellExecutor.run(
            command: "codesign --force --sign - --preserve-metadata=identifier,entitlements \"\(bundlePath)\" 2>&1",
            timeout: 60
        )
        let success = result.success
        if !success {
            RuntimeLogger.shared.warning("DataMod", "重新签名失败: \(bundlePath) - \(result.output)")
        } else {
            RuntimeLogger.shared.info("DataMod", "重新签名成功: \(bundlePath)")
        }
        return success
    }

    // MARK: - 私有方法

    private func findAllAppsData() async -> [AppDataInfo] {
        var result: [AppDataInfo] = []

        // 扫描 Data 容器目录
        let dataDirs = [
            "/var/mobile/Containers/Data/Application",
            "/var/containers/Data/Application"
        ]

        for dataDir in dataDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dataDir) else { continue }

            for uuid in entries {
                let dataPath = (dataDir as NSString).appendingPathComponent(uuid)
                let libraryPath = "/var/mobile/Containers/Library/Application/\(uuid)"
                let libraryPath2 = "/var/containers/Library/Application/\(uuid)"

                // 尝试从 info.plist 获取 Bundle ID 和显示名称
                var bundleID = uuid
                var displayName = uuid

                let infoPlistPath = dataPath + "/.com.apple.mobile_container_manager.metadata.plist"
                if let meta = try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: infoPlistPath)), format: nil) as? [String: Any] {
                    if let appInfo = meta["ApplicationProperties"] as? [String: Any] {
                        bundleID = appInfo["ApplicationIdentifier"] as? String ?? uuid
                        displayName = appInfo["ApplicationName"] as? String ?? uuid
                    }
                }

                // 尝试从 app 的 Info.plist 获取
                let appMetaPath = dataPath + "/.appMetadata.plist"
                if let meta = try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: appMetaPath)), format: nil) as? [String: Any] {
                    bundleID = meta["CFBundleIdentifier"] as? String ?? bundleID
                    displayName = meta["CFBundleDisplayName"] as? String ?? meta["CFBundleName"] as? String ?? displayName
                }

                let effectiveLibrary = FileManager.default.fileExists(atPath: libraryPath) ? libraryPath : libraryPath2
                let bundlePath = try await findBundlePath(bundleID: bundleID)

                result.append(AppDataInfo(
                    bundleID: bundleID,
                    displayName: displayName,
                    containerUUID: uuid,
                    dataPath: dataPath,
                    libraryPath: effectiveLibrary,
                    bundlePath: bundlePath
                ))
            }
        }

        return result
    }

    private func findBundlePath(bundleID: String) async -> String {
        let appsDir = "/var/containers/Bundle/Application"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: appsDir) else { return "" }

        for uuid in entries {
            let appDir = appsDir + "/\(uuid)"
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: appDir) else { continue }

            for item in items where item.hasSuffix(".app") {
                let appPath = appDir + "/\(item)"
                let infoPath = appPath + "/Info.plist"
                guard let info = NSDictionary(contentsOfFile: infoPath) else { continue }
                if let bid = info["CFBundleIdentifier"] as? String, bid == bundleID {
                    return appPath
                }
            }
        }
        return ""
    }

    private func enumerateDirectory(path: String) async -> [DataFileInfo] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }

        return entries.compactMap { name in
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }

            var size: Int64 = 0
            if !isDir.boolValue {
                let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
                size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }

            let modDate = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.modificationDate] as? Date) ?? Date()

            return DataFileInfo(name: name, path: fullPath, isDirectory: isDir.boolValue, size: size, modificationDate: modDate)
        }
    }

    private func recursiveSearch(directory: String, pattern: String, maxResults: Int, results: inout [DataFileInfo]) {
        guard results.count < maxResults else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }

        for name in entries {
            let fullPath = (directory as NSString).appendingPathComponent(name)
            guard results.count < maxResults else { return }

            if try? FileManager.default.isReadableFile(atPath: fullPath) == true {
                if let content = try? String(contentsOf: URL(fileURLWithPath: fullPath), encoding: .utf8) {
                    if content.lowercased().contains(pattern.lowercased()) {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
                        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        results.append(DataFileInfo(name: name, path: fullPath, isDirectory: false, size: size, modificationDate: Date()))
                    }
                }
            }

            var isDir = ObjCBool(false)
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue {
                recursiveSearch(directory: fullPath, pattern: pattern, maxResults: maxResults, results: &results)
            }
        }
    }

    private func isTextData(_ data: Data) -> Bool {
        let sample = data.prefix(min(4096, data.count))
        let nonPrintable = sample.filter { byte -> Bool in
            byte < 9 || (byte > 13 && byte < 32) || byte > 126
        }
        return Double(nonPrintable.count) / Double(max(sample.count, 1)) < 0.1
    }

    private func formatHexView(_ data: Data, width: Int = 16) -> String {
        var lines: [String] = []
        let bytes = Array(data)

        for offset in stride(from: 0, to: bytes.count, by: width) {
            let end = min(offset + width, bytes.count)
            let slice = bytes[offset..<end]

            let hexPart = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            let asciiPart = slice.map { byte -> Character in
                byte >= 32 && byte <= 126 ? Character(UnicodeScalar(byte)) ?? "." : "."
            }.joined()

            lines.append(String(format: "%08X  %-48s  %@", offset, hexPart, asciiPart))
        }
        return lines.joined(separator: "\n")
    }

    private func hexViewToData(_ view: String) -> Data? {
        var bytes: [UInt8] = []
        let lines = view.components(separatedBy: .newlines)

        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }

            let hexTokens = parts[1].split(separator: " ").filter { !$0.isEmpty }
            for token in hexTokens {
                if let byte = UInt8(token, radix: 16) {
                    bytes.append(byte)
                } else {
                    return nil
                }
            }
        }
        return Data(bytes)
    }
}