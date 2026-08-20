import Foundation
import UIKit

// MARK: - 修改类型
enum ModType: String, Codable {
    case memory = "memory"
    case file = "file"
}

// MARK: - 修改记录
struct Modification: Identifiable, Codable, Equatable {
    let id = UUID()
    let type: ModType
    let description: String
    let oldValue: String
    let newValue: String
    let timestamp: Date
    var canUndo: Bool

    init(type: ModType, description: String, oldValue: String, newValue: String, canUndo: Bool = true) {
        self.type = type
        self.description = description
        self.oldValue = oldValue
        self.newValue = newValue
        self.timestamp = Date()
        self.canUndo = canUndo
    }

    static func == (lhs: Modification, rhs: Modification) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 修改跟踪器
final class ModificationTracker: ObservableObject {
    static let shared = ModificationTracker()

    @Published private(set) var modifications: [Modification] = []
    @Published var undoInProgress = false

    private let maxModifications = 500
    private let lock = NSLock()
    private let storageKey = "ai_reverse_modifications"
    private let dateFormatter: DateFormatter

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter = formatter
        load()
    }

    // MARK: - 公开方法

    func addModification(modification: Modification) {
        lock.lock()
        var copy = modifications
        copy.append(modification)
        if copy.count > maxModifications {
            copy.removeFirst(copy.count - maxModifications)
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.modifications = copy
            self.save()
        }
    }

    func addMemoryModification(address: UInt64, oldValue: String, newValue: String) {
        let desc = "内存地址 0x\(String(address, radix: 16).uppercased())"
        let mod = Modification(type: .memory, description: desc, oldValue: oldValue, newValue: newValue)
        addModification(modification: mod)
    }

    func addFileModification(path: String, oldValue: String, newValue: String) {
        let mod = Modification(type: .file, description: path, oldValue: oldValue, newValue: newValue)
        addModification(modification: mod)
    }

    func undoLast() -> Modification? {
        guard !modifications.isEmpty, modifications.last!.canUndo else { return nil }
        let mod = modifications.last!
        lock.lock()
        modifications.removeLast()
        lock.unlock()
        DispatchQueue.main.async { self.modifications = self.modifications }
        save()
        return mod
    }

    func undoAt(index: Int) -> Modification? {
        guard index >= 0, index < modifications.count, modifications[index].canUndo else { return nil }
        let mod = modifications[index]
        lock.lock()
        modifications.remove(at: index)
        lock.unlock()
        DispatchQueue.main.async { self.modifications = self.modifications }
        save()
        return mod
    }

    func clear() {
        lock.lock()
        modifications.removeAll()
        lock.unlock()
        DispatchQueue.main.async { self.modifications = [] }
        save()
    }

    var memoryModifications: [Modification] {
        modifications.filter { $0.type == .memory }
    }

    var fileModifications: [Modification] {
        modifications.filter { $0.type == .file }
    }

    // MARK: - 持久化

    private func save() {
        guard let data = try? JSONEncoder().encode(modifications) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Modification].self, from: data) else {
            return
        }
        modifications = decoded
    }
}