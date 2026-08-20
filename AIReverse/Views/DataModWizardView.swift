import Foundation
import SwiftUI

// MARK: - 数据修改向导视图（步骤 2-4）
struct DataModWizardView: View {
    let targetProcess: ProcessInfo
    let onComplete: (() -> Void)?

    @StateObject private var memoryManager = MemoryManager()
    @StateObject private var appDataManager = AppDataManager()
    @StateObject private var modTracker = ModificationTracker.shared

    // UI 状态
    @State private var currentTab: WizardTab = .memory
    @State private var isAttached = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showProcessSelect = true

    // 内存扫描状态
    @State private var scanValue = ""
    @State private var scanType: ValueType = .uint32
    @State private var scanFilter: ScanFilter = .exact
    @State private var scanResults: [MemoryScanResult] = []
    @State private var scanState: ScanState = ScanState()
    @State private var progressText = ""
    @State private var progressFraction: Double = 0

    // 内存编辑（在 ResultRowView 内部处理）

    // 文件浏览
    @State private var selectedFile: DataFileInfo?
    @State private var editMode: FileEditMode = .text
    @State private var fileSearchText = ""
    @State private var showSearchResults = false
    @State private var showFileBrowser = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部状态栏
                topBar

                // 选项卡
                tabBar

                // 内容区
                if isAttached {
                    switch currentTab {
                    case .memory:
                        memoryTabView
                    case .file:
                        fileTabView
                    }
                } else {
                    attachingView
                }

