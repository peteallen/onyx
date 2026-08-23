import Foundation

// MARK: - Stable identities

/// Opaque identity for one delegated invocation.
///
/// A job ID is intentionally independent of a provider's request ID.  The
/// latter may be absent, recycled, or contain provider-specific information;
/// Onyx uses this value for lineage, cancellation, and UI projection.
struct DelegationJobID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible, Identifiable
{
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// Creates a sortable-enough opaque ID without exposing provider data.
    init() {
        self.init(UUID().uuidString.lowercased())
    }

    var id: DelegationJobID { self }
    var description: String { rawValue }

    var isBlank: Bool {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Provider-aware identity for an agent participating in a delegation chain.
///
/// `ModelRef` is scoped to a `ProviderConnectionID`; retaining both values in
/// this type makes that relationship explicit at every parent/child boundary.
/// No token, API key, endpoint secret, or account credential is part of this
/// identity.
struct DelegationAgentIdentity: Codable, Equatable, Hashable, Sendable {
    let connectionID: ProviderConnectionID
    let model: ModelRef
    let agentID: String

    init(
        connectionID: ProviderConnectionID,
        model: ModelRef,
        agentID: String = "default"
    ) {
        self.connectionID = connectionID
        self.model = model
        self.agentID = agentID
    }

    init(model: ModelRef, agentID: String = "default") {
        self.init(connectionID: model.connectionID, model: model, agentID: agentID)
    }

    init(
        connectionID: ProviderConnectionID,
        modelID: String,
        agentID: String = "default"
    ) {
        self.init(
            connectionID: connectionID,
            model: ModelRef(connectionID: connectionID, modelID: modelID),
            agentID: agentID
        )
    }

    /// Alias that reads naturally at call sites which use provider-neutral
    /// model terminology.
    var modelRef: ModelRef { model }

    /// Whether the two provider-scoped identity fields agree and contain
    /// usable values.  The initializer stays non-throwing for easy decoding;
    /// `DelegationCoordinator` enforces this invariant before execution.
    var isValid: Bool {
        connectionID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            && model.connectionID == connectionID
            && model.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            && agentID.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
    }
}

/// Explicit target selected by a parent agent.  Keeping the connection and
/// model together prevents a model name from accidentally being sent to the
/// wrong provider account.
struct DelegationTarget: Codable, Equatable, Hashable, Sendable {
    let agent: DelegationAgentIdentity

    init(agent: DelegationAgentIdentity) {
        self.agent = agent
    }

    init(
        connectionID: ProviderConnectionID,
        model: ModelRef,
        agentID: String = "default"
    ) {
        self.init(
            agent: DelegationAgentIdentity(
                connectionID: connectionID,
                model: model,
                agentID: agentID
            )
        )
    }

    init(
        connectionID: ProviderConnectionID,
        modelID: String,
        agentID: String = "default"
    ) {
        self.init(
            agent: DelegationAgentIdentity(
                connectionID: connectionID,
                modelID: modelID,
                agentID: agentID
            )
        )
    }

    init(model: ModelRef, agentID: String = "default") {
        self.init(agent: DelegationAgentIdentity(model: model, agentID: agentID))
    }

    var connectionID: ProviderConnectionID { agent.connectionID }
    var model: ModelRef { agent.model }
    var modelRef: ModelRef { agent.model }
    var agentID: String { agent.agentID }

    var isValid: Bool { agent.isValid }
}

/// The ancestor chain visible to a provider adapter and to the UI.
///
/// `agents` contains the invoking agent(s), not the target of the request
/// currently being submitted.  For example, a Codex parent delegating to
/// Qwen has `[Codex]`; a Qwen child delegating back to Codex has
/// `[Codex, Qwen]`.  The coordinator appends the target to result metadata.
struct DelegationLineage: Codable, Equatable, Hashable, Sendable {
    let rootJobID: DelegationJobID?
    let parentJobID: DelegationJobID?
    let agents: [DelegationAgentIdentity]
    let depth: Int

    init(
        rootJobID: DelegationJobID? = nil,
        parentJobID: DelegationJobID? = nil,
        agents: [DelegationAgentIdentity],
        depth: Int? = nil
    ) {
        self.rootJobID = rootJobID
        self.parentJobID = parentJobID
        self.agents = agents
        self.depth = max(0, depth ?? max(0, agents.count - 1))
    }

    init(rootAgent: DelegationAgentIdentity) {
        self.init(agents: [rootAgent])
    }

    static func root(parent: DelegationAgentIdentity) -> Self {
        Self(rootAgent: parent)
    }

    /// Returns a lineage for a request launched by `childAgent` after the
    /// current parent job has been accepted by the coordinator.
    func appending(
        _ childAgent: DelegationAgentIdentity,
        parentJobID: DelegationJobID
    ) -> Self {
        var next = agents
        // Repeated identities are meaningful: an agent can delegate another
        // bounded job to the same provider/model, and that is still a hop.
        next.append(childAgent)
        return Self(
            rootJobID: rootJobID,
            parentJobID: parentJobID,
            agents: next,
            depth: depth + 1
        )
    }

    func assigningRootIfNeeded(_ jobID: DelegationJobID) -> Self {
        guard rootJobID == nil else { return self }
        return Self(
            rootJobID: jobID,
            parentJobID: parentJobID,
            agents: agents,
            depth: depth
        )
    }

    var parentAgent: DelegationAgentIdentity? { agents.last }

    /// Every provider/model hop known for this request, including the target.
    /// This derived value avoids duplicating child identity inside persisted
    /// lineage while giving transcript/UI projection a complete route.
    func route(to target: DelegationAgentIdentity) -> [DelegationAgentIdentity] {
        agents + [target]
    }
}

/// A provider-neutral delegation request. It intentionally contains only
/// routing data, user-provided prompt text, and the selected workspace path.
/// Credentials are resolved by the selected executor and can never be
/// transported through this value.
struct DelegationRequest: Codable, Equatable, Hashable, Sendable {
    let id: DelegationJobID
    let parentAgent: DelegationAgentIdentity
    let target: DelegationTarget
    let prompt: String
    /// Workspace selected by the parent task for this invocation. Keeping the
    /// path on the request prevents a provider-wide executor shared by several
    /// windows from accidentally running every child in the first workspace
    /// that constructed it.
    let workingDirectory: String?
    let lineage: DelegationLineage

    init(
        id: DelegationJobID = DelegationJobID(),
        parentAgent: DelegationAgentIdentity,
        target: DelegationTarget,
        prompt: String,
        workingDirectory: String? = nil,
        lineage: DelegationLineage? = nil
    ) {
        self.id = id
        self.parentAgent = parentAgent
        self.target = target
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.lineage = lineage ?? .root(parent: parentAgent)
    }

    init(
        id: DelegationJobID = DelegationJobID(),
        parent: DelegationAgentIdentity,
        target: DelegationTarget,
        prompt: String,
        workingDirectory: String? = nil,
        lineage: DelegationLineage? = nil
    ) {
        self.init(
            id: id,
            parentAgent: parent,
            target: target,
            prompt: prompt,
            workingDirectory: workingDirectory,
            lineage: lineage
        )
    }

    /// Convenience for callers selecting a connection/model directly.
    init(
        id: DelegationJobID = DelegationJobID(),
        parentAgent: DelegationAgentIdentity,
        targetConnectionID: ProviderConnectionID,
        targetModel: ModelRef,
        targetAgentID: String = "default",
        prompt: String,
        workingDirectory: String? = nil,
        lineage: DelegationLineage? = nil
    ) {
        self.init(
            id: id,
            parentAgent: parentAgent,
            target: DelegationTarget(
                connectionID: targetConnectionID,
                model: targetModel,
                agentID: targetAgentID
            ),
            prompt: prompt,
            workingDirectory: workingDirectory,
            lineage: lineage
        )
    }

    var targetConnectionID: ProviderConnectionID { target.connectionID }
    var targetModel: ModelRef { target.model }
    var childAgent: DelegationAgentIdentity { target.agent }

    func assigningRootIfNeeded() -> Self {
        Self(
            id: id,
            parentAgent: parentAgent,
            target: target,
            prompt: prompt,
            workingDirectory: workingDirectory,
            lineage: lineage.assigningRootIfNeeded(id)
        )
    }
}

// MARK: - Lifecycle and output

enum DelegationJobState: String, Codable, Equatable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .queued, .running: false
        case .succeeded, .failed, .cancelled: true
        }
    }
}

