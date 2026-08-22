import Foundation

enum AgentRuntimeKind: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
    case openRouter
    case local

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .openRouter: "OpenRouter"
        case .local: "Local"
        }
    }
}

struct RuntimeCapabilities: OptionSet, Sendable {
    let rawValue: UInt64

    static let streaming = Self(rawValue: 1 << 0)
    static let steering = Self(rawValue: 1 << 1)
    static let interruption = Self(rawValue: 1 << 2)
    static let approvals = Self(rawValue: 1 << 3)
    static let threadForking = Self(rawValue: 1 << 4)
    static let threadArchiving = Self(rawValue: 1 << 5)
    static let reasoning = Self(rawValue: 1 << 6)
    static let tools = Self(rawValue: 1 << 7)
    static let diffs = Self(rawValue: 1 << 8)
    static let terminal = Self(rawValue: 1 << 9)
    static let images = Self(rawValue: 1 << 10)
    static let usage = Self(rawValue: 1 << 11)
    static let threadCompaction = Self(rawValue: 1 << 12)
    static let threadDeletion = Self(rawValue: 1 << 13)
    /// The runtime can start a structured code-review turn. This is separate
    /// from `diffs`: a provider may be able to display changes without running
    /// a review, or run a review without supplying a native diff surface.
    static let codeReview = Self(rawValue: 1 << 14)
}

struct RuntimeSession: Sendable, Equatable {
    let runtime: AgentRuntimeKind
    let displayName: String
    let accountLabel: String?
    let planLabel: String?
    let auth: RuntimeAuthState
    let availableLoginMethods: [RuntimeLoginMethod]
    let availableModels: [RuntimeModel]
    let capabilities: RuntimeCapabilities
}

/// Provider-neutral account state. Credentials never cross this boundary;
/// providers keep their own token/key stores and expose only this projection.
struct RuntimeAuthState: Sendable, Equatable {
    let mode: RuntimeAuthMode?
    let email: String?
    let planLabel: String?
    let requiresAuthentication: Bool

    var isSignedIn: Bool {
        mode != nil || email != nil
    }

    var canRun: Bool {
        isSignedIn || !requiresAuthentication
    }

    var displayLabel: String {
        if let email, !email.isEmpty { return email }
        if let mode { return mode.displayName }
        return requiresAuthentication ? "Not signed in" : "Authentication not required"
    }

    var planDisplayLabel: String? {
        guard let planLabel = planLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !planLabel.isEmpty else { return nil }

        return planLabel
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { token in
                switch token.lowercased() {
                case "api": "API"
                default: token.capitalized
                }
            }
            .joined(separator: " ")
    }

    static let signedOut = Self(
        mode: nil,
        email: nil,
        planLabel: nil,
        requiresAuthentication: true
    )
}

enum RuntimeAuthMode: String, Sendable, Codable, Equatable {
    case apiKey = "apikey"
    case chatgpt
    case chatgptAuthTokens
    case headers
    case agentIdentity
    case personalAccessToken
    case bedrockApiKey
    case unknown

    var displayName: String {
        switch self {
        case .apiKey: "API key"
        case .chatgpt, .chatgptAuthTokens: "ChatGPT"
        case .headers: "Headers"
        case .agentIdentity: "Agent identity"
        case .personalAccessToken: "Personal access token"
        case .bedrockApiKey: "Amazon Bedrock"
        case .unknown: "Connected account"
        }
    }

    static func from(raw: String?) -> Self {
        guard let raw else { return .unknown }
        return switch raw {
        case "apikey", "apiKey": .apiKey
        case "chatgpt": .chatgpt
        case "chatgptAuthTokens": .chatgptAuthTokens
        case "headers": .headers
        case "agentIdentity": .agentIdentity
        case "personalAccessToken": .personalAccessToken
        case "bedrockApiKey", "amazonBedrock": .bedrockApiKey
        default: .unknown
        }
    }
}

enum RuntimeLoginCeremony: String, Sendable, Codable, Equatable, Hashable {
    case browser
    case deviceCode
}

struct RuntimeLoginMethod: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let displayName: String
    let detail: String
    let ceremony: RuntimeLoginCeremony
}

