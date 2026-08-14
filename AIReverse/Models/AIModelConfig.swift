import Foundation

struct AIModelConfig: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var baseURL: String
    var apiKey: String
    var modelID: String
    var maxTokens: Int = 4096

    var isFilled: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
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
