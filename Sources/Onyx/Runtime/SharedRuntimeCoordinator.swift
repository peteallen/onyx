import Foundation

/// Owns one provider runtime while presenting an independent event stream to
/// every consumer. `AsyncStream` distributes elements across concurrent
/// iterators rather than broadcasting them, so sharing a raw `AgentRuntime`
/// between window models would make each window miss an arbitrary subset of
/// provider events.
///
/// The coordinator is deliberately UI-agnostic. A future multiwindow
/// composition root can share one instance between per-window app models
/// without starting a second app-server process or duplicating a connection
/// handshake.
final class SharedRuntimeCoordinator: AgentRuntime, @unchecked Sendable {
    static let defaultSubscriberEventLimit = 256
    static let defaultSubscriberDeltaByteLimit = 1_048_576

    let kind: AgentRuntimeKind

    /// Each access creates a new subscription. A consumer should retain and
    /// iterate the returned stream for its own lifetime. Adjacent token events
    /// for the same item are coalesced while they wait. If the retained event
    /// backlog reaches its limit, new non-delta events wait for the consumer,
    /// applying backpressure to the one shared source pump without reordering
    /// or silently desynchronizing any window.
    var events: AsyncStream<AgentRuntimeEvent> {
        eventBroadcaster.makeStream()
    }

    private let runtime: any AgentRuntime
    private let eventBroadcaster: RuntimeEventBroadcaster
    private let eventEmitter: RuntimeEventEmitter
    private let sessionState: SharedRuntimeSessionState
    private let eventPump: Task<Void, Never>

    init(
        runtime: any AgentRuntime,
        subscriberEventLimit: Int = defaultSubscriberEventLimit,
        subscriberDeltaByteLimit: Int = defaultSubscriberDeltaByteLimit
    ) {
        precondition(subscriberEventLimit > 0)
        precondition(subscriberDeltaByteLimit > 0)
        self.runtime = runtime
        kind = runtime.kind

        let broadcaster = RuntimeEventBroadcaster(
            eventLimit: subscriberEventLimit,
            deltaByteLimit: subscriberDeltaByteLimit
        )
        let emitter = RuntimeEventEmitter(broadcaster: broadcaster)
        let state = SharedRuntimeSessionState()
        let sourceEvents = runtime.events
        eventBroadcaster = broadcaster
        eventEmitter = emitter
        sessionState = state
        eventPump = Task {
            for await event in sourceEvents {
                // Invalidate connection snapshots before windows observe the
                // boundary event and decide whether to reconnect.
                if let authorization = await state.broadcastAuthorization(for: event) {
                    await emitter.yield(event, validator: {
                        await state.isBroadcastAuthorizationValid(authorization)
                    })
                }
            }
            await state.sourceFinished()
            await emitter.finish()
        }
    }

    deinit {
        eventPump.cancel()
        // Destruction is a cancellation boundary, not a graceful provider
        // shutdown. Any event still buffered for a window belongs to this
        // runtime generation and must not survive into a replacement.
        eventBroadcaster.cancel()
    }

    func connect() async throws -> RuntimeSession {
        try await sessionState.connect(using: runtime)
    }

    func disconnect() async {
        await sessionState.disconnect(using: runtime)
    }

    /// Permanently closes this coordinator before its provider configuration
    /// is mutated. Unlike an ordinary disconnect, retirement rejects every new
    /// operation immediately and waits for already-admitted writer calls to
    /// leave the shared boundary before the runtime is torn down.
    func retire() async {
        // Admit retirement at the shared operation boundary first. This
        // synchronously rejects later provider calls while the returned task
        // drains work that had already crossed the boundary.
        let retirement = await sessionState.beginRetirement(using: runtime)
        // Fence the event generation before awaiting that drain. Provider
        // disconnect may wait for an already-running writer, but stale UI
        // events must not remain visible during the wait.
        eventPump.cancel()
        await eventEmitter.cancel()
        await retirement.value
        // The provider may continue yielding buffered or late lifecycle
        // notifications after disconnect. A retired generation must never
        // mutate windows that are already rebinding to its replacement.
        // `cancel()` above also wakes bounded-queue producers, so a window that
        // stopped consuming cannot hold this provider replacement open.
    }

    /// Exposes the admission boundary for deterministic lifecycle coordination
    /// without waiting for provider teardown to finish.
    var isRetired: Bool {
        get async { await sessionState.hasRetired }
    }

    func startLogin(methodID: String) async throws -> RuntimeLoginStart {
        let token = try await sessionState.beginLoginOperation()
        let result: RuntimeLoginStart
        do {
            result = try await runtime.startLogin(methodID: methodID)
        } catch {
            await sessionState.failLoginStart(token)
            throw error
        }
        let accepted = await sessionState.completeLoginStart(token, loginID: result.loginID)
        guard accepted else {
            try? await runtime.cancelLogin(id: result.loginID)
            await sessionState.completeLoginCancellation(token, loginID: nil)
            throw await sessionState.currentBoundaryError()
        }
        // Keep the operation counted until this method is ready to hand the
        // provider result back to its caller. Logout can then never begin
        // between acceptance and delivery of the login ceremony.
        await sessionState.finishLoginStartDelivery(token)
        return result
    }

    func cancelLogin(id: String) async throws {
        let token = try await sessionState.beginLoginOperation(allowWaitingForLogout: true)
        do {
            try await runtime.cancelLogin(id: id)
            await sessionState.completeLoginCancellation(token, loginID: id)
        } catch {
            await sessionState.completeLoginCancellation(token, loginID: nil)
            throw error
        }
    }