/// Progress emitted by an executor.  A progress update contains no raw
/// provider response and is bounded before it enters the event log.
struct DelegationProgressUpdate: Codable, Equatable, Hashable, Sendable {
    let phase: String
    let message: String?
    let fraction: Double?

    init(phase: String, message: String? = nil, fraction: Double? = nil) {
        let normalizedPhase = phase.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phase = normalizedPhase.isEmpty
            ? "working"
            : String(normalizedPhase.prefix(80))
        self.message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        if let fraction, fraction.isFinite {
            self.fraction = min(1, max(0, fraction))
        } else {
            self.fraction = nil
        }
    }
}

struct DelegationUsage: Codable, Equatable, Hashable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

/// Safe output returned by a provider-specific executor. Provider response
/// IDs and raw JSON are deliberately omitted so adapters cannot accidentally
/// leak headers or credentials into the app-owned delegation log. A bounded
/// child-conversation identity is retained separately when the provider owns
/// one, because that is the join key for opening a delegated task in the UI.
struct DelegationOutput: Codable, Equatable, Hashable, Sendable {
    let text: String
    let usage: DelegationUsage?
    let childConversationID: String?
    /// Set when the executor or coordinator had to bound an otherwise valid
    /// response. Callers can surface this rather than silently presenting a
    /// partial result as complete.
    let truncatedAtCharacterLimit: Int?

