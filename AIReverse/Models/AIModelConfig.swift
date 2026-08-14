import Foundation

/// 模型 API 协议类型
enum ModelAPIType: String, Codable, CaseIterable, Hashable {
    /// OpenAI 兼容（/v1/chat/completions）
    case openAI
    /// Anthropic Claude（/v1/messages）
    case anthropic
}

struct AIModelConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var baseURL: String
    var apiKey: String
    var modelID: String
    var maxTokens: Int = 4096
    var apiType: ModelAPIType = .openAI

    var isFilled: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, modelID, maxTokens, apiType
    }

    init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String, modelID: String, maxTokens: Int = 4096, apiType: ModelAPIType = .openAI) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.maxTokens = maxTokens
        self.apiType = apiType
    }

    /// 兼容旧版本存档（无 apiType 字段时默认 openAI）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelID = try c.decode(String.self, forKey: .modelID)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 4096
        apiType = try c.decodeIfPresent(ModelAPIType.self, forKey: .apiType) ?? .openAI
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(modelID, forKey: .modelID)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(apiType, forKey: .apiType)
    }
}

final class ModelStore: ObservableObject {
    @Published var models: [AIModelConfig] = []
    @Published var selectedID: UUID?

    private let storageKey = "ai_models_v1"
    private let selectedKey = "ai_selected_model_v1"

    init() {
        load()
    }

    var selectedModel: AIModelConfig? {
        guard let id = selectedID else { return models.first }
        return models.first { $0.id == id } ?? models.first
    }

    func select(_ id: UUID) {
        selectedID = id
        save()
    }

    func add(_ model: AIModelConfig) {
        models.append(model)
        if selectedID == nil {
            selectedID = model.id
        }
        save()
    }

    func update(_ model: AIModelConfig) {
        if let idx = models.firstIndex(where: { $0.id == model.id }) {
            models[idx] = model
            save()
        }
    }

    func remove(_ model: AIModelConfig) {
        models.removeAll { $0.id == model.id }
        if selectedID == model.id {
            selectedID = models.first?.id
        }
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AIModelConfig].self, from: data) {
            models = decoded
        }
        if let idData = UserDefaults.standard.data(forKey: selectedKey),
           let id = try? JSONDecoder().decode(UUID.self, from: idData) {
            selectedID = id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        if let id = selectedID, let idData = try? JSONEncoder().encode(id) {
            UserDefaults.standard.set(idData, forKey: selectedKey)
        }
    }
}