    func logout() async throws {
        // Keep the provider request, synthetic boundary, and barrier release
        // inside one shared attempt. If several windows sign out together,
        // every caller waits until the one boundary event has been broadcast;
        // no sibling can observe a completed logout halfway through that
        // sequence.
        let emitter = eventEmitter
        try await sessionState.logout(using: runtime) {
            // Logout is a shared account boundary, even if a provider version
            // does not emit its own account notification. Every window must
            // immediately discard account-owned tasks, drafts, and approvals.
            await emitter.yield(.accountUpdated(.signedOut))
        }
    }

    func refreshAccount() async throws -> RuntimeSession {
        let session = try await sessionState.refresh(using: runtime)
        if session.auth.isSignedIn {
            let recoveryRevision = eventBroadcaster.authenticationRecoveryRevision
            if await sessionState.consumeAuthenticationRecoveryConfirmation() {
                // A second expiration can race the successful account read.
                // Clear only the recovery generation that this confirmation
                // actually observed; a newer one must remain sticky.
                eventBroadcaster.clearAuthenticationRecovery(ifRevision: recoveryRevision)
            }
        }
        return session
    }

    func listThreads(limit: Int, archived: Bool) async throws -> [RuntimeThread] {
        try await withAccountOperation { [runtime] in
            try await runtime.listThreads(limit: limit, archived: archived)
        }
    }

    func listAllThreads(archived: Bool) async throws -> [RuntimeThread] {
        try await withAccountOperation { [runtime] in
            try await runtime.listAllThreads(archived: archived)
        }
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        try await withAccountOperation { [runtime] in
            try await runtime.readThread(id: id)
        }
    }

    func readThread(
        id: String,
        initialHistoryPage: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        try await withCapabilityOperation(.threadHistoryPagination) { [runtime] in
            try await runtime.readThread(id: id, initialHistoryPage: initialHistoryPage)
        }
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await withAccountOperation { [runtime] in
            try await runtime.resumeThread(id: id)
        }
    }

    func resumeThread(
        id: String,
        initialHistoryPage: RuntimeInitialThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        try await withCapabilityOperation(.threadHistoryPagination) { [runtime] in
            try await runtime.resumeThread(id: id, initialHistoryPage: initialHistoryPage)
        }
    }

    func listThreadHistory(
        id: String,
        page: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadHistoryPage {
        try await withCapabilityOperation(.threadHistoryPagination) { [runtime] in
            try await runtime.listThreadHistory(id: id, page: page)
        }
    }

    func revertThread(id: String, beforeTurnID: String) async throws -> RuntimeThreadRevertResult {
        try await withCapabilityOperation(.threadHistoryRevert) { [runtime] in
            try await runtime.revertThread(id: id, beforeTurnID: beforeTurnID)
        }
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        try await withAccountOperation { [runtime] in
            try await runtime.startThread(request)
        }
    }

    func forkThread(id: String) async throws -> RuntimeThread {
        try await withAccountOperation { [runtime] in
            try await runtime.forkThread(id: id)
        }
    }

    func forkEphemeralThread(id: String) async throws -> RuntimeConversation {
        try await withAccountOperation { [runtime] in
            try await runtime.forkEphemeralThread(id: id)
        }
    }

    func compactThread(id: String) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.compactThread(id: id)
        }
    }

    func deleteThread(id: String) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.deleteThread(id: id)
        }
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.startTurn(request)
        }
    }

    func startReview(_ request: StartReviewRequest) async throws -> RuntimeReviewRun {
        try await withAccountOperation { [runtime] in
            try await runtime.startReview(request)
        }
    }

    func steer(threadID: String, text: String) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.steer(threadID: threadID, text: text)
        }
    }

    func steer(threadID: String, inputs: [RuntimeTurnInput]) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.steer(threadID: threadID, inputs: inputs)
        }
    }

    func interrupt(threadID: String) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.interrupt(threadID: threadID)
        }
    }

    func respond(
        to interactionID: RuntimeRequestID,
        with response: RuntimeUserInteractionResponse
    ) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.respond(to: interactionID, with: response)
        }
    }

    func renameThread(id: String, name: String) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.renameThread(id: id, name: name)
        }
    }

    func archiveThread(id: String) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.archiveThread(id: id)
        }
    }

    func unarchiveThread(id: String) async throws {
        try await withAccountOperation { [runtime] in
            try await runtime.unarchiveThread(id: id)
        }
    }

    private func withAccountOperation<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let token = try await sessionState.beginAccountOperation()
        do {
            let result = try await operation()
            await sessionState.finishAccountOperation(token)
            return result
        } catch {
            await sessionState.finishAccountOperation(token)
            throw error
        }
    }

    /// Records protocol evidence once at the shared provider boundary. This
    /// keeps a stale window from retrying a method another window has already
    /// proved unavailable, updates later connection snapshots, and broadcasts
    /// the same downgrade to every window that is already attached.
    private func withCapabilityOperation<Result: Sendable>(
        _ capability: RuntimeCapabilities,
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        guard try await sessionState.isCapabilityAvailable(capability) else {
            throw AgentRuntimeError.unsupported(Self.capabilityName(capability))
        }

        do {
            return try await withAccountOperation(operation)
        } catch {
            guard Self.isCapabilityCompatibilityFailure(error) else { throw error }
            if await sessionState.markCapabilityUnavailable(capability) {
                await eventEmitter.yield(.runtimeCapabilitiesDowngraded(capability))
            }
            throw error
        }
    }

    private static func isCapabilityCompatibilityFailure(_ error: any Error) -> Bool {
        guard let runtimeError = error as? AgentRuntimeError else { return false }
        switch runtimeError {
        case .unsupported:
            return true
        case let .requestFailed(code, _):
            return code == -32_601 || code == -32_602
        default:
            return false
        }
    }

    private static func capabilityName(_ capability: RuntimeCapabilities) -> String {
        if capability == .threadHistoryPagination { return "paginated thread history" }
        if capability == .threadHistoryRevert { return "thread history editing" }
        return "this runtime capability"
    }

    fileprivate static let accountBoundaryError = AgentRuntimeError.requestFailed(
        code: -32_100,
        message: "Account sign-out is in progress."
    )
    fileprivate static let retiredBoundaryError = AgentRuntimeError.requestFailed(
        code: -32_101,
        message: "Provider settings changed. Reconnect using the current configuration."
    )
}