    init(
        text: String,
        usage: DelegationUsage? = nil,
        childConversationID: String? = nil,
        truncatedAtCharacterLimit: Int? = nil
    ) {
        self.text = text
        self.usage = usage
        self.childConversationID = childConversationID.flatMap {
            DelegationSafeText.boundedIdentifier($0)
        }
        self.truncatedAtCharacterLimit = truncatedAtCharacterLimit.flatMap {
            $0 > 0 ? $0 : nil
        }
    }
}

struct DelegationProgress: Codable, Equatable, Hashable, Sendable {
    let jobID: DelegationJobID
    let target: DelegationTarget
    let lineage: DelegationLineage
    let update: DelegationProgressUpdate
    let emittedAt: Date
}

struct DelegationJobSnapshot: Codable, Equatable, Hashable, Sendable {
    let id: DelegationJobID
    let request: DelegationRequest
    let state: DelegationJobState
    let submittedAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let latestProgress: DelegationProgressUpdate?

    var target: DelegationTarget { request.target }
    var lineage: DelegationLineage { request.lineage }
}

enum DelegationFailureCode: String, Codable, Equatable, Hashable, Sendable {
    case invalidRequest
    case unavailable
    case unsupportedModel
    case provider
    case execution
    case unknown
}

/// Terminal provider failure.  `message` is sanitized by the coordinator;
/// callers should treat it as display text, not a machine-readable payload.
struct DelegationFailure: Codable, Equatable, Hashable, Sendable, Error, LocalizedError {
    let jobID: DelegationJobID
    let target: DelegationTarget
    let lineage: DelegationLineage
    let code: DelegationFailureCode
    let message: String
    let occurredAt: Date

    var errorDescription: String? { message }
}

enum DelegationCancellationReason: String, Codable, Equatable, Hashable, Sendable {
    case user
    case parent
    case shutdown
    case superseded
    case unknown
}

struct DelegationCancellation: Codable, Equatable, Hashable, Sendable, Error, LocalizedError {
    let jobID: DelegationJobID
    let target: DelegationTarget
    let lineage: DelegationLineage
    let reason: DelegationCancellationReason
    let occurredAt: Date

