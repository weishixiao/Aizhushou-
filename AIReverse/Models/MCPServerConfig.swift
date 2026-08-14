import Foundation

struct MCPServerConfig: Identifiable, Codable, Equatable {
    enum Transport: String, Codable, CaseIterable, Identifiable {
        case stdio
        case streamableHTTP
        case sse

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stdio: return "本地 stdio"
            case .streamableHTTP: return "Streamable HTTP"
            case .sse: return "SSE"
            }
        }
    }

    var id = UUID()
    var name: String
    var transport: Transport
    var command: String
    var args: [String]
    var env: [String: String]
    var url: String
    var headers: [String: String]
    var enabled: Bool
}

final class MCPServerStore: ObservableObject {
    @Published var servers: [MCPServerConfig] = []

    private let storageKey = "mcp_servers_v1"

    init() {
        load()
    }

    func add(_ server: MCPServerConfig) {
        servers.append(server)
        save()
    }

    func update(_ server: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        save()
    }

    func remove(_ server: MCPServerConfig) {
        servers.removeAll { $0.id == server.id }
        save()
    }

    func importServers(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let imported = try MCPServerJSONParser.parse(data: data)
        for server in imported {
            if let index = servers.firstIndex(where: { $0.name == server.name }) {
                servers[index] = server
            } else {
                servers.append(server)
            }
        }
        save()
        return imported.count
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return
        }
        servers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum MCPServerJSONParser {
    static func parse(data: Data) throws -> [MCPServerConfig] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let container = (root["mcpServers"] as? [String: Any])
            ?? (root["mcp"] as? [String: Any])
            ?? root

        return container.compactMap { name, rawValue in
            guard let item = rawValue as? [String: Any] else { return nil }
            return parseServer(name: name, item: item)
        }
    }

    private static func parseServer(name: String, item: [String: Any]) -> MCPServerConfig {
        let url = item["url"] as? String ?? ""
        let command = item["command"] as? String ?? commandArray(item["command"]).first ?? ""
        let args = (item["args"] as? [String]) ?? Array(commandArray(item["command"]).dropFirst())
        let env = stringMap(item["env"]) ?? stringMap(item["environment"]) ?? [:]
        let headers = stringMap(item["headers"]) ?? [:]
        let enabled = item["enabled"] as? Bool ?? true
        let transport = parseTransport(item: item, url: url)

        return MCPServerConfig(
            name: name,
            transport: transport,
            command: command,
            args: args,
            env: env,
            url: url,
            headers: headers,
            enabled: enabled
        )
    }

    private static func parseTransport(item: [String: Any], url: String) -> MCPServerConfig.Transport {
        let raw = ((item["transport"] ?? item["transportType"] ?? item["type"]) as? String)?.lowercased() ?? ""
        if raw.contains("sse") || url.hasSuffix("/sse") { return .sse }
        if raw.contains("http") || raw.contains("remote") || !url.isEmpty { return .streamableHTTP }
        return .stdio
    }

    private static func commandArray(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private static func stringMap(_ value: Any?) -> [String: String]? {
        guard let map = value as? [String: Any] else { return nil }
        return map.reduce(into: [:]) { result, pair in
            if let text = pair.value as? String {
                result[pair.key] = text
            }
        }
    }
}
