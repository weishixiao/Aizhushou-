import SwiftUI

/// 已安装应用选择视图
struct InstalledAppsView: View {
    let onSelect: (InstalledApp) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var isLoading = true
    @State private var searchText = ""

    var filteredApps: [InstalledApp] {
        if searchText.isEmpty { return apps }
        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLoading {
                    loadingView
                } else if apps.isEmpty {
                    emptyView
                } else {
                    appListView
                }
            }
            .navigationTitle("选择目标应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.green)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { loadApps() }
        }
    }

    // MARK: - 加载视图

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
                .tint(.green)
            Text("加载应用列表…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - 空状态视图

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "app.dashed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("未找到用户应用")
                .font(.headline)
            Text("当前设备可能没有安装用户应用，或沙盒受限")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    // MARK: - 应用列表视图

    private var appListView: some View {
        List {
            ForEach(filteredApps) { app in
                appRow(app)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "搜索应用…")
    }

    // MARK: - 应用行

    private func appRow(_ app: InstalledApp) -> some View {
        Button {
            onSelect(app)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                // 应用图标
                appIcon(for: app)

                // 应用信息
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(app.bundleID)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if !app.version.isEmpty {
                        Text("v\(app.version)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 应用图标视图

    @ViewBuilder
    private func appIcon(for app: InstalledApp) -> some View {
        Group {
            if let data = app.iconData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // 占位图标：显示应用名称首字母
                placeholderIcon(for: app)
            }
        }
        .frame(width: 44, height: 44)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 生成占位图标（显示首字母）
    @ViewBuilder
    private func placeholderIcon(for app: InstalledApp) -> some View {
        let initial = app.displayName.first?.uppercased() ?? "?"
        ZStack {
            // 渐变背景
            LinearGradient(
                colors: [Color.green.opacity(0.6), Color.green.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initial)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    // MARK: - 加载数据

    private func loadApps() {
        Task {
            let loaded = InstalledApps.shared.userApps()
            await MainActor.run {
                apps = loaded
                isLoading = false
            }
        }
    }
}
