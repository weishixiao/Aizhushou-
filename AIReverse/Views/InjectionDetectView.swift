//
//  InjectionDetectView.swift
//  AIReverse
//
//  注入检测/绕过模块的 UI 入口：
//  - 一键执行 4 种原理的全面检测（dyld_image_count / dyld callback / task_info / 地址范围）
//  - 展示当前进程全部已加载 dylib（含地址、共享缓存、可疑标记）
//  - 注册 dyld 回调，实时监控运行时新加载的 dylib
//

import SwiftUI
import Combine

// MARK: - 检测状态管理

/// 注入检测模块的状态管理（单例，供视图读取与驱动）
final class InjectionDetectStore: ObservableObject {
    static let shared = InjectionDetectStore()

    /// 4 种原理的检测结果
    @Published var results: [DetectionResult] = []
    /// 当前进程所有已加载的 dylib
    @Published var loadedDylibs: [DylibInfo] = []
    /// 运行时监控日志
    @Published var monitorLog: [String] = []
    /// 正在执行全面检测
    @Published var isDetecting = false
    /// 是否已注册 dyld 回调
    @Published var isMonitoring = false

    private let checker = InjectionDetectionChecker()

    private init() {
        // 回调可能来自任意线程（dyld 在加载镜像时触发），统一切回主线程
        checker.onDylibLoaded = { [weak self] name, _ in
            DispatchQueue.main.async {
                self?.appendMonitor("新 dylib 加载：\(name)")
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func appendMonitor(_ msg: String) {
        let time = Self.timeFormatter.string(from: Date())
        monitorLog.insert("[\(time)] \(msg)", at: 0)
        if monitorLog.count > 50 {
            monitorLog.removeLast(monitorLog.count - 50)
        }
    }

    // MARK: - 动作

    /// 后台线程执行 4 种原理的全面检测，完成后回主线程更新
    func runFullDetection() {
        guard !isDetecting else { return }
        isDetecting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let full = self.checker.fullDetection()
            let libs = DylibHideHelper.allLoadedDylibs()
            DispatchQueue.main.async {
                self.results = full
                self.loadedDylibs = libs
                self.isDetecting = false
                let foundCount = full.filter { $0.found }.count
                RuntimeLogger.shared.info(
                    "检测",
                    "完成 4 种原理注入检测：\(foundCount) 项方法发现可疑 dylib，共加载 \(libs.count) 个镜像"
                )
            }
        }
    }

    /// 切换运行时 dylib 加载监控
    func toggleMonitoring() {
        isMonitoring.toggle()
        if isMonitoring {
            // unregisterDylibCallback() 会把 onDylibLoaded 置 nil，
            // 重新开启前必须重新挂接回调，否则注册后收不到通知
            checker.onDylibLoaded = { [weak self] name, _ in
                DispatchQueue.main.async {
                    self?.appendMonitor("新 dylib 加载：\(name)")
                }
            }
            if checker.registerDylibCallback() {
                appendMonitor("已注册 _dyld_register_func_for_add_image 回调")
            } else {
                isMonitoring = false
                appendMonitor("回调注册失败（无法获取 dyld 符号）")
            }
        } else {
            checker.unregisterDylibCallback()
            appendMonitor("已停止监控")
        }
    }

    // MARK: - 派生数据

    /// 发现可疑 dylib 的检测方法数量
    var suspiciousMethodCount: Int {
        results.filter { $0.found }.count
    }

    /// 所有方法汇总出的可疑 dylib 列表（去重）
    var allSuspiciousLibs: [String] {
        var seen = Set<String>()
        return results.flatMap { $0.suspectedLibs }.filter { seen.insert($0).inserted }
    }
}

// MARK: - 视图

/// 注入检测界面：概览 + 4 种原理结果 + 已加载 dylib 列表 + 运行时监控
struct InjectionDetectView: View {
    @ObservedObject private var store = InjectionDetectStore.shared

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)

    var body: some View {
        List {
            overviewSection
            detectionSection
            loadedSection
            monitorSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("注入检测")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    store.runFullDetection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isDetecting)
            }
        }
        .onAppear {
            // 首次进入自动检测一次
            if store.results.isEmpty && !store.isDetecting {
                store.runFullDetection()
            }
        }
    }

    // MARK: 概览

    private var overviewSection: some View {
        Section {
            VStack(spacing: 10) {
                HStack(spacing: 24) {
                    statItem(title: "检测原理", value: "\(store.results.count)/4", color: accent)
                    statItem(
                        title: "可疑发现",
                        value: "\(store.suspiciousMethodCount)",
                        color: store.suspiciousMethodCount > 0 ? .red : accent
                    )
                    statItem(title: "已加载库", value: "\(store.loadedDylibs.count)", color: .blue)
                }
                .padding(.vertical, 6)

                if store.isDetecting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在执行 4 种原理检测…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 4)
                }

                if !store.allSuspiciousLibs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("可疑 dylib")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ForEach(store.allSuspiciousLibs, id: \.self) { lib in
                            Text(lib)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.red)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } footer: {
            Text("检测目标为当前进程（AIReverse 自身）。4 种原理中 task_info 为内核级检测，不可绕过。")
        }
    }

    private func statItem(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 4 种原理检测结果

    private var detectionSection: some View {
        Section("检测原理") {
            if store.results.isEmpty {
                Text(store.isDetecting ? "检测中…" : "尚未执行检测")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.results, id: \.method) { result in
                    DetectionResultRow(result: result)
                }
            }
        }
    }

    // MARK: 已加载 dylib 列表

    private var loadedSection: some View {
        Section("已加载 dylib（\(store.loadedDylibs.count)）") {
            if store.loadedDylibs.isEmpty {
                Text(store.isDetecting ? "正在枚举…" : "暂无数据，点击右上角重新检测")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.loadedDylibs, id: \.name) { info in
                    DylibInfoRow(info: info)
                }
            }
        }
    }

    // MARK: 运行时监控

    private var monitorSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.isMonitoring },
                set: { _ in store.toggleMonitoring() }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundColor(store.isMonitoring ? accent : .secondary)
                    Text("监控新加载的 dylib")
                }
            }

            if store.monitorLog.isEmpty {
                Text(store.isMonitoring ? "等待新 dylib 加载…" : "开启后实时记录进程内新加载的动态库")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(store.monitorLog.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("运行时监控")
        } footer: {
            Text("基于 _dyld_register_func_for_add_image 回调。监控对象为当前进程，无需越狱权限。")
        }
    }
}