struct RuntimeLoginStart: Sendable, Equatable {
    let method: RuntimeLoginMethod
    let loginID: String
    let authURL: URL?
    let verificationURL: URL?
    let userCode: String?
}

struct RuntimeLoginCompletion: Sendable, Equatable {
    let loginID: String?
    let success: Bool
    let error: String?
}

struct RuntimeModel: Identifiable, Sendable, Hashable {
    let id: String
    let displayName: String
    let description: String?
    let isDefault: Bool
    let defaultReasoningEffort: String?
    let reasoningEfforts: [String]
}

enum RuntimeSandboxMode: String, Sendable, Codable, CaseIterable {
    case readOnly
    case workspaceWrite
    case fullAccess
}

enum RuntimeApprovalPolicy: String, Sendable, Codable, CaseIterable {
    case untrusted
    case onRequest
    case never
}

enum RuntimeThreadStatus: String, Sendable, Codable {
    case idle
    case running
    case waitingForInput
    case waitingForApproval
    case failed
    case unknown

    var attention: RuntimeTaskAttention {
        switch self {
        case .idle: .ready
        case .running: .working
        case .waitingForInput: .needsInput
        case .waitingForApproval: .needsApproval
        case .failed: .failed
        case .unknown: .unknown
        }
    }

    var isBusy: Bool {
        switch self {
        case .running, .waitingForInput, .waitingForApproval: true
        case .idle, .failed, .unknown: false
        }
    }
}

/// The user-facing attention state for a task. Runtime adapters can retain
/// their native lifecycle states while every Onyx surface uses the same small,
/// truthful vocabulary.
enum RuntimeTaskAttention: String, Sendable, Codable, Hashable {
    case needsInput
    case needsApproval
    case working
    case failed
    case ready
    case unknown

    var label: String {
        switch self {
        case .needsInput: "Needs input"
        case .needsApproval: "Needs approval"
        case .working: "Working"
        case .failed: "Failed"
        case .ready: "Ready"
        case .unknown: "Status unknown"
        }
    }
}

struct RuntimeThread: Identifiable, Sendable, Hashable {
    let id: String
    var title: String
    var preview: String
    var cwd: String?
    var updatedAt: Date
    var status: RuntimeThreadStatus
    var isPinned: Bool
    var runtime: AgentRuntimeKind
    var model: String?
    var branch: String?
}

enum TimelineItemKind: String, Sendable, Codable {
    case userMessage
    case assistantMessage
    case reasoning
    case command
    case fileChange
    case tool
    case plan
    case approval
    case system
    case error
}

enum TimelineItemStatus: String, Sendable, Codable {
    case pending
    case running
    case completed
    case failed
    case declined
}

enum RuntimePlanStepStatus: Sendable, Codable, Hashable {
    case pending
    case inProgress
    case completed
    case unknown(String)

