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
                    Spacer()
                    ProgressView("加载应用列表…")
                        .tint(.green)
                    Spacer()
                } else if apps.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("未找到用户应用")
                            .font(.headline)
                        Text("当前设备可能没有安装用户应用，或沙盒受限")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else {
                    List {
                        ForEach(filteredApps) { app in
                            appRow(app)
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "搜索应用…")
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

    private func appRow(_ app: InstalledApp) -> some View {
        Button {
            onSelect(app)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                // 应用图标
                Group {
                    if let data = app.iconData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.green)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Color(white: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
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
