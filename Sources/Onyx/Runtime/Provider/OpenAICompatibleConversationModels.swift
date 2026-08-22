import Foundation

/// A provider-chat message persisted by Onyx. OpenAI-compatible chat APIs do
/// not own durable threads, so the app records the exact text that it sent and
/// received without persisting credentials, headers, or raw provider payloads.
struct OpenAICompatibleStoredMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    let id: String
    let role: Role
    var text: String
    var status: TimelineItemStatus
    let createdAt: Date
    var detail: String?

    init(
        id: String = UUID().uuidString.lowercased(),
        role: Role,
        text: String,
        status: TimelineItemStatus = .completed,
        createdAt: Date = .now,
        detail: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.detail = detail
    }

    var chatMessage: OpenAICompatibleChatMessage? {
        guard status != .failed || !text.isEmpty else { return nil }
        let chatRole: OpenAICompatibleChatMessage.Role = switch role {
        case .user: .user
        case .assistant: .assistant
        case .system: .system
        }
        return OpenAICompatibleChatMessage(role: chatRole, text: text)
    }

    var timelineItem: TimelineItem {
        let kind: TimelineItemKind = switch role {
        case .user: .userMessage
        case .assistant: .assistantMessage
        case .system: .system
        }
        return TimelineItem(
            id: id,
            kind: kind,
            title: nil,
            body: text,
            status: status,
            timestamp: createdAt,
            detail: detail
        )
    }
}

/// One app-owned conversation for a configured provider connection. The
/// connection ID is part of the durable identity boundary: two endpoints may
/// independently use the same model or remote completion IDs without aliasing
/// their local histories.
struct OpenAICompatibleStoredConversation: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let connectionID: ProviderConnectionID
    var title: String
    var cwd: String?
    var modelID: String
    let createdAt: Date
    var updatedAt: Date
    var isArchived: Bool
    var status: RuntimeThreadStatus
    var messages: [OpenAICompatibleStoredMessage]

    init(
        id: String,
        connectionID: ProviderConnectionID,
        title: String,
        cwd: String? = nil,
        modelID: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isArchived: Bool = false,
        status: RuntimeThreadStatus = .idle,
        messages: [OpenAICompatibleStoredMessage] = []
    ) {
        self.id = id
        self.connectionID = connectionID
        self.title = title
        self.cwd = cwd
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.status = status
        self.messages = messages
    }

    func runtimeThread(kind: AgentRuntimeKind) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: title,
            preview: Self.preview(from: messages),
            cwd: cwd,
            updatedAt: updatedAt,
            status: status,
            isPinned: false,
            runtime: kind,
            model: modelID,
            branch: nil
        )
    }

    func runtimeConversation(kind: AgentRuntimeKind) -> RuntimeConversation {
        RuntimeConversation(
            thread: runtimeThread(kind: kind),
            items: messages.map(\.timelineItem)
        )
    }

    private static func preview(from messages: [OpenAICompatibleStoredMessage]) -> String {
        guard let text = messages.reversed().first(where: { !$0.text.isEmpty })?.text else {
            return "No messages yet"
        }
        let collapsed = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > 160 else { return collapsed }
        return String(collapsed.prefix(157)) + "…"
    }
}

struct OpenAICompatibleConversationSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var conversations: [OpenAICompatibleStoredConversation]

    init(
        schemaVersion: Int = currentSchemaVersion,
        conversations: [OpenAICompatibleStoredConversation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.conversations = conversations
    }
}