    init(rawValue: String) {
        self = switch rawValue {
        case "pending": .pending
        case "inProgress": .inProgress
        case "completed": .completed
        default: .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .pending: "pending"
        case .inProgress: "inProgress"
        case .completed: "completed"
        case let .unknown(value): value
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct RuntimePlanStep: Sendable, Hashable {
    let text: String
    let status: RuntimePlanStepStatus
}

/// A complete provider-neutral plan snapshot. Each update replaces the prior
/// snapshot for its turn; consumers must not concatenate updates as deltas.
struct RuntimePlan: Sendable, Hashable {
    let turnID: String
    let explanation: String?
    let steps: [RuntimePlanStep]

    var timelineStatus: TimelineItemStatus {
        if steps.contains(where: { $0.status == .inProgress }) { return .running }
        if !steps.isEmpty, steps.allSatisfy({ $0.status == .completed }) { return .completed }
        return .pending
    }

    var checklistText: String {
        steps.map { step in
            let marker = switch step.status {
            case .pending: "[ ]"
            case .inProgress: "[~]"
            case .completed: "[x]"
            case .unknown: "[?]"
            }
            return "\(marker) \(step.text)"
        }
        .joined(separator: "\n")
    }
}

enum RuntimeCollaborationAgentStatus: String, Sendable, Codable, Hashable {
    case starting
    case working
    case completed
    case interrupted
    case failed
    case stopped
    case unavailable
    case unknown

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .completed: "Completed"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }

    var isLive: Bool {
        self == .starting || self == .working
    }
}

struct RuntimeCollaborationAgent: Identifiable, Sendable, Hashable {
    let id: String
    var path: String?
    var status: RuntimeCollaborationAgentStatus
    var message: String?
    var updatedAt: Date

    var displayName: String {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            let suffix = String(id.suffix(6))
            return suffix.isEmpty ? "Agent" : "Agent \(suffix)"
        }

        let component = path.split(separator: "/").last.map(String.init) ?? path
        let words = component
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
        return words.isEmpty ? path : words.joined(separator: " ")
    }
}

enum RuntimeCollaborationAction: String, Sendable, Codable, Hashable {
    case spawn
    case sendInput
    case resume
    case wait
    case close
    case started
    case interacted
    case interrupted
}

/// Structured collaboration metadata carried beside a generic transcript card.
/// The transcript can render the card from `TimelineItem` alone, while summary
/// surfaces can aggregate agents without parsing provider JSON or display text.
struct RuntimeCollaborationActivity: Sendable, Hashable {
    let action: RuntimeCollaborationAction
    let agents: [RuntimeCollaborationAgent]
}

/// Media that belongs beside a provider-neutral timeline item. Provider
/// adapters translate their wire formats into one of these sources; transcript
/// rendering never needs to know which runtime produced the image.
struct TimelineAttachment: Identifiable, Sendable, Hashable {
    let id: String
    let source: TimelineAttachmentSource
    let accessibilityLabel: String
    /// A provider-assigned identity used by the thumbnail cache. This avoids
    /// hashing multi-megabyte data URLs on the main thread during cell reuse.
    let cacheIdentity: String

    init(
        id: String,
        source: TimelineAttachmentSource,
        accessibilityLabel: String,
        cacheIdentity: String? = nil
    ) {
        self.id = id
        self.source = source
        self.accessibilityLabel = accessibilityLabel
        self.cacheIdentity = cacheIdentity ?? UUID().uuidString
    }
}

enum TimelineAttachmentSource: Sendable, Hashable {
    /// A complete image data URL, including its media type and encoding.
    case dataURL(String)
    /// A path on the local machine. It intentionally remains a path instead of
    /// a file URL so providers cannot smuggle an unrelated URL scheme through.
    case localFilePath(String)
    /// A network image. Adapters only create this case for HTTP(S) URLs.
    case remoteURL(URL)
}

/// A bounded, provider-neutral link returned by a tool. Tool payloads are
/// intentionally not exposed directly to the transcript: adapters validate the
/// URL and retain only the display metadata needed for a safe native link row.
struct TimelineResourceLink: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let url: URL
    let detail: String?

    init(id: String, title: String, url: URL, detail: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.detail = detail
    }
}

struct TimelineItem: Identifiable, Sendable, Hashable {
    let id: String
    var kind: TimelineItemKind
    var title: String?
    var body: String
    var status: TimelineItemStatus
    var timestamp: Date
    var detail: String?
    var attachments: [TimelineAttachment] = []
    var links: [TimelineResourceLink] = []
    var collaboration: RuntimeCollaborationActivity? = nil
    var plan: RuntimePlan? = nil

    static func welcome() -> Self {
        Self(
            id: "onyx-welcome",
            kind: .assistantMessage,
            title: nil,
            body: "What are we building? I can work in this project, inspect its history, run tools, and keep the result grounded in the current checkout.",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
    }

    static func planUpdate(_ plan: RuntimePlan, timestamp: Date = .now) -> Self {
        Self(
            id: "runtime-plan:\(plan.turnID)",
            kind: .plan,
            title: "Plan",
            body: plan.checklistText,
            status: plan.timelineStatus,
            timestamp: timestamp,
            detail: plan.explanation,
            plan: plan
        )
    }
}

struct RuntimeConversation: Sendable, Equatable {
    var thread: RuntimeThread
    var items: [TimelineItem]
}

enum RuntimeRequestID: Sendable, Equatable, Hashable, CustomStringConvertible {
    case integer(Int)
    case string(String)

