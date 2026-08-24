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
    /// Stable app-owned turn identity. Older records omit this field; their
    /// turn identity is derived from the user-message ID so they remain
    /// editable without a destructive migration.
    let turnID: String?
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
        turnID: String? = nil,
        role: Role,
        text: String,
        contentParts: [ContentPart]? = nil,
        status: TimelineItemStatus = .completed,
        createdAt: Date = .now,
        detail: String? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.role = role
        self.text = text
        self.contentParts = contentParts ?? [.text(text)]
        self.status = status
        self.createdAt = createdAt
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case turnID
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
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
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
        try container.encodeIfPresent(turnID, forKey: .turnID)
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
           contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
            body: contentText,
            status: status,
            timestamp: createdAt,
            detail: detail,
            attachments: timelineAttachments
        )
    }

    /// The stored `text` field is retained for compatibility with legacy
    /// records and compact previews. User turns with images, however, carry
    /// authoritative ordered content parts; an image-only turn may therefore
    /// have a presentation placeholder in `text` while its actual body is
    /// empty. Derive transcript copy from text parts so a literal string such
    /// as `[Image attachment]` remains editable when it was genuinely sent.
    var contentText: String {
        let textParts = contentParts.compactMap { part -> String? in
            guard case let .text(value) = part else { return nil }
            return value
        }
        if !textParts.isEmpty {
            return textParts.joined(separator: "\n")
        }
        return contentParts.isEmpty ? text : ""
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
        let turns = runtimeTurns
        return RuntimeConversation(
            thread: runtimeThread(kind: kind),
            items: turns.flatMap(\.items),
            turns: turns
        )
    }

    /// OpenAI-compatible endpoints do not own thread history, but Onyx does.
    /// Each submitted user/assistant pair therefore has an authoritative local
    /// turn boundary. Legacy messages are grouped deterministically from the
    /// user-message ID so retry/edit remains available after an upgrade.
    var runtimeTurns: [RuntimeConversationTurn] {
        turnGroups.map { group in
            let status: RuntimeConversationTurnStatus
            if group.messages.contains(where: { $0.status == .running }) {
                status = .inProgress
            } else if group.messages.contains(where: { $0.status == .failed }) {
                status = .failed
            } else {
                status = .completed
            }
            return RuntimeConversationTurn(
                id: group.id,
                items: group.messages.map(\.timelineItem),
                status: status,
                itemDetail: .full,
                startedAt: group.messages.first?.createdAt,
                completedAt: status == .inProgress ? nil : group.messages.last?.createdAt,
                durationMilliseconds: nil
            )
        }
    }

    /// Lightweight authoritative grouping shared by projection and store
    /// validation. A legacy nil turn ID is resolved from its user message, so
    /// mixed old/new records cannot create two disjoint groups with one ID.
    var turnGroups: [(id: String, messages: [OpenAICompatibleStoredMessage])] {
        var groups: [(id: String, messages: [OpenAICompatibleStoredMessage])] = []
        var currentTurnID: String?

        for message in messages {
            let resolvedTurnID: String
            if let explicit = message.turnID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty
            {
                resolvedTurnID = explicit
            } else if message.role == .user {
                resolvedTurnID = Self.legacyTurnID(for: message.id)
            } else if let currentTurnID {
                resolvedTurnID = currentTurnID
            } else {
                resolvedTurnID = Self.legacyTurnID(for: message.id)
            }

            if currentTurnID != resolvedTurnID {
                groups.append((id: resolvedTurnID, messages: []))
                currentTurnID = resolvedTurnID
            }
            groups[groups.count - 1].messages.append(message)
        }
        return groups
    }

    func messageIndex(startingTurnID turnID: String) -> Int? {
        runtimeTurns.first(where: { $0.id == turnID }).flatMap { turn in
            let itemIDs = Set(turn.items.map(\.id))
            return messages.firstIndex(where: { itemIDs.contains($0.id) })
        }
    }

    private static func legacyTurnID(for messageID: String) -> String {
        "turn:\(messageID)"
    }

    private static func preview(from messages: [OpenAICompatibleStoredMessage]) -> String {
        for message in messages.reversed() {
            let text = message.contentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let collapsed = text
                    .split(whereSeparator: \Character.isWhitespace)
                    .joined(separator: " ")
                guard collapsed.count > 160 else { return collapsed }
                return String(collapsed.prefix(157)) + "…"
            }
            if message.contentParts.contains(where: {
                if case .imageURL = $0 { true } else { false }
            }) {
                return "Image attachment"
            }
        }
        return "No messages yet"
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
