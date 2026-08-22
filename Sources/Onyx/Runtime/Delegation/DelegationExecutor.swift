import Foundation

/// Progress sink supplied to a provider-specific executor.  It is async so a
/// coordinator can preserve progress ordering without blocking the provider's
/// network or app-server task.
typealias DelegationProgressReporter =
    @Sendable (DelegationProgressUpdate) async -> Void

/// Narrow execution boundary shared by Codex, OpenAI-compatible chat, and
/// future providers.  Implementations resolve their own credentials and
/// transport internally; only a credential-free request crosses this seam.
///
/// A provider adapter may wrap an existing `AgentRuntime`, an OpenAI chat
/// transport, or another native client.  The coordinator does not assume
/// threads, tools, approvals, or a particular wire protocol.
protocol DelegationExecutor: Sendable {
    /// Stable configured connection served by this executor.
    var connectionID: ProviderConnectionID { get }

    /// Return false when this adapter has a discovered model catalog and the
    /// requested model is not available.  The default keeps local/vLLM and
    /// Codex adapters usable before discovery metadata is loaded.
    func supports(model: ModelRef) -> Bool

    /// Execute one provider-neutral prompt.  Throwing errors are converted to
    /// sanitized `DelegationFailure` values by `DelegationCoordinator`.
    func execute(
        _ request: DelegationRequest,
        reportProgress: @escaping DelegationProgressReporter
    ) async throws -> DelegationOutput
}
extension DelegationExecutor {
    func supports(model: ModelRef) -> Bool {
        model.connectionID == connectionID
    }
}

/// A closure-backed adapter that makes integration and deterministic tests
/// straightforward.  Production code can use the same type to bridge a
/// Codex `AgentRuntime` or OpenAI-compatible chat transport while keeping
/// credentials outside the delegation layer.
struct ClosureDelegationExecutor: DelegationExecutor {
    let connectionID: ProviderConnectionID
    private let supportedModelIDs: Set<String>?
    private let operation: @Sendable (
        DelegationRequest,
        @escaping DelegationProgressReporter
    ) async throws -> DelegationOutput

    init(
        connectionID: ProviderConnectionID,
        supportedModelIDs: Set<String>? = nil,
        operation: @escaping @Sendable (
            DelegationRequest,
            @escaping DelegationProgressReporter
        ) async throws -> DelegationOutput
    ) {
        self.connectionID = connectionID
        self.supportedModelIDs = supportedModelIDs
        self.operation = operation
    }

    func supports(model: ModelRef) -> Bool {
        guard model.connectionID == connectionID else { return false }
        guard let supportedModelIDs else { return true }
        return supportedModelIDs.contains(model.modelID)
    }

    func execute(
        _ request: DelegationRequest,
        reportProgress: @escaping DelegationProgressReporter
    ) async throws -> DelegationOutput {
        try await operation(request, reportProgress)
    }
}

/// Short alias useful when an adapter is conceptually a runtime rather than
/// a closure.  Keeping it as a typealias avoids a second abstraction layer.
typealias DelegationRuntimeExecutor = ClosureDelegationExecutor

/// A small typed error vocabulary adapters may use when they do not want to
/// expose a provider's raw error object.  The coordinator also accepts other
/// errors and sanitizes their display text.
enum DelegationExecutorError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case unsupportedModel(String)
    case provider(String)
    case execution(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The selected provider connection is unavailable."
        case let .unsupportedModel(modelID):
            "The selected provider does not support model \(modelID)."
        case let .provider(message), let .execution(message):
            message
        }
    }
}