    var errorDescription: String? {
        switch reason {
        case .user: "Delegated job was cancelled."
        case .parent: "Delegated job was cancelled by its parent."
        case .shutdown: "Delegated job was cancelled because the runtime is shutting down."
        case .superseded: "Delegated job was superseded."
        case .unknown: "Delegated job was cancelled."
        }
    }
}

struct DelegationCancellationRequest: Codable, Equatable, Hashable, Sendable {
    let jobID: DelegationJobID
    let target: DelegationTarget
    let lineage: DelegationLineage
    let reason: DelegationCancellationReason
    /// State at the instant cancellation was requested. Queued cancellation
    /// must not be projected as work that reached a provider.
    let state: DelegationJobState
    let occurredAt: Date
}

/// Ordered lifecycle stream for one job and for the coordinator-wide stream.
enum DelegationEvent: Sendable, Equatable {
    case queued(DelegationJobSnapshot)
    case started(DelegationJobSnapshot)
    case progress(DelegationProgress)
    case cancellationRequested(DelegationCancellationRequest)
    case completed(DelegationResult)
    case failed(DelegationFailure)
    case cancelled(DelegationCancellation)

    var jobID: DelegationJobID {
        switch self {
        case let .queued(snapshot), let .started(snapshot): snapshot.id
        case let .progress(progress): progress.jobID
        case let .cancellationRequested(request): request.jobID
        case let .completed(result): result.jobID
        case let .failed(failure): failure.jobID
        case let .cancelled(cancellation): cancellation.jobID
        }
    }

    var state: DelegationJobState {
        switch self {
        case .queued: .queued
        case .started, .progress: .running
        case let .cancellationRequested(request): request.state
        case .completed: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    var isTerminal: Bool { state.isTerminal }
}

/// Result enriched with the provider-aware child identity and complete
/// lineage.  The parent can project this into a transcript without knowing
/// anything about the executor's wire protocol.
struct DelegationResult: Codable, Equatable, Hashable, Sendable {
    let jobID: DelegationJobID
    let parentAgent: DelegationAgentIdentity
    let target: DelegationTarget
    let lineage: DelegationLineage
    let output: DelegationOutput
    let completedAt: Date

    var text: String { output.text }
    var usage: DelegationUsage? { output.usage }
    var isTruncated: Bool { output.truncatedAtCharacterLimit != nil }
    var childAgent: DelegationAgentIdentity { target.agent }
    var route: [DelegationAgentIdentity] { lineage.route(to: target.agent) }
}

enum DelegationResultError: Error, Sendable, Equatable, LocalizedError {
    case failed(DelegationFailure)
    case cancelled(DelegationCancellation)

    var errorDescription: String? {
        switch self {
        case let .failed(failure): failure.errorDescription
        case let .cancelled(cancellation): cancellation.errorDescription
        }
    }
}

/// Return value from `submit`.  The stream is hot and begins with a queued
/// event, so callers can attach UI projection immediately without polling.
struct DelegationJobHandle: Sendable {
    let jobID: DelegationJobID
    let request: DelegationRequest
    /// Replaying event subscription for this job. The coordinator retains
    /// lifecycle boundaries even when an executor reports progress faster
    /// than a UI can render it.
    let events: DelegationEventStream
}

typealias DelegationSubmission = DelegationJobHandle

/// Independent, bounded subscription to delegation lifecycle events. Every
/// call to `DelegationCoordinator.events(for:)` creates a fresh stream, so UI,
/// persistence, and diagnostics never compete for elements.
struct DelegationEventStream: AsyncSequence, Sendable {
    typealias Element = DelegationEvent

    struct AsyncIterator: AsyncIteratorProtocol {
        private let subscription: DelegationEventSubscription

        fileprivate init(subscription: DelegationEventSubscription) {
            self.subscription = subscription
        }

        mutating func next() async -> DelegationEvent? {
            await subscription.buffer.next()
        }
    }

    fileprivate let id: UUID
    private let subscription: DelegationEventSubscription

    init(id: UUID, buffer: DelegationEventBuffer) {
        self.id = id
        subscription = DelegationEventSubscription(buffer: buffer)
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(subscription: subscription)
    }
}

/// The coordinator owns only the event buffer. Stream and iterator copies
/// share this lease, whose deinitialization unregisters a subscription even
/// when a caller drops it without an outstanding `next()` to cancel.
fileprivate final class DelegationEventSubscription: @unchecked Sendable {
    let buffer: DelegationEventBuffer

    init(buffer: DelegationEventBuffer) {
        self.buffer = buffer
    }

    deinit {
        buffer.finish()
    }
}

/// Lock-backed so the coordinator can publish events synchronously and retain
/// exact order. The queue coalesces progress first and never drops queued,
/// started, cancellation, or terminal lifecycle boundaries.
final class DelegationEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private let onFinish: (@Sendable () -> Void)?
    private var queue: [DelegationEvent] = []
    private var waiter: CheckedContinuation<DelegationEvent?, Never>?
    private var isFinished = false

    init(
        capacity: Int = 256,
        onFinish: (@Sendable () -> Void)? = nil
    ) {
        self.capacity = max(4, capacity)
        self.onFinish = onFinish
    }

    func publish(_ event: DelegationEvent) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
            return
        }