    var description: String {
        switch self {
        case let .integer(value): String(value)
        case let .string(value): value
        }
    }
}

/// A provider-neutral projection of something the running agent needs from the
/// person at the keyboard. Provider adapters keep their wire request around and
/// translate the typed response back into the provider's exact protocol shape.
struct RuntimeUserInteraction: Identifiable, Sendable, Equatable, Hashable {
    let id: RuntimeRequestID
    let threadID: String?
    let providerMethod: String
    let title: String
    let detail: String
    let kind: RuntimeUserInteractionKind

    var isBlocking: Bool {
        if case let .questions(prompt) = kind { return prompt.isBlocking }
        return true
    }
}

enum RuntimeUserInteractionKind: Sendable, Equatable, Hashable {
    case approval(RuntimeApprovalPrompt)
    case questions(RuntimeQuestionPrompt)
    case form(RuntimeFormPrompt)
    case externalLink(RuntimeExternalLinkPrompt)
    case unsupported
}

struct RuntimeApprovalPrompt: Sendable, Equatable, Hashable {
    enum Subject: Sendable, Equatable, Hashable {
        case command
        case fileChanges
        case permissions
        case network
    }

    let subject: Subject
    let command: String?
    /// Provider-neutral decisions that may be offered for this specific prompt.
    /// Providers that omit an availability list retain the legacy behavior of
    /// allowing every standard decision.
    let allowedDecisions: Set<ApprovalDecision>

    init(
        subject: Subject,
        command: String?,
        allowedDecisions: Set<ApprovalDecision> = Set(ApprovalDecision.allCases)
    ) {
        self.subject = subject
        self.command = command
        self.allowedDecisions = allowedDecisions
    }

    /// Kept as a convenience for the existing approval UI and test fixtures.
    init(subject: Subject, command: String?, supportsSessionApproval: Bool) {
        self.init(
            subject: subject,
            command: command,
            allowedDecisions: supportsSessionApproval
                ? Set(ApprovalDecision.allCases)
                : [.accept, .decline, .cancel]
        )
    }

    func allows(_ decision: ApprovalDecision) -> Bool {
        allowedDecisions.contains(decision)
    }

    var supportsSessionApproval: Bool {
        allows(.acceptForSession)
    }
}

struct RuntimeQuestionPrompt: Sendable, Equatable, Hashable {
    let questions: [RuntimeQuestion]
    let isBlocking: Bool
}

struct RuntimeQuestion: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let header: String
    let prompt: String
    let options: [RuntimeQuestionOption]
    let allowsOther: Bool
    let isSecret: Bool
}

struct RuntimeQuestionOption: Sendable, Equatable, Hashable {
    let label: String
    let detail: String
}

struct RuntimeFormPrompt: Sendable, Equatable, Hashable {
    let sourceName: String?
    let fields: [RuntimeFormField]
}

struct RuntimeFormField: Identifiable, Sendable, Equatable, Hashable {
    enum Kind: Sendable, Equatable, Hashable {
        case text(format: String?)
        case number(integerOnly: Bool)
        case toggle
        case singleChoice([RuntimeFormChoice])
        case multipleChoice([RuntimeFormChoice])
    }

    let id: String
    let label: String
    let detail: String?
    let isRequired: Bool
    let kind: Kind
    let initialValue: RuntimeFormValue?
}

struct RuntimeFormChoice: Sendable, Equatable, Hashable {
    let value: String
    let label: String
}

enum RuntimeFormValue: Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case strings([String])
}

/// In-progress input for a provider interaction. These values intentionally
/// live only in memory: task switching may rebuild the SwiftUI prompt, but
/// secrets and other answers must never be written to preferences.
struct RuntimeQuestionDraft: Sendable, Equatable {
    var selections: [String: String] = [:]
    var freeform: [String: String] = [:]
    var usesOther: Set<String> = []
}

struct RuntimeFormDraft: Sendable, Equatable {
    var textValues: [String: String] = [:]
    var boolValues: [String: Bool] = [:]
    var touchedBoolFields: Set<String> = []
    var choiceValues: [String: String] = [:]
    var multiValues: [String: Set<String>] = [:]
}

struct RuntimeExternalLinkPrompt: Sendable, Equatable, Hashable {
    let sourceName: String?
    let url: URL
}

enum RuntimeElicitationAction: String, Sendable, Equatable {
    case accept
    case decline
    case cancel
}

