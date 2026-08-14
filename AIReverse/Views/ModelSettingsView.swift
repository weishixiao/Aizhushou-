import SwiftUI

/// 模型设置列表：添加 / 编辑 / 删除自定义模型
struct ModelSettingsView: View {
    @EnvironmentObject var modelStore: ModelStore
    @State private var editingModel: AIModelConfig?
    @State private var showAdd = false
    @State private var testingModel: AIModelConfig?
    @State private var testResult: String?
    @State private var showTestAlert = false
    @State private var isTesting = false

    private let client = LLMClient()

    var body: some View {
        List {
            Section {
                if modelStore.models.isEmpty {
                    Text("还没有添加模型。点击右上角「+」添加，或从下方「常用模型」一键添加。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(modelStore.models) { model in
                        modelRow(model)
                    }
                }
            } header: {
                Text("自定义模型")
            } footer: {
                Text("支持 OpenAI 兼容协议（DeepSeek、OpenAI、Kimi、Ollama 等）与 Anthropic Claude 官方 API。Base URL 形如 https://api.deepseek.com 或 https://api.anthropic.com，模型名为接口要求的模型标识。")
            }

            Section {
                Button {
                    addAllPresets()
                } label: {
                    Label("添加全部常用模型", systemImage: "tray.and.arrow.down.fill")
                }

                ForEach(ModelPreset.all) { preset in
                    Button {
                        addPreset(preset)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 18))
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .foregroundColor(.primary)
                                Text("\(preset.apiTypeLabel) · \(preset.baseURL)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("常用模型（一键添加）")
            } footer: {
                Text("点击后自动填入默认接口地址与模型名，保存前请填写自己的 API Key。")
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("自定义添加", systemImage: "plus.circle")
                }
            }

            if let model = modelStore.selectedModel {
                Section("当前选中") {
                    Text("\(model.name) — \(model.modelID)")
                }
            }
        }
        .navigationTitle("模型设置")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            ModelEditView(model: nil) { newModel in
                modelStore.add(newModel)
            }
        }
        .sheet(item: $editingModel) { model in
            ModelEditView(model: model) { updated in
                modelStore.update(updated)
            }
        }
        .alert(isPresented: $showTestAlert) {
            Alert(
                title: Text(testResult?.hasPrefix("连接成功") == true ? "测试成功" : "测试结果"),
                message: Text(testResult ?? ""),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func addPreset(_ preset: ModelPreset) {
        guard !modelStore.models.contains(where: { existing in
            existing.apiType == preset.apiType
                && existing.baseURL == preset.baseURL
                && existing.modelID == preset.modelID
        }) else { return }

        let config = AIModelConfig(
            name: preset.name,
            baseURL: preset.baseURL,
            apiKey: "",
            modelID: preset.modelID,
            apiType: preset.apiType
        )
        modelStore.add(config)
    }

    private func addAllPresets() {
        let existing = Set(modelStore.models.map { "\($0.apiType.rawValue)|\($0.baseURL)|\($0.modelID)" })
        for preset in ModelPreset.all {
            let key = "\(preset.apiType.rawValue)|\(preset.baseURL)|\(preset.modelID)"
            guard !existing.contains(key) else { continue }
            addPreset(preset)
        }
    }

    private func testModel(_ model: AIModelConfig) {
        guard !isTesting else { return }
        guard model.isFilled else {
            testResult = "配置不完整：请填写接口地址和模型名"
            showTestAlert = true
            return
        }
        isTesting = true
        testingModel = model
        testResult = nil
        Task {
            let messages = [
                ChatMessage(role: .system, content: "你是连接测试助手，收到消息后请只回复两个字：正常"),
                ChatMessage(role: .user, content: "测试连接")
            ]
            do {
                let reply = try await client.chat(model: model, messages: messages)
                let preview = String(reply.prefix(60))
                await MainActor.run {
                    testResult = "连接成功，模型可用\n\n回复：\(preview)"
                    isTesting = false
                    testingModel = nil
                    showTestAlert = true
                }
            } catch {
                await MainActor.run {
                    testResult = "连接失败：\n\(error.localizedDescription)"
                    isTesting = false
                    testingModel = nil
                    showTestAlert = true
                }
            }
        }
    }

    private func modelRow(_ model: AIModelConfig) -> some View {
        HStack {
            Button {
                modelStore.select(model.id)
            } label: {
                HStack {
                    Image(systemName: modelStore.selectedModel?.id == model.id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(modelStore.selectedModel?.id == model.id ? .blue : .secondary)
                    VStack(alignment: .leading) {
                        Text(model.name)
                            .font(.body)
                        Text("\(model.modelID) · \(model.apiType == .anthropic ? "Claude API" : "OpenAI 兼容") · \(hostFromURL(model.baseURL))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button("测试连接") { testModel(model) }
                Button("编辑") { editingModel = model }
                Button("删除", role: .destructive) { modelStore.remove(model) }
            } label: {
                if isTesting && testingModel?.id == model.id {
                    ProgressView()
                        .padding(.horizontal, 4)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func hostFromURL(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        return host
    }
}

/// 常用模型预设（一键添加）
struct ModelPreset: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let baseURL: String
    let modelID: String
    let apiType: ModelAPIType

    var apiTypeLabel: String {
        apiType == .anthropic ? "Claude API" : "OpenAI 兼容"
    }

    static let all: [ModelPreset] = [
        ModelPreset(
            name: "Claude Sonnet 4",
            symbol: "sparkles",
            baseURL: "https://api.anthropic.com",
            modelID: "claude-sonnet-4-20250514",
            apiType: .anthropic
        ),
        ModelPreset(
            name: "Claude Opus 4",
            symbol: "sparkles",
            baseURL: "https://api.anthropic.com",
            modelID: "claude-opus-4-20250514",
            apiType: .anthropic
        ),
        ModelPreset(
            name: "Claude Haiku 3.5",
            symbol: "bolt.fill",
            baseURL: "https://api.anthropic.com",
            modelID: "claude-3-5-haiku-20241022",
            apiType: .anthropic
        ),
        ModelPreset(
            name: "OpenAI GPT-4o",
            symbol: "circle.hexagongrid.fill",
            baseURL: "https://api.openai.com/v1",
            modelID: "gpt-4o",
            apiType: .openAI
        ),
        ModelPreset(
            name: "OpenAI GPT-4o mini",
            symbol: "circle.hexagongrid.fill",
            baseURL: "https://api.openai.com/v1",
            modelID: "gpt-4o-mini",
            apiType: .openAI
        ),
        ModelPreset(
            name: "DeepSeek Chat",
            symbol: "waveform.path.ecg",
            baseURL: "https://api.deepseek.com",
            modelID: "deepseek-chat",
            apiType: .openAI
        ),
        ModelPreset(
            name: "DeepSeek Reasoner",
            symbol: "brain.head.profile",
            baseURL: "https://api.deepseek.com",
            modelID: "deepseek-reasoner",
            apiType: .openAI
        ),
        ModelPreset(
            name: "Kimi (Moonshot)",
            symbol: "moon.stars.fill",
            baseURL: "https://api.moonshot.cn/v1",
            modelID: "moonshot-v1-8k",
            apiType: .openAI
        ),
        ModelPreset(
            name: "通义千问 Qwen",
            symbol: "cloud.fill",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            modelID: "qwen-plus",
            apiType: .openAI
        ),
        ModelPreset(
            name: "智谱 GLM",
            symbol: "brain",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            modelID: "glm-4-flash",
            apiType: .openAI
        ),
        ModelPreset(
            name: "本地 Ollama",
            symbol: "desktopcomputer",
            baseURL: "http://127.0.0.1:11434/v1",
            modelID: "llama3.1",
            apiType: .openAI
        )
    ]
}

/// 模型编辑表单
struct ModelEditView: View {
    let model: AIModelConfig?
    let onSave: (AIModelConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var modelID: String = ""
    @State private var apiType: ModelAPIType = .openAI
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var showTestAlert = false
    @State private var isLoadingModels = false
    @State private var availableModels: [LLMModelInfo] = []
    @State private var modelLoadMessage: String?

    private let client = LLMClient()

    var body: some View {
        NavigationView {
            Form {
                Section("名称") {
                    TextField("例如：DeepSeek", text: $name)
                }
                Section("API 类型") {
                    Picker("API 类型", selection: $apiType) {
                        Text("OpenAI 兼容").tag(ModelAPIType.openAI)
                        Text("Anthropic Claude").tag(ModelAPIType.anthropic)
                    }
                    .pickerStyle(.segmented)
                }
                Section("接口地址") {
                    TextField(apiType == .anthropic ? "https://api.anthropic.com" : "https://api.deepseek.com", text: $baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
                Section("API Key") {
                    SecureField(apiType == .anthropic ? "sk-ant-...（必填）" : "sk-...（可选，本地服务可留空）", text: $apiKey)
                }
                Section("模型名") {
                    TextField(apiType == .anthropic ? "claude-sonnet-4-20250514" : "deepseek-chat", text: $modelID)
                        .autocorrectionDisabled()
                }
                Section {
                    Button {
                        loadAvailableModels()
                    } label: {
                        if isLoadingModels {
                            HStack {
                                ProgressView()
                                Text("识别中...")
                            }
                        } else {
                            Label("自动识别模型", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isLoadingModels || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let modelLoadMessage {
                        Text(modelLoadMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ForEach(availableModels) { item in
                        Button {
                            modelID = item.id
                            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                name = preferredModelName(item)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                        .foregroundColor(.primary)
                                    Text(modelMetaText(item))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if modelID == item.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("模型识别")
                } footer: {
                    if apiType == .anthropic {
                        Text("Claude 官方接口会列出可用模型，选择后自动填入模型名。")
                    } else {
                        Text("使用 OpenAI 兼容的 GET /v1/models 读取中转站可用模型，选择后自动填入模型名。")
                    }
                }
                Section {
                    Button {
                        testCurrentConfig()
                    } label: {
                        if isTesting {
                            HStack {
                                ProgressView()
                                Text("测试中...")
                            }
                        } else {
                            Label("测试模型是否可用", systemImage: "bolt.circle")
                        }
                    }
                    .disabled(isTesting || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                              || modelID.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("保存前可先测试连接。测试会发送一条消息，返回「正常」即表示配置可用。")
                }
            }
            .navigationTitle(model == nil ? "添加模型" : "编辑模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let cfg = AIModelConfig(
                            id: model?.id ?? UUID(),
                            name: name,
                            baseURL: baseURL,
                            apiKey: apiKey,
                            modelID: modelID,
                            apiType: apiType
                        )
                        onSave(cfg)
                        dismiss()
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                              || modelID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let m = model {
                    name = m.name
                    baseURL = m.baseURL
                    apiKey = m.apiKey
                    modelID = m.modelID
                    apiType = m.apiType
                }
            }
            .alert(isPresented: $showTestAlert) {
                Alert(
                    title: Text(testResult?.hasPrefix("连接成功") == true ? "测试成功" : "测试结果"),
                    message: Text(testResult ?? ""),
                    dismissButton: .default(Text("好"))
                )
            }
        }
    }

    private func testCurrentConfig() {
        guard !isTesting else { return }
        let cfg = AIModelConfig(
            id: model?.id ?? UUID(),
            name: name,
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: modelID,
            apiType: apiType
        )
        isTesting = true
        Task {
            let messages = [
                ChatMessage(role: .system, content: "你是连接测试助手，收到消息后请只回复两个字：正常"),
                ChatMessage(role: .user, content: "测试连接")
            ]
            do {
                let reply = try await client.chat(model: cfg, messages: messages)
                let preview = String(reply.prefix(60))
                await MainActor.run {
                    testResult = "连接成功，模型可用\n\n回复：\(preview)"
                    isTesting = false
                    showTestAlert = true
                }
            } catch {
                await MainActor.run {
                    testResult = "连接失败：\n\(error.localizedDescription)"
                    isTesting = false
                    showTestAlert = true
                }
            }
        }
    }

    private func loadAvailableModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelLoadMessage = nil
        availableModels = []
        Task {
            do {
                let models = try await client.listModels(baseURL: baseURL, apiKey: apiKey, apiType: apiType)
                await MainActor.run {
                    availableModels = models
                    modelLoadMessage = models.isEmpty ? "未识别到可用模型" : "已识别 \(models.count) 个模型"
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    modelLoadMessage = "识别失败：\(error.localizedDescription)"
                    isLoadingModels = false
                }
            }
        }
    }

    private func modelMetaText(_ item: LLMModelInfo) -> String {
        var parts: [String] = []
        if let ownedBy = item.ownedBy, !ownedBy.isEmpty { parts.append(ownedBy) }
        if let status = item.status, !status.isEmpty { parts.append(status) }
        return parts.isEmpty ? "可用模型" : parts.joined(separator: " · ")
    }

    private func preferredModelName(_ item: LLMModelInfo) -> String {
        if let name = item.name, !name.isEmpty { return name }
        return item.id
    }
}