                // 底部修改摘要栏
                if modTracker.modifications.count > 0 {
                    modificationSummaryBar
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("数据修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        detach()
                        onComplete?()
                    }
                }
            }
            .onAppear {
                attachToProcess()
                appDataManager.selectAppByName(targetProcess.name)
            }
            .onDisappear { detach() }
            .alert("错误", isPresented: .constant(errorMessage != nil)) {
                Button("确定") { errorMessage = nil }
            } message: {
                if let msg = errorMessage { Text(msg) }
            }
        }
    }

    // MARK: - 顶部状态栏

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: isAttached ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundColor(isAttached ? .green : .orange)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(targetProcess.name)
                        .font(.body).fontWeight(.semibold)
                        .foregroundColor(.primary)
                    HStack(spacing: 4) {
                        Text("PID: \(targetProcess.pid)")
                            .font(.caption2).foregroundColor(.secondary)
                        if isAttached {
                            Text("已附加").font(.caption2).foregroundColor(.green)
                        }
                    }
                }
            }
            Spacer()
            Button { detach(); attachToProcess() } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .overlay(Rectangle().fill(Color(.separator)).frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - 选项卡栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "内存修改", icon: "brain.fill", tab: .memory)
            tabButton(title: "文件修改", icon: "folder.fill", tab: .file)
        }
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    private func tabButton(title: String, icon: String, tab: WizardTab) -> some View {
        Button { currentTab = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(currentTab == tab ? accent : .secondary)
                Text(title)
                    .font(.caption2)
                    .fontWeight(currentTab == tab ? .semibold : .regular)
                    .foregroundColor(currentTab == tab ? accent : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 附加中

    private var attachingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("正在附加到进程…")
                .font(.body).foregroundColor(.secondary)
            Text("PID: \(targetProcess.pid)")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 80)
    }

    // MARK: - 内存标签页

    private var memoryTabView: some View {
        VStack(spacing: 0) {
            // 搜索配置区
            scanConfigSection

            // 扫描进度
            if isBusy {
                scanProgressView
            }

            // 结果区
            if !scanResults.isEmpty {
                resultHeader
                resultList
            } else if !isBusy {
                emptyScanResult
            }
        }
    }

    private var scanConfigSection: some View {
        VStack(spacing: 10) {
            // 值类型选择
            Picker("值类型", selection: $scanType) {
                ForEach(ValueType.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 100)
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                // 输入框
                HStack {
                    TextField("输入搜索值", text: $scanValue)
                        .font(.body)
                }
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(8)

                Spacer()

                // 扫描按钮
                Button { performScan() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: scanState.isEmpty ? "magnifyingglass" : "arrow.down.to.line")
                            .font(.caption)
                        Text(scanState.isEmpty ? "扫描" : "过滤")
                            .font(.caption2).fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(accent)
                    .cornerRadius(8)
                }
                .disabled(isBusy || scanValue.isEmpty)
            }

            // 过滤器（仅当有上次结果时显示）
            if !scanState.isEmpty {
                Picker("过滤器", selection: $scanFilter) {
                    ForEach(ScanFilter.allCases, id: \.$0) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 统计信息
            if !scanState.isEmpty {
                HStack(spacing: 12) {
                    statChip(label: "上次结果", value: "\(scanState.results.count)")
                    if scanState.regionCount > 0 {
                        statChip(label: "内存区", value: "\(scanState.regionCount)")
                    }
                    if scanState.totalBytes > 0 {
                        statChip(label: "扫描", value: formatBytes(scanState.totalBytes))
                    }
                    Spacer()
                    Button("清除") {
                        scanResults.removeAll()
                        scanState = ScanState()
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .overlay(Rectangle().fill(Color(.separator)).frame(height: 0.5), alignment: .bottom)
    }

    private var scanProgressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: progressFraction)
                .tint(accent)
            HStack {
                ProgressView()
                    .scaleEffect(0.5)
                    .tint(accent)
                Text(progressText)
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var resultHeader: some View {
        HStack {
            Text("搜索结果 (\(scanResults.count))")
                .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
            Spacer()
            Button {
                Task { await exportResults() }
            } label: {
                Text("导出").font(.caption2).foregroundColor(accent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(scanResults) { result in
                    ResultRowView(result: result, onFreeze: {
                        _ = try? memoryManager.freeze(addresses: [result.address])
                    }, onThaw: {
                        _ = try? memoryManager.thaw(addresses: [result.address])
                    }, onWriteValue: { address, newValue in
                        Task {
                            await writeMemoryValue(address: address, value: newValue)
                        }
                    })
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var emptyScanResult: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40)).foregroundColor(.secondary)
            Text(scanState.isEmpty ? "输入值并点击扫描" : "未找到匹配结果")
                .font(.body).foregroundColor(.secondary)
            if !scanState.isEmpty {
                Text("尝试其他值类型或过滤器")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 60)
    }

    // MARK: - 文件标签页

    private var fileTabView: some View {
        if showSearchResults {
            searchResultsView
        } else if let file = selectedFile {
            fileContentView(file: file)
        } else {
            fileBrowserView
        }
    }

    private var fileBrowserView: some View {
        VStack(spacing: 0) {
            // 路径导航
            pathBar

            // 搜索按钮
            HStack {
                Button {
                    fileSearchText = ""
                    Task {
                        let results = await appDataManager.searchInFiles(
                            basePath: currentFilePath,
                            pattern: fileSearchText
                        )
                        showSearchResults = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                        Text("搜索文件内容").font(.caption2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(.systemGray6)).cornerRadius(6)
                }
                .textFieldStyle(.roundedBorder)

                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            // 文件列表
            ScrollView {
                LazyVStack(spacing: 1) {
                    if !currentFilePath.isEmpty && currentFilePath != appDataManager.selectedApp?.dataPath {
                        FileRowView(file: DataFileInfo(
                            name: "..", path: URL(fileURLWithPath: currentFilePath).deletingLastPathComponent().path,
                            isDirectory: true, size: 0, modificationDate: Date())) {
                            appDataManager.goUp()
                        }
                    }

                    ForEach(appDataManager.fileEntries) { file in
                        FileRowView(file: file) {
                            if file.isDirectory {
                                appDataManager.listFiles(path: file.path)
                            } else {
                                selectedFile = file
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private var pathBar: some View {
        HStack {
            Button { appDataManager.goUp() } label: {
                Image(systemName: "arrow.left")
                    .foregroundColor(currentFilePath != appDataManager.selectedApp?.dataPath ? accent : .secondary)
            }
            .disabled(currentFilePath == appDataManager.selectedApp?.dataPath)

            Button { appDataManager.goHome() } label: {
                Image(systemName: "house.fill")
                    .foregroundColor(.secondary)
            }

            Text(currentFilePath)
                .font(.caption2).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var currentFilePath: String {
        appDataManager.currentPath
    }

    private var searchResultsView: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showSearchResults = false } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                        Text("返回")
                    }
                    .font(.caption2).foregroundColor(accent)
                }
                Spacer()
                Text("搜索: \(fileSearchText)").font(.caption2).foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.systemBackground))

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(appDataManager.searchResults) { file in
                        FileRowView(file: file) {
                            selectedFile = file
                            showSearchResults = false
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func fileContentView(file: DataFileInfo) -> some View {
        VStack(spacing: 0) {
            // 文件信息栏
            HStack {
                Button { selectedFile = nil } label: {
                    Image(systemName: "arrow.left")
                        .foregroundColor(accent)
                }
                Spacer()
                Button { saveFileContent() } label: {
                    Text("保存").font(.caption2).fontWeight(.semibold).foregroundColor(accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(.systemBackground))

            // 文件信息
            HStack(spacing: 8) {
                Text(file.name).font(.caption2).fontWeight(.semibold).foregroundColor(.primary).lineLimit(1)
                Spacer()
                Picker("模式", selection: $editMode) {
                    Text("文本").tag(FileEditMode.text)
                    Text("HEX").tag(FileEditMode.hex)
                }
                .pickerStyle(.segmented).frame(width: 120)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)

            // 文件内容编辑
            TextEditor(text: $appDataManager.fileContent)
                .font(editMode == .text ? .body : .caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(editMode == .hex ? Color(.systemGray6) : .clear)
        }
        .onAppear {
            Task { await loadFileContent(file) }
        }
    }

    // MARK: - 修改摘要栏

    private var modificationSummaryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(accent)
                .font(.system(size: 12))
            Text("修改记录: \(modTracker.modifications.count)")
                .font(.caption2).foregroundColor(.secondary)
            Spacer()
            Button {
                if let mod = modTracker.undoLast() {
                    // 在 UI 上移除对应结果
                    undoModification(mod)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.left").font(.caption)
                    Text("撤销").font(.caption2).fontWeight(.semibold)
                }
                .foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.orange).cornerRadius(6)
            }
            Button { modTracker.clear() } label: {
                Text("全部清除").font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(.systemGray6)).cornerRadius(6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(Rectangle().fill(Color(.separator)).frame(height: 0.5), alignment: .top)
    }

    // MARK: - 操作逻辑

    private func attachToProcess() {
        isAttached = false
        Task {
            do {
                try await memoryManager.attach(pid: targetProcess.pid)
                await MainActor.run { isAttached = true }
            } catch {
                await MainActor.run { errorMessage = "附加失败: \(error.localizedDescription)" }
            }
        }
    }

    private func detach() {
        memoryManager.detach()
        isAttached = false
    }

    private func performScan() {
        isBusy = true
        progressFraction = 0
        progressText = "正在扫描内存…"

        Task {
            let result: ScanState
            let displayType = scanType

            if scanState.isEmpty {
                // 首次扫描
                result = await memoryManager.performScan(
                    value: scanValue,
                    type: displayType,
                    onProgress: { pages, regions, bytes in
                        let total = max(regions * 100, 1)
                        await MainActor.run {
                            self.progressFraction = Double(pages) / Double(total)
                            self.progressText = "扫描中 \(pages)/\(regions) 区域 (\(formatBytes(bytes)))"
                        }
                    }
                )
            } else {
                // 后续过滤
                result = await memoryManager.filterResults(
                    previous: scanState,
                    value: scanValue,
                    type: displayType,
                    filter: scanFilter
                )
            }

            await MainActor.run {
                self.scanResults = result.results
                self.scanState = result
                self.isBusy = false
            }
        }
    }

    private func exportResults() async {
        guard !scanResults.isEmpty else { return }
        let lines = scanResults.map { r in
            "0x\(String(r.address, radix: 16).uppercased()): \(r.currentDisplay)"
        }
        let text = lines.joined(separator: "\n")
        UIAccessibility.post(notification: .screenChanged, argument: text)
        RuntimeLogger.shared.info("DataMod", "导出 \(scanResults.count) 个内存地址到剪贴板")
    }

    private func undoModification(_ mod: Modification) {
        guard mod.type == .memory, let address = UInt64(mod.description.components(separatedBy: "0x").last ?? "", radix: 16) else { return }
        Task {
            _ = await memoryManager.writeValue(address: address, value: mod.oldValue, type: scanType)
        }
        if let idx = scanResults.firstIndex(where: { $0.address == address }) {
            scanResults[idx] = MemoryScanResult(address: address, display: mod.oldValue)
        }
    }

    private func writeMemoryValue(address: UInt64, value: String) async {
        let oldDisplay = scanResults.first(where: { $0.address == address })?.currentDisplay ?? ""
        do {
            let newDisplay = try memoryManager.writeValue(address: address, value: value, type: scanType)
            if let idx = scanResults.firstIndex(where: { $0.address == address }) {
                scanResults[idx].currentDisplay = newDisplay
                scanResults[idx].isModified = true
            }
            ModificationTracker.shared.addMemoryModification(address: address, oldValue: oldDisplay, newValue: value)
        } catch {
            RuntimeLogger.shared.error("DataMod", "写入失败: \(error.localizedDescription)")
        }
    }

    private func loadFileContent(_ file: DataFileInfo) {
        Task {
            do {
                let (content, mode) = try await appDataManager.readFileContent(path: file.path, mode: editMode)
                await MainActor.run {
                    appDataManager.fileContent = content
                    if mode != editMode { editMode = mode }
                }
            } catch {
                await MainActor.run {
                    appDataManager.fileContent = "读取失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveFileContent() {
        guard let file = selectedFile else { return }
        isBusy = true
        Task {
            do {
                try await appDataManager.writeFileContent(
                    path: file.path,
                    content: appDataManager.fileContent,
                    mode: editMode
                )
                    isBusy = false
                    if file.path.hasSuffix(".app") || file.path.contains(".app/") {
                        let bundlePath = URL(fileURLWithPath: file.path).deletingPathExtension().path
                        _ = await appDataManager.reSignBundle(bundlePath: bundlePath)
                    }
            } catch {
                await MainActor.run {
                    errorMessage = "保存失败: \(error.localizedDescription)"
                    isBusy = false
                }
            }
        }
    }

    // MARK: - 工具方法

    private func formatBytes(_ bytes: Int) -> String {
        let divisor: Double = 1024
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= divisor && unitIndex < units.count - 1 {
            value /= divisor
            unitIndex += 1
        }
        return String(format: "%s %s", String(format: "%.1f", value), units[unitIndex])
    }

    private func statChip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.caption2).fontWeight(.semibold).foregroundColor(.primary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color(.systemGray6)).cornerRadius(4)
    }

    private var accent: Color { Color(red: 0.31, green: 0.68, blue: 1.0) }
}

// MARK: - 选项卡类型
enum WizardTab {
    case memory, file
}

// MARK: - 结果行视图
struct ResultRowView: View {
    let result: MemoryScanResult
    let onFreeze: () -> Void
    let onThaw: () -> Void
    let onWriteValue: (UInt64, String) -> Void

    @State private var showingEdit = false
    @State private var editValue = ""

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("0x\(String(result.address, radix: 16).uppercased())")
                    .font(.caption2).foregroundColor(.primary)
                Text(result.currentDisplay)
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundColor(result.isModified ? .red : accent)
            }

            Spacer()

            if result.isModified {
                Image(systemName: "link")
                    .foregroundColor(.red).font(.system(size: 10))
            }

            Button {
                editValue = result.currentDisplay
                showingEdit = true
            } label: {
                Image(systemName: "pencil")
                    .foregroundColor(.secondary).font(.system(size: 12))
            }

            Button {
                if result.isModified { onThaw() } else { onFreeze() }
            } label: {
                Image(systemName: result.isModified ? "link.slash" : "link")
                    .foregroundColor(result.isModified ? .red : .secondary)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(result.isModified ? Color.red.opacity(0.06) : .clear)
        .sheet(isPresented: $showingEdit) {
            NavigationView {
                Form {
                    TextField("新值", text: $editValue)
                        .keyboardType(.decimalPad)
                    Section {
                        Button("写入") {
                            onWriteValue(result.address, editValue)
                            showingEdit = false
                        }
                        Button("取消", role: .cancel) { showingEdit = false }
                    }
                }
                .navigationTitle("编辑内存值")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var accent: Color { Color(red: 0.31, green: 0.68, blue: 1.0) }
}

// MARK: - 文件行视图
struct FileRowView: View {
    let file: DataFileInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundColor(file.isDirectory ? .yellow : .secondary)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.body).foregroundColor(.primary).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        if file.isDirectory {
                            Text("文件夹").font(.caption2).foregroundColor(.secondary)
                        } else {
                            Text(formatFileSize(file.size)).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                if !file.isDirectory {
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let divisor: Double = 1024
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= divisor && unitIndex < units.count - 1 { value /= divisor; unitIndex += 1 }
        return String(format: "%.1f %s", value, units[unitIndex])
    }
}
