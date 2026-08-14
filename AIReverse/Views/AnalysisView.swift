import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 分析视图：选择目标文件、触发分析、展示结果。
struct AnalysisView: View {
    @EnvironmentObject var analysisStore: AnalysisStore
    @State private var showFilePicker = false
    @State private var showFileBrowser = false
    @State private var isAnalyzing = false
    @State private var progressText = "准备就绪"
    @State private var selectedTab: AnalysisTab = .overview
    @State private var toastText: String?

    private let analyzer = AppAnalyzer()

    enum AnalysisTab: String, CaseIterable {
        case overview = "概览"
        case classes = "ObjC类"
        case symbols = "符号表"
        case strings = "字符串"
        case disasm = "反汇编"
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let result = analysisStore.activeResult {
                    resultView(result)
                } else {
                    emptyState
                }
            }
            .navigationTitle("分析")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showFileBrowser = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .disabled(isAnalyzing)

                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                    .disabled(isAnalyzing)
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPicker(onPick: { url in
                    importAndAnalyze(url: url)
                }, onCancel: {})
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showFileBrowser) {
                FileBrowserView()
                    .environmentObject(analysisStore)
            }
            .overlay {
                if isAnalyzing {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text(progressText)
                                .font(.body)
                                .foregroundColor(.white)
                            Text("大型 App 可能耗时较长")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(24)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemGray6)))
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = toastText {
                    Text(toast)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(8)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toastText = nil }
        }
    }

    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        showToast("已复制到剪贴板")
    }

    private func currentTabText(_ result: AnalysisResult) -> String {
        switch selectedTab {
        case .overview:
            return overviewText(result)
        case .classes:
            return result.objcClasses.map { cls in
                var line = "\(cls.name)"
                if !cls.superclassName.isEmpty { line += " : \(cls.superclassName)" }
                for m in cls.methods {
                    line += "\n  \(m.selector)  imp 0x\(String(format: "%08llX", m.imp))  \(m.typeEncoding)"
                }
                return line
            }.joined(separator: "\n")
        case .symbols:
            return result.symbols.map { String(format: "0x%08llX  %@", $0.address, $0.name) }.joined(separator: "\n")
        case .strings:
            return result.macho.strings.joined(separator: "\n")
        case .disasm:
            return result.disassembly.map { String(format: "0x%08llX  %@", $0.address, $0.text) }.joined(separator: "\n")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("选择一个要分析的 App")
                .font(.headline)
            Text("支持 .tipa / .ipa / .app 目录 / 裸 Mach-O 二进制")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button {
                showFilePicker = true
            } label: {
                Label("选择文件", systemImage: "folder")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }

            Button {
                showFileBrowser = true
            } label: {
                Label("浏览系统文件（越狱）", systemImage: "folder.badge.gearshape")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
            }

            if !analysisStore.importedFiles.isEmpty {
                Divider()
                    .padding(.horizontal, 24)
                Text("已导入文件")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(analysisStore.importedFiles) { file in
                            HStack {
                                Image(systemName: "doc.circle")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading) {
                                    Text(file.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(file.date, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button {
                                    reanalyze(file)
                                } label: {
                                    Text("重新分析")
                                        .font(.caption)
                                }
                                Button {
                                    analysisStore.removeImportedFile(file)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            .padding(.horizontal, 24)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private func reanalyze(_ file: ImportedFile) {
        analysisStore.loadImportedFile(file)
        startAnalysis(url: file.url)
    }

    @ViewBuilder
    private func resultView(_ result: AnalysisResult) -> some View {
        VStack(spacing: 0) {
            // 文件信息条
            VStack(alignment: .leading, spacing: 4) {
                Text(result.macho.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(result.macho.architectures.map(\.cpuType).joined(separator: ", ")) · ObjC \(result.macho.objcClassCount) 类 · \(result.macho.symbolCount) 符号 · \(result.macho.strings.count) 字符串")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))

            Picker("", selection: $selectedTab) {
                ForEach(AnalysisTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack {
                Spacer()
                Button {
                    copyToClipboard(currentTabText(result))
                } label: {
                    Label("复制当前内容", systemImage: "doc.on.doc")
                        .font(.footnote)
                }
                .padding(.horizontal)
            }

            ScrollView {
                switch selectedTab {
                case .overview: overviewView(result)
                case .classes: classesView(result)
                case .symbols: symbolsView(result)
                case .strings: stringsView(result)
                case .disasm: disasmView(result)
                }
            }
        }
    }

    // MARK: - 各标签内容

    private func overviewView(_ result: AnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let err = result.macho.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .padding()
            }
            infoRow("文件", result.url.lastPathComponent)
            infoRow("架构", result.macho.architectures.map { "\($0.cpuType) (\($0.cpuSubtype))" }.joined(separator: "\n"))
            infoRow("头信息", result.macho.header)
            infoRow("符号数量", "\(result.macho.symbolCount)")
            infoRow("ObjC 类", "\(result.macho.objcClassCount)")
            infoRow("字符串", "\(result.macho.strings.count)")

            if !result.macho.segments.isEmpty {
                Text("Segments")
                    .font(.headline)
                    .padding(.top, 8)
                ForEach(Array(result.macho.segments.enumerated()), id: \.offset) { _, seg in
                    infoRow(seg.name, String(format: "vmaddr 0x%08llX  fileoff 0x%08llX  size %llu", seg.vmAddr, seg.fileOffset, seg.fileSize))
                }
            }
        }
        .padding()
    }

    private func overviewText(_ result: AnalysisResult) -> String {
        var lines = ["文件: \(result.url.lastPathComponent)"]
        lines.append("架构: \(result.macho.architectures.map { "\($0.cpuType) (\($0.cpuSubtype))" }.joined(separator: ", "))")
        lines.append("头信息: \(result.macho.header)")
        lines.append("符号数量: \(result.macho.symbolCount)")
        lines.append("ObjC 类: \(result.macho.objcClassCount)")
        lines.append("字符串: \(result.macho.strings.count)")
        for seg in result.macho.segments {
            lines.append("\(seg.name): vmaddr 0x\(String(format: "%08llX", seg.vmAddr)) fileoff 0x\(String(format: "%08llX", seg.fileOffset)) size \(seg.fileSize)")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private func classesView(_ result: AnalysisResult) -> some View {
        if result.objcClasses.isEmpty {
            Text("未解析到 ObjC 类（可能是 Swift 应用或解析失败）")
                .foregroundColor(.secondary)
                .padding()
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(result.objcClasses.enumerated()), id: \.offset) { _, cls in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(cls.name)
                                .font(.headline)
                                .foregroundColor(.blue)
                            if !cls.superclassName.isEmpty {
                                Text(": \(cls.superclassName)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        ForEach(Array(cls.methods.enumerated()), id: \.offset) { _, m in
                            Text("  \(m.selector)")
                                .font(.system(.caption, design: .monospaced))

                                .foregroundColor(.primary)
                            Text(String(format: "      imp 0x%08llX  %@", m.imp, m.typeEncoding))
                                .font(.system(.caption2, design: .monospaced))

                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6).opacity(0.5))
                    .cornerRadius(8)
                }
            }
            .padding()
        }
    }

    @ViewBuilder private func symbolsView(_ result: AnalysisResult) -> some View {
        if result.symbols.isEmpty {
            Text("未解析到符号表")
                .foregroundColor(.secondary)
                .padding()
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(result.symbols.enumerated()), id: \.offset) { _, sym in
                    HStack {
                        Text(String(format: "0x%08llX", sym.address))
                            .font(.system(.caption, design: .monospaced))

                            .foregroundColor(.secondary)
                        Text(sym.name)
                            .font(.system(.caption, design: .monospaced))
                            
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder private func stringsView(_ result: AnalysisResult) -> some View {
        if result.macho.strings.isEmpty {
            Text("未提取到字符串")
                .foregroundColor(.secondary)
                .padding()
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(result.macho.strings.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(.system(.caption2, design: .monospaced))
                        
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 1)
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder private func disasmView(_ result: AnalysisResult) -> some View {
        if result.disassembly.isEmpty {
            Text("未找到 __text 段")
                .foregroundColor(.secondary)
                .padding()
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(result.disassembly.enumerated()), id: \.offset) { _, line in
                    HStack {
                        Text(String(format: "0x%08llX", line.address))
                            .font(.system(.caption2, design: .monospaced))

                            .foregroundColor(.secondary)
                        Text(line.text)
                            .font(.system(.caption2, design: .monospaced))
                            
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 触发分析

    private func importAndAnalyze(url: URL) {
        isAnalyzing = true
        progressText = "正在导入文件..."

        Task {
            var localURL = url
            do {
                // 复制进沙盒持久化（asCopy 已复制到 tmp，此处落到 Documents 长期保存）
                localURL = try analysisStore.importFile(from: url)
            } catch {
                await MainActor.run {
                    isAnalyzing = false
                    progressText = "文件导入失败"
                    showToast("文件导入失败：\(error.localizedDescription)")
                }
                return
            }

            let result = await analyzer.analyze(url: localURL) { msg in
                Task { @MainActor in
                    progressText = msg
                }
            }
            await MainActor.run {
                analysisStore.add(result)
                isAnalyzing = false
                progressText = "完成"
                if result.macho.errorMessage != nil {
                    showToast(result.macho.errorMessage!)
                }
            }
        }
    }

    private func startAnalysis(url: URL) {
        isAnalyzing = true
        progressText = "开始分析..."

        Task {
            let result = await analyzer.analyze(url: url) { msg in
                Task { @MainActor in
                    progressText = msg
                }
            }
            await MainActor.run {
                analysisStore.add(result)
                isAnalyzing = false
                progressText = "完成"
            }
        }
    }
}
