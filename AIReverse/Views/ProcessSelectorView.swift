import SwiftUI

// MARK: - 进程选择器视图（步骤 1）
struct ProcessSelectorView: View {
    let onSelect: (ProcessInfo) -> Void

    @State private var processes: [ProcessInfo] = []
    @State private var searchText = ""
    @State private var showSystem = false
    @State private var isLoading = true
    @State private var selectedProcess: ProcessInfo?
    @State private var showAlert = false
    @State private var alertMessage = ""

    private var filteredProcesses: [ProcessInfo] {
        let filtered = processes.filter { p in
            let matchesSearch = searchText.isEmpty ||
                p.name.lowercased().contains(searchText.lowercased()) ||
                p.path.lowercased().contains(searchText.lowercased()) ||
                String(p.pid).contains(searchText)
            let matchesSystem = showSystem || !p.isSystem
            return matchesSearch && matchesSystem
        }
        return filtered
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 搜索栏
                searchSection

                // 筛选器
                filterSection

                // 加载指示器
                if isLoading {
                    LoadingIndicator(text: "正在枚举所有进程…")
                } else if filteredProcesses.isEmpty {
                    EmptyState(text: showSystem ? "未找到系统进程" : "未找到用户进程")
                } else {
                    processList
                }
            }
            .navigationTitle("选择目标进程")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadProcesses() }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("提示"), message: Text(alertMessage), dismissButton: .default(Text("确定")))
            }
        }
    }

    // MARK: - 搜索栏

    private var searchSection: some View {
        VStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索进程（名称/PID/路径）", text: $searchText)
                    .font(.body)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 筛选器

    private var filterSection: some View {
        HStack {
            Button {
                withAnimation { showSystem.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSystem ? "checkmark.shield.fill" : "shield")
                        .font(.caption)
                    Text(showSystem ? "显示全部进程" : "仅用户进程")
                        .font(.caption)
                }
                .foregroundColor(showSystem ? accentColor : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(showSystem ? accentColor.opacity(0.12) : Color(.systemGray6))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(filteredProcesses.count) 个进程")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - 进程列表

    private var processList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filteredProcesses) { process in
                    ProcessRowView(process: process, isSelected: selectedProcess?.pid == process.pid) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedProcess = process
                        }
                    }
                    .onTapGesture {
                        guard process.readable else {
                            alertMessage = "无法附加到该进程（权限不足或进程受保护）"
                            showAlert = true
                            return
                        }
                        onSelect(process)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 数据加载

    private func loadProcesses() {
        isLoading = true
        Task {
            let procs = ProcessInspector.shared.listAllProcesses()
            await MainActor.run {
                self.processes = procs
                self.isLoading = false
            }
        }
    }
}

// MARK: - 辅助视图

private struct ProcessRowView: View {
    let process: ProcessInfo
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 图标
                ZStack {
                    Circle()
                        .fill(isSelected ? accentColor : Color(.systemGray5))
                        .frame(width: 32, height: 32)
                    Image(systemName: appIconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .white : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(process.name)
                            .font(.body)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if process.isSystem {
                            Text("系统")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .background(Color.orange.opacity(0.7))
                                .cornerRadius(3)
                        }

                        if !process.readable {
                            Text("受保护")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .background(Color.red.opacity(0.7))
                                .cornerRadius(3)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("PID: \(process.pid)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(process.path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(isSelected ? accentColor : .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? accentColor.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
    }

    private var appIconName: String {
        if process.isSystem { return "gearshape" }
        if process.name == "SpringBoard" { return "house.fill" }
        if process.name.contains("WeChat") || process.name.contains("微信") { return "bubble.fill" }
        if process.name.contains("Alipay") || process.name.contains("支付宝") { return "yensign.circle.fill" }
        return "square.fill"
    }
}

private struct LoadingIndicator: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.5)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 60)
    }
}

private struct EmptyState: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(text)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 60)
    }
}

// MARK: - 配色

extension ProcessSelectorView {
    private var accentColor: Color { Color(red: 0.31, green: 0.68, blue: 1.0) }
}

extension ProcessRowView {
    private var accentColor: Color { Color(red: 0.31, green: 0.68, blue: 1.0) }
}