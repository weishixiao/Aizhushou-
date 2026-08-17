import SwiftUI
import UIKit

/// 内存修改工具箱 UI
///
/// 功能：
/// 1. 内存扫描（选择类型 → 输入值 → 搜索）
/// 2. 缩小搜索（二次筛选）
/// 3. 读写地址（修改内存值）
/// 4. 指针链追踪
/// 5. 代码段 Patch
/// 6. 枚举内存区域
struct MemoryView: View {
    @StateObject private var mem = MemoryTool.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchValue = ""
    @State private var selectedType: MemoryScanType = .u32
    @State private var selectedAddress: UInt64? = nil
    @State private var writeValue = ""
    @State private var errorMessage: String? = nil
    @State private var actionLog: String = ""
    @State private var showAdvanced = false
    @State private var pointerBase = ""
    @State private var pointerOffsets = ""
    @State private var patchAddress = ""

    let accent = Color(red: 0.10, green: 0.62, blue: 0.42)
    let resultLimit = 500  // 最多显示 500 条结果

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ── 扫描区 ──
                scanSection

                Divider()

                // ── 结果/操作区 ──
                ScrollView {
                    VStack(spacing: 10) {
                        resultSection
                        writeSection
                    }
                    .padding()
                }

                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                    .padding()
                    .background(Color.red.opacity(0.08))
                }
                if !actionLog.isEmpty {
                    Text(actionLog)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("内存修改工具箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button("高级") { showAdvanced = true }
                            .font(.caption)
                            .foregroundColor(accent)
                    }
                }
            }
        }
        .sheet(isPresented: $showAdvanced) {
            advancedView
        }
    }

    // MARK: - 扫描区

    private var scanSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("类型", selection: $selectedType) {
                    ForEach(MemoryScanType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 80)

                TextField("搜索值 (如 1250 或 FF 00 ?)", text: $searchValue)
                    .font(.system(size: 14, weight: .medium))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)

                Button {
                    performScan()
                } label: {
                    Image(systemName: mem.isScanning ? "hourglass" : "magnifyingglass")
                        .foregroundColor(.white)
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(mem.isScanning ? Color.gray : accent)
                        .clipShape(Circle())
                }
                .disabled(mem.isScanning || searchValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if mem.scanCount > 0 {
                HStack {
                    Text("找到 \(mem.scanCount) 个地址")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(accent)

                    Spacer()

                    Button("缩小搜索") {
                        performNarrowSearch()
                    }
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .disabled(mem.scanResults.count <= 1)

                    Button("重新扫描") {
                        mem.scanResults = []
                        mem.scanCount = 0
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding()
        .background(Color(.systemBackground))
    }

    // MARK: - 结果列表

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("扫描结果")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                if mem.scanResults.count > resultLimit {
                    Text("显示前 \(resultLimit) 条")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            let displayResults = Array(mem.scanResults.prefix(resultLimit))

            if displayResults.isEmpty {
                Text(mem.isScanning ? "扫描中..." : "输入值后点击搜索")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(displayResults) { result in
                    resultRow(result)
                }
            }
        }
    }

    private func resultRow(_ result: ScanResult) -> some View {
        HStack(spacing: 8) {
            // 地址
            Text("0x\(String(result.address, radix: 16))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            // 当前值
            Text(result.currentValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            Spacer()

            // 选中状态
            if selectedAddress == result.address {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(accent)
                    .font(.caption)
            }

            // 选中按钮
            Button {
                selectedAddress = result.address
                writeValue = result.currentValue
            } label: {
                Text("选中")
                    .font(.caption2)
                    .foregroundColor(selectedAddress == result.address ? .white : accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(selectedAddress == result.address ? accent : Color.clear)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            selectedAddress == result.address
                ? accent.opacity(0.08) : Color.white
        )
        .cornerRadius(6)
    }

    // MARK: - 写入区

    private var writeSection: some View {
        Group {
            if let addr = selectedAddress {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("写入地址")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("0x\(String(addr, radix: 16))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)

                        Button {
                            // 复制地址
                            let pasteboard = UIPasteboard.general
                            pasteboard.string = String(addr, radix: 16)
                            actionLog = "已复制地址: 0x\(String(addr, radix: 16))"
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Text("新值")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("输入新值", text: $writeValue)
                            .font(.system(size: 14, weight: .medium))
                            .textFieldStyle(.roundedBorder)
                            .flexibleWidth()

                        Button("写入") {
                            performWrite(address: addr)
                        }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(accent)
                        .cornerRadius(6)
                        .disabled(writeValue.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - 高级面板

    private var advancedView: some View {
        NavigationView {
            Form {
                Section("内存区域枚举") {
                    Button("枚举可读写区域") {
                        enumerateRegions()
                    }
                }

                Section("指针链追踪") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base 地址 (如 0x100000000)")
                        TextField("0x", text: $pointerBase)
                            .font(.system(size: 12, design: .monospaced))
                        Text("偏移链 (逗号分隔, 如 0x10,0x24,0x08)")
                        TextField("0x10,0x24,0x08", text: $pointerOffsets)
                            .font(.system(size: 12, design: .monospaced))
                        Button("追踪指针链") {
                            followPointerChain()
                        }
                        .foregroundColor(accent)
                    }
                }

                Section("代码段 Patch") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标地址 (十六进制)")
                        TextField("0x", text: $patchAddress)
                            .font(.system(size: 12, design: .monospaced))

                        Button("Return Zero") {
                            doPatchAction(action: "zero", address: patchAddress)
                        }
                        .foregroundColor(.orange)

                        Button("Return One") {
                            doPatchAction(action: "one", address: patchAddress)
                        }
                        .foregroundColor(.orange)

                        Button("NOP") {
                            doPatchAction(action: "nop", address: patchAddress)
                        }
                        .foregroundColor(.orange)
                    }
                }

                Section("修改历史") {
                    if mem.changes.isEmpty {
                        Text("暂无修改记录")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(mem.changes.prefix(20)) { change in
                            HStack {
                                Text("0x\(String(change.address, radix: 16))")
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text("\(change.oldValue) → \(change.newValue)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("高级")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showAdvanced = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func performScan() {
        let value = searchValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        dismissKeyboard()

        mem.asyncScan(selectedType, value: value) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let addrs):
                    actionLog = "扫描完成：\(selectedType.displayName) 搜索值='\(value)'，找到 \(addrs.count) 个地址"
                case .failure(let error):
                    errorMessage = "扫描失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func performNarrowSearch() {
        let value = searchValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        dismissKeyboard()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let count = try mem.narrowSearch(newValue: value)
                DispatchQueue.main.async {
                    actionLog = "缩小搜索完成：='\(value)'，剩余 \(count) 个地址"
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "缩小搜索失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func performWrite(address: UInt64) {
        let value = writeValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        dismissKeyboard()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try mem.writeValue(address: address, value: value)
                DispatchQueue.main.async {
                    actionLog = "写入成功：0x\(String(address, radix: 16)) = \(value)"
                    errorMessage = nil
                    // 刷新选中地址的显示值
                    if let newValue = mem.readValueAt(address, type: mem.scanType) {
                        mem.scanResults = mem.scanResults.map { r in
                            r.address == address ? ScanResult(address: r.address, currentValue: newValue) : r
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "写入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func enumerateRegions() {
        let regions = mem.enumerateRegions()
        var lines = ["枚举到 \(regions.count) 个可读写区域:", ""]
        for (i, region) in regions.prefix(30).enumerated() {
            lines.append("\(i+1). 0x\(String(region.address, radix: 16)) — 0x\(String(region.address + region.size, radix: 16))  大小: \(region.size) bytes")
        }
        if regions.count > 30 {
            lines.append("... 还有 \(regions.count - 30) 个区域")
        }
        actionLog = lines.joined(separator: "\n")
    }

    private func followPointerChain() {
        let baseStr = pointerBase.trimmingCharacters(in: .whitespaces)
        guard let base = parseHexString(baseStr) else {
            errorMessage = "无效的 base 地址"
            return
        }

        let offsetsStr = pointerOffsets.trimmingCharacters(in: .whitespaces)
        let offsets = offsetsStr.split(separator: ",").compactMap { parseHexString(String($0)) }
        guard !offsets.isEmpty else {
            errorMessage = "无效的偏移链"
            return
        }

        do {
            let result = try mem.followPointer(base: base, offsets: offsets)
            actionLog = "指针链追踪结果: 0x\(String(result, radix: 16))"
            selectedAddress = result
        } catch {
            errorMessage = "指针链追踪失败：\(error.localizedDescription)"
        }
    }

    private func doPatchAction(action: String, address: String) {
        guard let addr = parseHexString(address.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "无效的十六进制地址"
            return
        }

        do {
            switch action {
            case "zero":
                try mem.patchReturnZero(address: addr)
                actionLog = "Patch return 0 成功: 0x\(String(addr, radix: 16))"
            case "one":
                try mem.patchReturnOne(address: addr)
                actionLog = "Patch return 1 成功: 0x\(String(addr, radix: 16))"
            case "nop":
                try mem.patchNOP(address: addr)
                actionLog = "Patch NOP 成功: 0x\(String(addr, radix: 16))"
            default: break
            }
        } catch {
            errorMessage = "Patch 失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func parseHexString(_ input: String) -> UInt64? {
        let cleaned = input.replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
            .trimmingCharacters(in: .whitespaces)
        return UInt64(cleaned, radix: 16)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}

// MARK: - Preview
#if DEBUG
struct MemoryView_Preview: PreviewProvider {
    static var previews: some View {
        MemoryView()
    }
}
#endif

// MARK: - 通用 View 扩展

extension View {
    /// 占满父视图可用宽度
    func flexibleWidth() -> some View {
        frame(maxWidth: .infinity)
    }
}