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
                    Text("还没有添加模型。点击右上角「+」添加。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(modelStore.models) { model in
                        modelRow(model)
                    }
                }
            } header: {
                Text("自定义模型")
            } footer: {
                Text("支持任何 OpenAI 兼容的 API（DeepSeek、OpenAI、Kimi、本地 Ollama 等）。Base URL 形如 https://api.deepseek.com 或 https://api.openai.com/v1，模型名为接口要求的模型标识。")
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("添加模型", systemImage: "plus.circle")
                }
            }

            if let model = modelStore.selectedModel {
                Section("当前选中") {
                    Text("\(model.name) — \(model.modelID)")
                }
            }

            Section("运行配置") {
                NavigationLink {
                    AIEnvironmentSettingsView()
                } label: {
                    Label("AI 环境变量", systemImage: "curlybraces.square")
                }

                NavigationLink {
                    TerminalProfileSettingsView()
                } label: {
                    Label("终端配置文件", systemImage: "terminal")
                }
            } footer: {
                Text("这些配置只保存到 App 本地，用于给 AI 执行任务时提供上下文。不会读取当前运行环境中的平台 API Key。")
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
                        Text("\(model.modelID) · \(hostFromURL(model.baseURL))")
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

struct AIEnvironmentSettingsView: View {
    @AppStorage("ai_env_api_key_name") private var apiKeyName = "PROJECT_LLM_API_KEY"
    @AppStorage("ai_env_base_url_name") private var baseURLName = "PROJECT_LLM_BASE_URL"
    @AppStorage("ai_env_model_name") private var modelName = "PROJECT_LLM_MODEL"
    @AppStorage("ai_env_extra_variables") private var extraVariables = ""

    var body: some View {
        Form {
            Section("变量名") {
                TextField("API Key 变量名", text: $apiKeyName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Base URL 变量名", text: $baseURLName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("模型变量名", text: $modelName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("只配置项目内使用的变量名，由你在 App 内主动填写或引用。")
            }

            Section("额外环境变量") {
                TextEditor(text: $extraVariables)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .autocorrectionDisabled()
            } footer: {
                Text("每行一个变量，例如 PROJECT_ENV=development。请勿粘贴不需要保存的敏感信息。")
            }
        }
        .navigationTitle("AI 环境变量")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TerminalProfileSettingsView: View {
    @AppStorage("terminal_shell_path") private var shellPath = "/bin/zsh"
    @AppStorage("terminal_working_directory") private var workingDirectory = ""
    @AppStorage("terminal_profile_content") private var profileContent = ""

    var body: some View {
        Form {
            Section("基础配置") {
                TextField("Shell 路径", text: $shellPath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("工作目录", text: $workingDirectory)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("工作目录留空时使用当前仓库工作区。")
            }

            Section("初始化脚本") {
                TextEditor(text: $profileContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .autocorrectionDisabled()
            } footer: {
                Text("用于记录终端初始化命令和环境说明，AI 可将其作为执行任务前的上下文。")
            }
        }
        .navigationTitle("终端配置文件")
        .navigationBarTitleDisplayMode(.inline)
    }
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
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var showTestAlert = false

    private let client = LLMClient()

    var body: some View {
        NavigationView {
            Form {
                Section("名称") {
                    TextField("例如：DeepSeek", text: $name)
                }
                Section("接口地址") {
                    TextField("https://api.deepseek.com", text: $baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
                Section("API Key") {
                    SecureField("sk-...（可选，本地服务可留空）", text: $apiKey)
                }
                Section("模型名") {
                    TextField("deepseek-chat", text: $modelID)
                        .autocorrectionDisabled()
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
                            modelID: modelID
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
            modelID: modelID
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
}