// MARK: - 单行组件

/// 单种检测原理的结果行
struct DetectionResultRow: View {
    let result: DetectionResult

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(result.emoji)
                Text(result.method.rawValue)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(result.found ? "发现可疑" : "未发现")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((result.found ? Color.red : accent).opacity(0.14))
                    .foregroundColor(result.found ? .red : accent)
                    .cornerRadius(5)
            }

            Text(result.details)
                .font(.caption)
                .foregroundColor(.secondary)

            if !result.suspectedLibs.isEmpty {
                ForEach(result.suspectedLibs, id: \.self) { lib in
                    Text(lib)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Text(result.method.bypassable ? "可绕过" : "不可绕过（内核级）")
                .font(.caption2)
                .foregroundColor(result.method.bypassable ? .secondary : .orange)
        }
        .padding(.vertical, 3)
    }
}

/// 单个已加载 dylib 信息行
struct DylibInfoRow: View {
    let info: DylibInfo

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(info.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .foregroundColor(info.isSuspect ? .red : .primary)
                Spacer()
                if info.isSuspect {
                    Text("可疑")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
            HStack(spacing: 8) {
                Text("0x\(String(info.address, radix: 16))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                if info.inSharedCache {
                    Text("共享缓存")
                        .font(.caption2)
                        .foregroundColor(accent)
                }
                if info.isSystem {
                    Text("系统")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
