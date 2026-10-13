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
    enum Role: String, Codable {
        case user
        case assistant
        case system
        case tool
    }

    let id = UUID()
    var role: Role
    var content: String
    /// 用户消息携带的图片附件（JPEG），多模态模型可见
    var imageData: Data?
    var date = Date()
    /// tool 消息回传时关联的工具调用 ID
    var toolCallID: String?
    /// 工具名称（tool 消息使用）
    var name: String?
    /// assistant 消息携带的工具调用列表
    var assistantToolCalls: [ToolCall]?
    /// 本地执行进度消息，不参与模型上下文
    var isProgress: Bool

    init(role: Role, content: String, date: Date = Date(), toolCallID: String? = nil, name: String? = nil, assistantToolCalls: [ToolCall]? = nil, isProgress: Bool = false, imageData: Data? = nil) {
        self.role = role
        self.content = content
        self.date = date
        self.toolCallID = toolCallID
        self.name = name
        self.assistantToolCalls = assistantToolCalls
        self.isProgress = isProgress
        self.imageData = imageData
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.imageData == rhs.imageData
            && lhs.toolCallID == rhs.toolCallID
            && lhs.name == rhs.name
            && lhs.assistantToolCalls == rhs.assistantToolCalls
            && lhs.isProgress == rhs.isProgress
    }
}
