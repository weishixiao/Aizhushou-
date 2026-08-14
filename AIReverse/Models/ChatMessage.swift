import Foundation

/// 一次工具调用的信息（assistant 消息携带）
struct ToolCall: Equatable {
    let id: String
    let name: String
    let arguments: [String: Any]

    static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
        case system
        case tool
    }

    let id = UUID()
    var role: Role
    var content: String
    var date = Date()
    /// tool 消息回传时关联的工具调用 ID
    var toolCallID: String?
    /// 工具名称（tool 消息使用）
    var name: String?
    /// assistant 消息携带的工具调用列表
    var assistantToolCalls: [ToolCall]?

    init(role: Role, content: String, toolCallID: String? = nil, name: String? = nil, assistantToolCalls: [ToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.name = name
        self.assistantToolCalls = assistantToolCalls
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.toolCallID == rhs.toolCallID
            && lhs.name == rhs.name
            && lhs.assistantToolCalls == rhs.assistantToolCalls
    }
}
