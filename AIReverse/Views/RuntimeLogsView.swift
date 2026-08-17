import SwiftUI
import UIKit

/// 设置页「运行日志」：查看、复制、清空运行时日志
struct RuntimeLogsView: View {
    @ObservedObject private var logger = RuntimeLogger.shared
    @State private var showClearConfirm = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green.opacity(0.14))
                            .frame(width: 38, height: 38)
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.green)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("运行日志")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text("记录应用启动、模型请求、注入与 RootService 运行情况，保存于沙盒 Documents/Logs/runtime.log")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)

                HStack {
                    Text("当前共 \(logger.entries.count) 条")
                    Spacer()
                    if let url = logger.logFileURL {
                        Text(url.path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section("日志内容") {
                if logger.entries.isEmpty {
                    Text("暂无日志记录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(logger.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(entry.level.rawValue)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(levelColor(entry.level))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(levelColor(entry.level).opacity(0.15))
                                    .cornerRadius(4)
                                Text(entry.source)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(formattedDate(entry.date))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.message)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    copyToPasteboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(logger.entries.isEmpty)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(logger.entries.isEmpty)
            }
        }
        .confirmationDialog("确定清空全部运行日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                logger.clear()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func levelColor(_ level: RuntimeLogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func copyToPasteboard() {
        let text = logger.exportText
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }
}
