import Foundation

/// Stable, app-owned identity for a conversation. Provider thread IDs are
/// deliberately not used as local identity because two connections may expose
/// the same opaque value.
struct ConversationID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    init() {
        self.init(UUID().uuidString.lowercased())
    }

    var description: String { rawValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Connection-scoped provider identity for a remote conversation. The remote
/// value remains opaque: only the adapter for `connectionID` may interpret it.
struct ProviderConversationBinding: Codable, Hashable, Sendable {
    let connectionID: ProviderConnectionID
    let opaqueRemoteThreadID: String

    init(
        connectionID: ProviderConnectionID,
        opaqueRemoteThreadID: String
    ) {
        self.connectionID = connectionID
        self.opaqueRemoteThreadID = opaqueRemoteThreadID
    }
}

/// Minimal project metadata for recents and restoration. This is intentionally
/// not a security-scoped bookmark or a provider working-directory payload.
struct ConversationProject: Codable, Hashable, Sendable {
    var path: String
    var displayName: String?

    init(path: String, displayName: String? = nil) {
        self.path = path
        self.displayName = displayName
    }
}

enum ConversationContinuationKind: String, Codable, Hashable, Sendable {
    /// The configured provider connection is unchanged.
    case sameProvider
    /// The destination provider connection differs from the source. This may
    /// represent another adapter, account, or endpoint; the catalog does not
    /// infer adapter identity from an opaque connection ID.
    case crossProvider
}

/// Source metadata captured when a new conversation continues another one.
/// Keeping the source binding here preserves useful lineage even if the source
/// record is later removed from the local catalog.
struct ConversationContinuation: Codable, Hashable, Sendable {
    let sourceConversationID: ConversationID
    let sourceBinding: ProviderConversationBinding
    let kind: ConversationContinuationKind
    let continuedAt: Date

    init(
        sourceConversationID: ConversationID,
        sourceBinding: ProviderConversationBinding,
        kind: ConversationContinuationKind,
        continuedAt: Date = .now
    ) {
        self.sourceConversationID = sourceConversationID
        self.sourceBinding = sourceBinding
        self.kind = kind
        self.continuedAt = continuedAt
    }
}

/// Explicit root/continuation state. Custom coding keeps the persisted shape
/// stable instead of relying on Swift's synthesized associated-value format.
enum ConversationLineage: Codable, Hashable, Sendable {
    case root
    case continuation(ConversationContinuation)

    private enum Kind: String, Codable {
        case root
        case continuation
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case continuation
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .root:
            self = .root
        case .continuation:
            self = .continuation(
                try container.decode(ConversationContinuation.self, forKey: .continuation)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .root:
            try container.encode(Kind.root, forKey: .kind)
        case let .continuation(continuation):
            try container.encode(Kind.continuation, forKey: .kind)
            try container.encode(continuation, forKey: .continuation)
        }
    }
}

/// App-owned conversation metadata. Credentials and transcript contents never
/// enter this record; provider adapters remain responsible for both.
struct ConversationCatalogRecord: Identifiable, Codable, Hashable, Sendable {
    let id: ConversationID
    let binding: ProviderConversationBinding
    var lineage: ConversationLineage
    var title: String
    var project: ConversationProject?
    var isPinned: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: ConversationID = ConversationID(),
        binding: ProviderConversationBinding,
        lineage: ConversationLineage = .root,
        title: String,
        project: ConversationProject? = nil,
        isPinned: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.binding = binding
        self.lineage = lineage
        self.title = title
        self.project = project
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Versioned value snapshot used at the persistence boundary. Callers cannot
/// silently manufacture a snapshot for another schema version.
struct ConversationCatalogSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var conversations: [ConversationCatalogRecord]

    init(conversations: [ConversationCatalogRecord] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.conversations = conversations
    }
}
