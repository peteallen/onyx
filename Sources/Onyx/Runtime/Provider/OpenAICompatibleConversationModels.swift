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

    /// The ordered content that was actually sent to the provider. Local image
    /// paths are resolved to data URLs before this value is persisted, so a
    /// later app launch can reproduce both the transcript attachments and the
    /// next request without depending on a file that may have moved.
    enum ContentPart: Codable, Equatable, Sendable {
        case text(String)
        case imageURL(String)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case url
        }

        private enum Kind: String, Codable {
            case text
            case imageURL
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .text:
                self = .text(try container.decode(String.self, forKey: .text))
            case .imageURL:
                self = .imageURL(try container.decode(String.self, forKey: .url))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try container.encode(Kind.text, forKey: .type)
                try container.encode(text, forKey: .text)
            case let .imageURL(url):
                try container.encode(Kind.imageURL, forKey: .type)
                try container.encode(url, forKey: .url)
            }
        }

        init(_ chatPart: OpenAICompatibleChatMessage.ContentPart) {
            self = switch chatPart {
            case let .text(text): .text(text)
            case let .imageURL(url): .imageURL(url)
            }
        }

        var chatPart: OpenAICompatibleChatMessage.ContentPart {
            switch self {
            case let .text(text): .text(text)
            case let .imageURL(url): .imageURL(url)
            }
        }
    }

    let id: String
    let role: Role
    var text: String {
        didSet {
            // Streaming assistant messages and legacy text-only records use a
            // single text part. Keep that provider history synchronized with
            // the user-visible body as new deltas are persisted.
            if contentParts.allSatisfy({ if case .text = $0 { true } else { false } }) {
                contentParts = [.text(text)]
            }
        }
    }
    var contentParts: [ContentPart]
    var status: TimelineItemStatus
    let createdAt: Date
    var detail: String?

    init(
        id: String = UUID().uuidString.lowercased(),
        role: Role,
        text: String,
        contentParts: [ContentPart]? = nil,
        status: TimelineItemStatus = .completed,
        createdAt: Date = .now,
        detail: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.contentParts = contentParts ?? [.text(text)]
        self.status = status
        self.createdAt = createdAt
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case contentParts
        case status
        case createdAt
        case detail
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        contentParts = try container.decodeIfPresent([ContentPart].self, forKey: .contentParts)
            ?? [.text(text)]
        status = try container.decode(TimelineItemStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(contentParts, forKey: .contentParts)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    var chatMessage: OpenAICompatibleChatMessage? {
        // A legacy provider turn may contain only whitespace after an empty
        // streamed answer. Once recovery marks it failed, do not replay that
        // placeholder as an assistant history message on the next request.
        guard status != .failed
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let chatRole: OpenAICompatibleChatMessage.Role = switch role {
        case .user: .user
        case .assistant: .assistant
        case .system: .system
        }
        return OpenAICompatibleChatMessage(
            role: chatRole,
            parts: contentParts.map(\.chatPart)
        )
    }

    var timelineItem: TimelineItem {
        if role == .assistant,
           status == .failed,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty
        {
            return TimelineItem(
                id: id,
                kind: .error,
                title: "Provider response failed",
                body: detail,
                status: .failed,
                timestamp: createdAt,
                detail: nil
            )
        }
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
            detail: detail,
            attachments: timelineAttachments
        )
    }

    private var timelineAttachments: [TimelineAttachment] {
        contentParts.enumerated().compactMap { index, part in
            guard case let .imageURL(raw) = part else { return nil }
            let source: TimelineAttachmentSource
            if raw.lowercased().hasPrefix("data:image/") {
                source = .dataURL(raw)
            } else if let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                source = .remoteURL(url)
            } else {
                return nil
            }
            let attachmentID = "\(id):image:\(index)"
            return TimelineAttachment(
                id: attachmentID,
                source: source,
                accessibilityLabel: "Image attachment",
                cacheIdentity: attachmentID
            )
        }
    }
}

/// One app-owned conversation for a configured provider connection. The
/// connection ID is part of the durable identity boundary: two endpoints may
/// independently use the same model or remote completion IDs without aliasing
/// their local histories.
struct OpenAICompatibleStoredConversation: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let connectionID: ProviderConnectionID
    /// The non-secret provider-configuration scope that owns this transcript.
    /// `nil` is retained only for records written before scope isolation.
    var conversationScopeID: String?
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
        conversationScopeID: String? = nil,
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
        self.conversationScopeID = conversationScopeID
        self.title = title
        self.cwd = cwd
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.status = status
        self.messages = messages
    }

    func belongs(to scopeID: String) -> Bool {
        if conversationScopeID == scopeID { return true }
        return conversationScopeID == nil
            && scopeID == ProviderConnectionRecord.legacyConversationScopeID(for: connectionID)
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