enum RuntimeUserInteractionResponse: Sendable, Equatable {
    case approval(ApprovalDecision)
    case answers([String: [String]])
    case form(action: RuntimeElicitationAction, values: [String: RuntimeFormValue])
    case externalLink(RuntimeElicitationAction)
}

enum AgentRuntimeEvent: Sendable, Equatable {
    case connectionChanged(RuntimeConnectionState)
    case accountUpdated(RuntimeAuthState)
    case loginCompleted(RuntimeLoginCompletion)
    case threadUpdated(RuntimeThread)
    case threadNameChanged(threadID: String, name: String?)
    case threadStatusChanged(threadID: String, status: RuntimeThreadStatus)
    case threadArchived(threadID: String)
    case threadUnarchived(threadID: String)
    case threadDeleted(threadID: String)
    case threadRefreshRequested(threadID: String)
    case itemStarted(threadID: String, item: TimelineItem)
    case itemDelta(threadID: String, itemID: String, delta: String)
    case itemCompleted(threadID: String, item: TimelineItem)
    case turnStarted(threadID: String, turnID: String)
    case planUpdated(threadID: String, plan: RuntimePlan)
    case turnCompleted(threadID: String, status: RuntimeThreadStatus)
    case userInteractionRequested(RuntimeUserInteraction)
    case userInteractionResolved(RuntimeRequestID)
    case runtimeNotice(title: String, detail: String)
}

enum RuntimeConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(String)
    case failed(String)
}

enum ApprovalDecision: String, Sendable, CaseIterable, Hashable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

struct StartThreadRequest: Sendable {
    var cwd: String
    var model: String?
    var ephemeral = false
    var sandboxMode = RuntimeSandboxMode.workspaceWrite
    var approvalPolicy = RuntimeApprovalPolicy.onRequest
}

/// Provider-neutral, ordered content supplied by the user for a turn. Runtime
/// adapters own the translation into their provider's wire representation.
enum RuntimeTurnInput: Sendable, Hashable {
    case text(String)
    case localImagePath(String)
    /// A complete HTTP(S) or image data URL.
    case imageURL(String)
}

struct StartTurnRequest: Sendable {
    var threadID: String
    var inputs: [RuntimeTurnInput]
    var model: String?
    var cwd: String?
    var reasoningEffort: String?
    var sandboxMode = RuntimeSandboxMode.workspaceWrite
    var approvalPolicy = RuntimeApprovalPolicy.onRequest

    init(
        threadID: String,
        inputs: [RuntimeTurnInput],
        model: String? = nil,
        cwd: String? = nil,
        reasoningEffort: String? = nil,
        sandboxMode: RuntimeSandboxMode = .workspaceWrite,
        approvalPolicy: RuntimeApprovalPolicy = .onRequest
    ) {
        self.threadID = threadID
        self.inputs = inputs
        self.model = model
        self.cwd = cwd
        self.reasoningEffort = reasoningEffort
        self.sandboxMode = sandboxMode
        self.approvalPolicy = approvalPolicy
    }

    /// Keeps text-only runtimes and fixtures source-compatible.
    init(
        threadID: String,
        text: String,
        model: String? = nil,
        cwd: String? = nil,
        reasoningEffort: String? = nil,
        sandboxMode: RuntimeSandboxMode = .workspaceWrite,
        approvalPolicy: RuntimeApprovalPolicy = .onRequest
    ) {
        self.init(
            threadID: threadID,
            inputs: [.text(text)],
            model: model,
            cwd: cwd,
            reasoningEffort: reasoningEffort,
            sandboxMode: sandboxMode,
            approvalPolicy: approvalPolicy
        )
    }

    var text: String {
        inputs.compactMap { input in
            guard case let .text(text) = input else { return nil }
            return text
        }.joined(separator: "\n")
    }
}

enum RuntimeReviewTarget: Sendable, Equatable {
    case uncommittedChanges
}

enum RuntimeReviewDelivery: Sendable, Equatable {
    case inline
    case detached
}

struct StartReviewRequest: Sendable, Equatable {
    var threadID: String
    var target = RuntimeReviewTarget.uncommittedChanges
    var delivery = RuntimeReviewDelivery.inline
}

struct RuntimeReviewRun: Sendable, Equatable {
    let threadID: String
    let turnID: String
}