/// Serializes acquisition of the runtime session and keeps the last successful
/// snapshot for windows that attach after the provider is already connected.
private enum EventBroadcastAuthorization: Sendable {
    case always
    case auth(generation: UInt64)
}

private actor SharedRuntimeSessionState {
    struct AccountOperationToken: Sendable, Hashable {
        fileprivate let id: UInt64
    }

    struct LoginOperationToken: Sendable, Hashable {
        fileprivate let id: UInt64
        fileprivate let revision: UInt64
    }

    private struct Attempt: Sendable {
        let id: UInt64
        let revision: UInt64
        let task: Task<RuntimeSession, any Error>
    }

    private struct LogoutAttempt: Sendable {
        let id: UInt64
        let task: Task<Void, any Error>
    }

    private struct RetirementAttempt: Sendable {
        let task: Task<Void, Never>
    }

    private var cachedSession: RuntimeSession?
    /// Model-specific compatibility work can finish after the provider's
    /// initial connection snapshot. Retain the newest catalog for this
    /// connection generation so a window that attaches later observes the
    /// same execution modes as windows that consumed the live event.
    private var availableModelsOverride: [RuntimeModel]?
    /// Protocol downgrades are runtime/binary facts rather than account facts,
    /// so they survive cached-session invalidation, logout, and reconnect for
    /// the lifetime of this coordinator.
    private var unavailableCapabilities: RuntimeCapabilities = []
    private var attempt: Attempt?
    private var activeSessionAttempts: [UInt64: Task<RuntimeSession, any Error>] = [:]
    private var nextAttemptID: UInt64 = 0
    private var revision: UInt64 = 0

    private var logoutWaiters: [CheckedContinuation<Void, Never>] = []
    private var accountOperationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeAccountOperations: Set<AccountOperationToken> = []
    private var nextAccountOperationID: UInt64 = 0
    private var loginDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeLoginOperations: Set<LoginOperationToken> = []
    private var activeLoginIDs: Set<String> = []
    private var nextLoginOperationID: UInt64 = 0
    private var logoutAttempt: LogoutAttempt?
    private var nextLogoutAttemptID: UInt64 = 0
    private var isLoggingOut = false
    private var signedOutBoundaryActive = false
    private var isRetired = false
    private var retirementAttempt: RetirementAttempt?
    private var authEventGeneration: UInt64 = 0
    private var authenticationRecoveryActive = false
    private var authenticationRecoveryConfirmationPending = false

    func connect(using runtime: any AgentRuntime) async throws -> RuntimeSession {
        guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        if isLoggingOut {
            await waitForLogoutIfNeeded()
            guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        }
        if let attempt {
            return try await result(of: attempt)
        }
        if let cachedSession {
            return cachedSession
        }

        nextAttemptID &+= 1
        let attempt = Attempt(
            id: nextAttemptID,
            revision: revision,
            task: Task { try await runtime.connect() }
        )
        self.attempt = attempt
        activeSessionAttempts[attempt.id] = attempt.task
        return try await result(of: attempt)
    }

    func refresh(using runtime: any AgentRuntime) async throws -> RuntimeSession {
        guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        if isLoggingOut {
            await waitForLogoutIfNeeded()
            guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        }
        // A connect handshake already includes the provider's session
        // snapshot, while simultaneous account refreshes from several windows
        // should become one provider request.
        if let attempt {
            return try await result(of: attempt)
        }

        nextAttemptID &+= 1
        let attempt = Attempt(
            id: nextAttemptID,
            revision: revision,
            task: Task { try await runtime.refreshAccount() }
        )
        self.attempt = attempt
        activeSessionAttempts[attempt.id] = attempt.task
        return try await result(of: attempt)
    }

    func broadcastAuthorization(for event: AgentRuntimeEvent) -> EventBroadcastAuthorization? {
        guard !isRetired else { return nil }
        switch event {
        case .connectionChanged(.disconnected), .connectionChanged(.failed):
            availableModelsOverride = nil
            invalidate()
            return .always
        case .connectionChanged:
            return .always
        case let .runtimeModelsUpdated(models):
            availableModelsOverride = models
            if let cachedSession {
                self.cachedSession = replacingAvailableModels(
                    in: cachedSession,
                    with: models
                )
            }
            return .always
        case let .accountUpdated(auth):
            // Account events make an otherwise connected session snapshot
            // stale. The result of an older provider request may still return
            // to its caller, but it cannot become the durable account snapshot.
            invalidateSessionSnapshot()

            if auth.isSignedIn {
                guard !isLoggingOut else { return nil }
                // This notification carries no login ID. After an explicit
                // sign-out it cannot prove that a new ceremony succeeded;
                // wait for the correlated loginCompleted event instead.
                guard !signedOutBoundaryActive else { return nil }
                return .auth(generation: authEventGeneration)
            }

            // A coordinator-owned logout emits one canonical boundary after
            // the provider call returns. Suppress the provider's equivalent
            // notification on either side of that handoff so windows cannot
            // observe duplicate or scheduler-dependent account events.
            guard !isLoggingOut, !signedOutBoundaryActive else { return nil }
            activeLoginIDs.removeAll()
            if !auth.canRun {
                authenticationRecoveryActive = false
                authenticationRecoveryConfirmationPending = false
            }
            // Merely connecting while signed out must not close this boundary:
            // Codex can still list local task history before login. Only a
            // successful explicit logout establishes the privilege barrier.
            return .auth(generation: authEventGeneration)
        case .authenticationRecoveryRequired:
            authenticationRecoveryActive = true
            authenticationRecoveryConfirmationPending = false
            return .always
        case let .loginCompleted(completion):
            invalidateSessionSnapshot()
            guard !isLoggingOut else { return nil }

            let matchesActiveLogin: Bool
            if let loginID = completion.loginID {
                matchesActiveLogin = activeLoginIDs.contains(loginID)
            } else {
                matchesActiveLogin = !activeLoginIDs.isEmpty
            }

            if signedOutBoundaryActive, !matchesActiveLogin {
                return nil
            }

            // A successful completion can clear recovery in every window, so
            // only publish one that belongs to a ceremony admitted through
            // this shared coordinator. An unrelated or stale provider event
            // must not arm a routine signed-in refresh as confirmation.
            if authenticationRecoveryActive, completion.success, !matchesActiveLogin {
                return nil
            }

            if let loginID = completion.loginID {
                activeLoginIDs.remove(loginID)
            } else if matchesActiveLogin {
                activeLoginIDs.removeAll()
            }
            if completion.success, matchesActiveLogin {
                signedOutBoundaryActive = false
                if authenticationRecoveryActive {
                    authenticationRecoveryConfirmationPending = true
                }
            } else if !completion.success, matchesActiveLogin, authenticationRecoveryActive {
                authenticationRecoveryConfirmationPending = false
            }
            return .auth(generation: authEventGeneration)
        default:
            return .always
        }
    }

    func isBroadcastAuthorizationValid(_ authorization: EventBroadcastAuthorization) -> Bool {
        switch authorization {
        case .always:
            return true
        case let .auth(generation):
            return generation == authEventGeneration
        }
    }

    func sourceFinished() {
        availableModelsOverride = nil
        invalidate()
        authenticationRecoveryActive = false
        authenticationRecoveryConfirmationPending = false
    }

    func invalidate() {
        invalidateSessionSnapshot()
        activeLoginIDs.removeAll()
    }

    func disconnect(using runtime: any AgentRuntime) async {
        if isRetired {
            await retirementAttempt?.task.value
            return
        }
        availableModelsOverride = nil
        invalidate()
        await runtime.disconnect()
    }

    func consumeAuthenticationRecoveryConfirmation() -> Bool {
        guard authenticationRecoveryConfirmationPending else { return false }
        authenticationRecoveryConfirmationPending = false
        authenticationRecoveryActive = false
        return true
    }

    func beginLoginOperation(allowWaitingForLogout: Bool = false) async throws -> LoginOperationToken {
        guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        if isLoggingOut {
            guard allowWaitingForLogout else {
                throw SharedRuntimeCoordinator.accountBoundaryError
            }
            await waitForLogoutIfNeeded()
            guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        }
        nextLoginOperationID &+= 1
        let token = LoginOperationToken(id: nextLoginOperationID, revision: revision)
        activeLoginOperations.insert(token)
        return token
    }

    /// Returns `false` when logout invalidated this provider operation. An
    /// accepted login token remains active until the result is handed back to
    /// its caller, so logout cannot race that delivery boundary.
    func completeLoginStart(_ token: LoginOperationToken, loginID: String?) -> Bool {
        let accepted = activeLoginOperations.contains(token)
            && token.revision == revision
            && !isLoggingOut
            && !isRetired

        guard accepted else {
            if loginID == nil {
                finishLoginOperation(token)
            }
            return false
        }

        if let loginID {
            activeLoginIDs.insert(loginID)
        }
        return true
    }

    func finishLoginStartDelivery(_ token: LoginOperationToken) {
        finishLoginOperation(token)
    }

    func failLoginStart(_ token: LoginOperationToken) {
        finishLoginOperation(token)
    }

    func completeLoginCancellation(_ token: LoginOperationToken, loginID: String?) {
        if token.revision == revision, let loginID {
            activeLoginIDs.remove(loginID)
        }
        finishLoginOperation(token)
    }

    func beginAccountOperation() throws -> AccountOperationToken {
        guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        guard accountOperationIsAllowed() else {
            throw SharedRuntimeCoordinator.accountBoundaryError
        }
        nextAccountOperationID &+= 1
        let token = AccountOperationToken(id: nextAccountOperationID)
        activeAccountOperations.insert(token)
        return token
    }

    func finishAccountOperation(_ token: AccountOperationToken) {
        guard activeAccountOperations.remove(token) != nil,
              activeAccountOperations.isEmpty else { return }
        let waiters = accountOperationDrainWaiters
        accountOperationDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Coalesces concurrent callers onto one provider request and one shared
    /// signed-out boundary. The attempt does not release the account barrier
    /// until the boundary event has finished traversing every subscriber.
    func logout(
        using runtime: any AgentRuntime,
        emitBoundary: @escaping @Sendable () async -> Void
    ) async throws {
        guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        let pending: LogoutAttempt
        if let logoutAttempt {
            pending = logoutAttempt
        } else if signedOutBoundaryActive {
            // A late sibling sign-out is already covered by the completed
            // shared boundary; do not start a second provider request.
            return
        } else {
            isLoggingOut = true
            signedOutBoundaryActive = false
            let loginIDsToCancel = invalidateForLogout()
            nextLogoutAttemptID &+= 1
            let id = nextLogoutAttemptID
            let task = Task { [weak self] in
                do {
                    await self?.waitForAccountOperationsToDrain()
                    await self?.waitForLoginOperationsToDrain()
                    await self?.cancelActiveLogins(
                        loginIDs: loginIDsToCancel,
                        using: runtime
                    )
                    try await runtime.logout()
                    await emitBoundary()
                    await self?.finishLogout(id: id, succeeded: true)
                } catch {
                    await self?.finishLogout(id: id, succeeded: false)
                    throw error
                }
            }
            pending = LogoutAttempt(id: id, task: task)
            logoutAttempt = pending
        }

        try await pending.task.value
    }

    func accountOperationIsAllowed() -> Bool {
        !isRetired && !isLoggingOut && !signedOutBoundaryActive
    }

    func beginRetirement(using runtime: any AgentRuntime) -> Task<Void, Never> {
        if let retirementAttempt {
            return retirementAttempt.task
        }

        // Close admission before creating or awaiting any drain work. Every
        // call that reaches this actor afterward observes a permanent retired
        // boundary, including calls that were waiting for logout to finish.
        isRetired = true
        availableModelsOverride = nil
        let sessionAttempts = Array(activeSessionAttempts.values)
        let logoutTask = logoutAttempt?.task
        invalidateSessionSnapshot()
        activeLoginIDs.removeAll()

        let task = Task {
            await self.waitForAccountOperationsToDrain()
            await self.waitForLoginOperationsToDrain()
            for attempt in sessionAttempts {
                _ = try? await attempt.value
            }
            _ = try? await logoutTask?.value
            await runtime.disconnect()
        }
        let pending = RetirementAttempt(task: task)
        retirementAttempt = pending
        return pending.task
    }

    var hasRetired: Bool { isRetired }

    func currentBoundaryError() -> AgentRuntimeError {
        isRetired
            ? SharedRuntimeCoordinator.retiredBoundaryError
            : SharedRuntimeCoordinator.accountBoundaryError
    }

    func isCapabilityAvailable(_ capability: RuntimeCapabilities) throws -> Bool {
        guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
        return !unavailableCapabilities.contains(capability)
    }

    /// Returns true only for the first observation so concurrent failing
    /// callers cannot broadcast duplicate downgrade events.
    func markCapabilityUnavailable(_ capability: RuntimeCapabilities) -> Bool {
        guard !unavailableCapabilities.contains(capability) else { return false }
        unavailableCapabilities.formUnion(capability)
        if let cachedSession {
            self.cachedSession = applyingCapabilityDowngrades(to: cachedSession)
        }
        return true
    }

    private func waitForLogoutIfNeeded() async {
        guard isLoggingOut else { return }
        await withCheckedContinuation { continuation in
            logoutWaiters.append(continuation)
        }
    }

    private func waitForLoginOperationsToDrain() async {
        guard !activeLoginOperations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            loginDrainWaiters.append(continuation)
        }
    }

    private func waitForAccountOperationsToDrain() async {
        guard !activeAccountOperations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            accountOperationDrainWaiters.append(continuation)
        }
    }

    private func finishLoginOperation(_ token: LoginOperationToken) {
        guard activeLoginOperations.remove(token) != nil,
              activeLoginOperations.isEmpty else { return }
        let waiters = loginDrainWaiters
        loginDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func invalidateForLogout() -> [String] {
        let loginIDs = Array(activeLoginIDs)
        invalidateSessionSnapshot()
        activeLoginIDs.removeAll()
        return loginIDs
    }

    private func cancelActiveLogins(
        loginIDs: [String],
        using runtime: any AgentRuntime
    ) async {
        for loginID in loginIDs {
            // A provider may reject cancellation when the browser ceremony
            // has already completed. Logout still owns the boundary, so a
            // best-effort cancellation must not prevent provider logout.
            try? await runtime.cancelLogin(id: loginID)
        }
    }

    private func finishLogout(id: UInt64, succeeded: Bool) {
        guard logoutAttempt?.id == id else { return }
        logoutAttempt = nil
        isLoggingOut = false
        signedOutBoundaryActive = succeeded
        invalidateSessionSnapshot()
        if succeeded {
            authenticationRecoveryActive = false
            authenticationRecoveryConfirmationPending = false
        }

        let waiters = logoutWaiters
        logoutWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func invalidateSessionSnapshot() {
        revision &+= 1
        authEventGeneration &+= 1
        cachedSession = nil
        attempt = nil
    }

    private func result(of pending: Attempt) async throws -> RuntimeSession {
        do {
            let providerSession = try await pending.task.value
            activeSessionAttempts[pending.id] = nil
            guard !isRetired else { throw SharedRuntimeCoordinator.retiredBoundaryError }
            let currentProviderSession = availableModelsOverride.map {
                replacingAvailableModels(in: providerSession, with: $0)
            } ?? providerSession
            let session = boundarySafeSession(
                applyingCapabilityDowngrades(to: currentProviderSession)
            )
            if attempt?.id == pending.id {
                attempt = nil
            }
            if revision == pending.revision {
                cachedSession = session
            }
            return session
        } catch {
            activeSessionAttempts[pending.id] = nil
            if attempt?.id == pending.id {
                attempt = nil
            }
            throw error
        }
    }

    private func boundarySafeSession(_ session: RuntimeSession) -> RuntimeSession {
        guard (isLoggingOut || signedOutBoundaryActive), session.auth.isSignedIn else {
            return session
        }
        return RuntimeSession(
            runtime: session.runtime,
            displayName: session.displayName,
            accountLabel: nil,
            planLabel: nil,
            auth: .signedOut,
            availableLoginMethods: session.availableLoginMethods,
            availableModels: session.availableModels,
            capabilities: session.capabilities
        )
    }

    private func applyingCapabilityDowngrades(to session: RuntimeSession) -> RuntimeSession {
        guard !unavailableCapabilities.isEmpty,
              !session.capabilities.intersection(unavailableCapabilities).isEmpty else {
            return session
        }
        var capabilities = session.capabilities
        capabilities.subtract(unavailableCapabilities)
        return RuntimeSession(
            runtime: session.runtime,
            displayName: session.displayName,
            accountLabel: session.accountLabel,
            planLabel: session.planLabel,
            auth: session.auth,
            availableLoginMethods: session.availableLoginMethods,
            availableModels: session.availableModels,
            capabilities: capabilities
        )
    }

    private func replacingAvailableModels(
        in session: RuntimeSession,
        with models: [RuntimeModel]
    ) -> RuntimeSession {
        RuntimeSession(
            runtime: session.runtime,
            displayName: session.displayName,
            accountLabel: session.accountLabel,
            planLabel: session.planLabel,
            auth: session.auth,
            availableLoginMethods: session.availableLoginMethods,
            availableModels: models,
            capabilities: session.capabilities
        )
    }
}

/// Serializes provider events and coordinator-generated account boundaries.
/// Concurrent broadcasts must never enqueue in a different order for sibling
/// window subscribers.
private actor RuntimeEventEmitter {
    private struct PendingYield {
        let event: AgentRuntimeEvent
        let validator: (@Sendable () async -> Bool)?
        let completion: CheckedContinuation<Void, Never>
    }

    private let broadcaster: RuntimeEventBroadcaster
    private var pendingYields: [PendingYield] = []
    private var isYielding = false
    private var isFinished = false
    private var isCancelled = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(broadcaster: RuntimeEventBroadcaster) {
        self.broadcaster = broadcaster
    }

    func yield(_ event: AgentRuntimeEvent) async {
        await yield(event, validator: nil)
    }

    func yield(
        _ event: AgentRuntimeEvent,
        validator: (@Sendable () async -> Bool)?
    ) async {
        guard !isFinished else { return }
        await withCheckedContinuation { continuation in
            pendingYields.append(
                PendingYield(
                    event: event,
                    validator: validator,
                    completion: continuation
                )
            )
            drainPendingYields()
        }
    }

    func finish() async {
        guard !isFinished, !isCancelled else { return }
        isFinished = true
        guard isYielding || !pendingYields.isEmpty else {
            broadcaster.finish()
            return
        }

        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }

    /// Aborts the current event generation immediately. Unlike `finish()`,
    /// this intentionally drops pending and buffered events, because they may
    /// have been authorized by the old runtime just before its retirement
    /// boundary. It also resumes every continuation waiting on a bounded
    /// subscriber so a stalled window cannot hold retirement open forever.
    func cancel() {
        isCancelled = true
        isFinished = true

        let pending = pendingYields
        pendingYields.removeAll()

        broadcaster.cancel()
        for pendingYield in pending {
            pendingYield.completion.resume()
        }
        finishCancelledEmitterIfIdle()
    }

    private func drainPendingYields() {
        guard !isYielding, let next = pendingYields.first else {
            if isFinished, !isYielding {
                finishBroadcasterIfDrained()
            }
            return
        }

        pendingYields.removeFirst()
        isYielding = true
        let broadcaster = broadcaster
        Task { [weak self] in
            let shouldBroadcast = if let validator = next.validator {
                await validator()
            } else {
                true
            }
            if shouldBroadcast {
                await broadcaster.yield(next.event)
            }
            await self?.completeYield(next.completion)
        }
    }

    private func completeYield(_ completion: CheckedContinuation<Void, Never>) {
        completion.resume()
        isYielding = false
        if isCancelled {
            finishCancelledEmitterIfIdle()
            return
        }
        drainPendingYields()
    }

    private func finishCancelledEmitterIfIdle() {
        guard isCancelled, !isYielding else { return }
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func finishBroadcasterIfDrained() {
        guard isFinished, !isCancelled, !isYielding, pendingYields.isEmpty else { return }
        broadcaster.finish()
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Lock-backed because `AgentRuntime.events` is a synchronous requirement and
/// a new subscription must be constructible without crossing an actor hop.
///
/// Each subscriber has a pull-driven, bounded queue. Adjacent token deltas for
/// the same item are combined while they wait. A full queue suspends the source
/// event pump until that subscriber consumes an event. Both event count and
/// buffered token bytes are bounded, and no event is lost or reordered.
private final class RuntimeEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private let eventLimit: Int
    private let deltaByteLimit: Int
    private var subscriptions: [UUID: RuntimeEventSubscription] = [:]
    private var isFinished = false
    private var stickyAuthenticationRecovery: RuntimeAuthenticationRecovery?
    private var stickyAuthenticationRecoveryLogin: RuntimeLoginCompletion?
    private var stickyAuthenticationRecoveryRevision: UInt64 = 0

    init(eventLimit: Int, deltaByteLimit: Int) {
        self.eventLimit = eventLimit
        self.deltaByteLimit = deltaByteLimit
    }

    func makeStream() -> AsyncStream<AgentRuntimeEvent> {
        let id = UUID()
        lock.lock()
        var initialEvents: [AgentRuntimeEvent] = []
        if let stickyAuthenticationRecovery {
            initialEvents.append(.authenticationRecoveryRequired(stickyAuthenticationRecovery))
        }
        if let stickyAuthenticationRecoveryLogin {
            initialEvents.append(.loginCompleted(stickyAuthenticationRecoveryLogin))
        }
        let subscription = RuntimeEventSubscription(
            eventLimit: eventLimit,
            deltaByteLimit: deltaByteLimit,
            initialEvents: initialEvents
        )
        if isFinished {
            subscription.finish()
        } else {
            subscriptions[id] = subscription
        }
        lock.unlock()

        let lifetime = RuntimeEventSubscriptionLifetime(
            id: id,
            subscription: subscription,
            broadcaster: self
        )
        return AsyncStream(
            unfolding: { await lifetime.next() },
            onCancel: { lifetime.cancel() }
        )
    }

    func yield(_ event: AgentRuntimeEvent) async {
        let currentSubscriptions: [RuntimeEventSubscription] = lock.withLock {
            guard !isFinished else { return [] }
            switch event {
            case let .authenticationRecoveryRequired(recovery):
                stickyAuthenticationRecoveryRevision &+= 1
                stickyAuthenticationRecovery = recovery
                stickyAuthenticationRecoveryLogin = nil
            case let .loginCompleted(completion)
                where completion.success && stickyAuthenticationRecovery != nil:
                // The session actor admits only a completion correlated with a
                // login started through this coordinator while recovery is
                // active. Replay it after recovery so a just-opened sibling
                // also performs the authoritative account refresh.
                stickyAuthenticationRecoveryLogin = completion
            case let .loginCompleted(completion) where !completion.success:
                stickyAuthenticationRecoveryLogin = nil
            case let .accountUpdated(auth) where !auth.canRun:
                stickyAuthenticationRecovery = nil
                stickyAuthenticationRecoveryLogin = nil
            default:
                break
            }
            return Array(subscriptions.values)
        }

        await withTaskGroup(of: Void.self) { group in
            for subscription in currentSubscriptions {
                group.addTask { await subscription.enqueue(event) }
            }
            await group.waitForAll()
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        stickyAuthenticationRecovery = nil
        stickyAuthenticationRecoveryLogin = nil
        let currentSubscriptions = Array(subscriptions.values)
        lock.unlock()

        for subscription in currentSubscriptions {
            subscription.finish()
        }
    }

    var authenticationRecoveryRevision: UInt64 {
        lock.withLock { stickyAuthenticationRecoveryRevision }
    }

    func clearAuthenticationRecovery(ifRevision revision: UInt64) {
        lock.withLock {
            guard stickyAuthenticationRecoveryRevision == revision else { return }
            stickyAuthenticationRecovery = nil
            stickyAuthenticationRecoveryLogin = nil
        }
    }

    /// Closes this generation without delivering any queued events. Keep the
    /// subscription objects reachable until this pass completes so a race
    /// with a graceful `finish()` can still clear their already-buffered rows.
    func cancel() {
        lock.lock()
        let currentSubscriptions = Array(subscriptions.values)
        subscriptions.removeAll()
        isFinished = true
        stickyAuthenticationRecovery = nil
        stickyAuthenticationRecoveryLogin = nil
        lock.unlock()

        for subscription in currentSubscriptions {
            subscription.cancel()
        }
    }

    fileprivate func cancel(id: UUID, subscription: RuntimeEventSubscription) {
        lock.lock()
        if subscriptions[id] === subscription {
            subscriptions.removeValue(forKey: id)
        }
        lock.unlock()
        subscription.cancel()
    }
}

private final class RuntimeEventSubscriptionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let id: UUID
    private let subscription: RuntimeEventSubscription
    private weak var broadcaster: RuntimeEventBroadcaster?
    private var isCancelled = false

    init(
        id: UUID,
        subscription: RuntimeEventSubscription,
        broadcaster: RuntimeEventBroadcaster
    ) {
        self.id = id
        self.subscription = subscription
        self.broadcaster = broadcaster
    }

    deinit {
        cancel()
    }

    func next() async -> AgentRuntimeEvent? {
        await subscription.next()
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let broadcaster = broadcaster
        self.broadcaster = nil
        lock.unlock()

        if let broadcaster {
            broadcaster.cancel(id: id, subscription: subscription)
        } else {
            subscription.cancel()
        }
    }
}

private final class RuntimeEventSubscription: @unchecked Sendable {
    private typealias NextContinuation = CheckedContinuation<AgentRuntimeEvent?, Never>
    private typealias SpaceContinuation = CheckedContinuation<Void, Never>

    private let lock = NSLock()
    private let eventLimit: Int
    private let deltaByteLimit: Int
    private var bufferedEvents: [AgentRuntimeEvent] = []
    private var bufferedDeltaBytes = 0
    private var nextWaiters: [NextContinuation] = []
    private var spaceWaiters: [SpaceContinuation] = []
    private var isFinished = false
    private var isCancelled = false

    init(
        eventLimit: Int,
        deltaByteLimit: Int,
        initialEvents: [AgentRuntimeEvent] = []
    ) {
        self.eventLimit = eventLimit
        self.deltaByteLimit = deltaByteLimit
        bufferedEvents = initialEvents
        bufferedDeltaBytes = initialEvents.reduce(into: 0) { total, event in
            total += Self.deltaByteCount(of: event)
        }
    }

    func enqueue(_ event: AgentRuntimeEvent) async {
        while true {
            if enqueueIfPossible(event) { return }
            await waitForSpace(for: event)
        }
    }

    func next() async -> AgentRuntimeEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                prepareNext(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func finish() {
        let nextContinuations: [NextContinuation]
        let spaceContinuations: [SpaceContinuation]
        lock.lock()
        guard !isFinished, !isCancelled else {
            lock.unlock()
            return
        }
        isFinished = true
        nextContinuations = nextWaiters
        nextWaiters.removeAll()
        spaceContinuations = spaceWaiters
        spaceWaiters.removeAll()
        lock.unlock()

        for continuation in nextContinuations {
            continuation.resume(returning: nil)
        }
        for continuation in spaceContinuations { continuation.resume() }
    }

    func cancel() {
        let nextContinuations: [NextContinuation]
        let spaceContinuations: [SpaceContinuation]
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        bufferedEvents.removeAll()
        bufferedDeltaBytes = 0
        nextContinuations = nextWaiters
        nextWaiters.removeAll()
        spaceContinuations = spaceWaiters
        spaceWaiters.removeAll()
        lock.unlock()

        for continuation in nextContinuations {
            continuation.resume(returning: nil)
        }
        for continuation in spaceContinuations { continuation.resume() }
    }

    private func prepareNext(_ continuation: NextContinuation) {
        var event: AgentRuntimeEvent?
        var shouldResume = false
        var spaceContinuation: SpaceContinuation?

        lock.lock()
        if !bufferedEvents.isEmpty {
            event = bufferedEvents.removeFirst()
            bufferedDeltaBytes -= Self.deltaByteCount(of: event)
            if !spaceWaiters.isEmpty {
                spaceContinuation = spaceWaiters.removeFirst()
            }
            shouldResume = true
        } else if isFinished || isCancelled || Task.isCancelled {
            shouldResume = true
        } else {
            nextWaiters.append(continuation)
        }
        lock.unlock()

        spaceContinuation?.resume()
        if shouldResume {
            continuation.resume(returning: event)
        }
    }

    private func enqueueIfPossible(_ event: AgentRuntimeEvent) -> Bool {
        var nextContinuation: NextContinuation?

        lock.lock()
        guard !isFinished, !isCancelled else {
            lock.unlock()
            return true
        }

        if !nextWaiters.isEmpty {
            nextContinuation = nextWaiters.removeFirst()
            lock.unlock()
            nextContinuation?.resume(returning: event)
            return true
        }

        let deltaBytes = Self.deltaByteCount(of: event)
        let (newDeltaByteCount, byteCountOverflowed) = bufferedDeltaBytes.addingReportingOverflow(deltaBytes)
        guard !byteCountOverflowed, newDeltaByteCount <= deltaByteLimit else {
            lock.unlock()
            return false
        }

        if mergeIntoLastBufferedEventIfPossible(event) {
            bufferedDeltaBytes = newDeltaByteCount
            lock.unlock()
            return true
        }

        guard bufferedEvents.count < eventLimit else {
            lock.unlock()
            return false
        }
        bufferedEvents.append(event)
        bufferedDeltaBytes = newDeltaByteCount
        lock.unlock()
        return true
    }

    private func waitForSpace(for event: AgentRuntimeEvent) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if canAccept(event) || isFinished || isCancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    spaceWaiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func canAccept(_ event: AgentRuntimeEvent) -> Bool {
        let deltaBytes = Self.deltaByteCount(of: event)
        let (newDeltaByteCount, byteCountOverflowed) = bufferedDeltaBytes.addingReportingOverflow(deltaBytes)
        guard !byteCountOverflowed, newDeltaByteCount <= deltaByteLimit else { return false }
        return canMergeIntoLastBufferedEvent(event) || bufferedEvents.count < eventLimit
    }

    private func mergeIntoLastBufferedEventIfPossible(_ event: AgentRuntimeEvent) -> Bool {
        guard canMergeIntoLastBufferedEvent(event) else { return false }
        guard
            case let .itemDelta(threadID, itemID, delta) = event,
            case let .itemDelta(_, _, lastDelta)? = bufferedEvents.last
        else {
            return false
        }

        bufferedEvents[bufferedEvents.count - 1] = .itemDelta(
            threadID: threadID,
            itemID: itemID,
            delta: lastDelta + delta
        )
        return true
    }

    private func canMergeIntoLastBufferedEvent(_ event: AgentRuntimeEvent) -> Bool {
        guard
            case let .itemDelta(threadID, itemID, _) = event,
            case let .itemDelta(lastThreadID, lastItemID, _)? = bufferedEvents.last,
            threadID == lastThreadID,
            itemID == lastItemID
        else {
            return false
        }
        return true
    }

    private static func deltaByteCount(of event: AgentRuntimeEvent?) -> Int {
        guard case let .itemDelta(_, _, delta) = event else { return 0 }
        return delta.utf8.count
    }

}