        if queue.count >= capacity {
            if case .progress = event {
                if let lastProgress = queue.lastIndex(where: Self.isProgress) {
                    queue[lastProgress] = event
                }
                lock.unlock()
                return
            }
            if let progress = queue.firstIndex(where: Self.isProgress) {
                queue.remove(at: progress)
            } else if let removable = queue.firstIndex(where: { !$0.isTerminal }) {
                queue.remove(at: removable)
            } else {
                queue.removeFirst()
            }
        }
        queue.append(event)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
        onFinish?()
    }

    func next() async -> DelegationEvent? {
        if Task.isCancelled {
            finish()
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !queue.isEmpty {
                    let event = queue.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: event)
                } else if isFinished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    // AsyncSequence permits one outstanding next call per
                    // iterator. A second iterator should use a fresh stream.
                    precondition(waiter == nil)
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish()
        }
    }

    private static func isProgress(_ event: DelegationEvent) -> Bool {
        if case .progress = event { return true }
        return false
    }
}

// MARK: - Internal safe text helpers

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DelegationSafeText {
    /// Provider adapters should already return display-safe errors. This
    /// second line of defense strips common bearer/API-key spellings and
    /// bounds text before it is emitted to an event stream. Use this for
    /// errors and progress only; successful model output is user-visible
    /// content and must not be heuristically rewritten.
    static func sanitizeDiagnostic(_ rawValue: String, limit: Int = 1_000) -> String {
        var value = rawValue
        let patterns = [
            "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+",
            "(?i)(?:sk|rk|xai|ghp|github_pat)[-_][A-Za-z0-9_\\-]{8,}",
            "(?i)xox[baprs]-[A-Za-z0-9-]{8,}",
            "(?i)hf_[A-Za-z0-9]{8,}",
            "\\bAKIA[0-9A-Z]{16}\\b",
            "\\bAIza[0-9A-Za-z_-]{20,}\\b",
            "(?i)[\"']?(?:api[-_ ]?key|access[-_ ]?token|authorization|secret[-_ ]?access[-_ ]?key)[\"']?\\s*[:=]\\s*[\"']?[^\"'\\s,;}]+[\"']?",
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: .regularExpression
            )
        }
        if value.count > limit {
            value = String(value.prefix(limit)) + "…"
        }
        return value.isEmpty ? "Provider execution failed." : value
    }

    static let outputCharacterLimit = 100_000
    static let identifierCharacterLimit = 512

    static func boundedIdentifier(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= identifierCharacterLimit else { return nil }
        return value
    }

    static func boundedOutput(
        _ rawValue: String,
        limit: Int = outputCharacterLimit
    ) -> String {
        guard rawValue.count > limit else { return rawValue }
        return String(rawValue.prefix(limit)) + "…"
    }
}
