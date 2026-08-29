import Foundation

/// Bounds a private OpenAI-compatible app-server turn after the provider has
/// accepted it but stops producing lifecycle events. The ordinary Codex
/// runtime remains authoritative while it is making progress; this wrapper
/// only supplies the missing terminal boundary that prevents an Onyx task
/// from remaining `Working` forever after a malformed or stalled stream.
struct OpenAICompatibleAgentTurnLivenessPolicy: Sendable, Equatable {
    let inactivityTimeout: Duration

    init(inactivityTimeout: Duration = .seconds(300)) {
        self.inactivityTimeout = max(.milliseconds(50), inactivityTimeout)
    }

    static let production = OpenAICompatibleAgentTurnLivenessPolicy()
}

actor OpenAICompatibleAgentTurnLivenessRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private struct ActiveTurn: Sendable {
        let token: UUID
        var turnID: String?
        var watchdog: Task<Void, Never>?
        var isPausedForInteraction: Bool
    }

    /// App-server notifications can arrive before the request response that
    /// accepted the same turn. Remember that race so a synchronous terminal
    /// notification cannot be followed by the request completion re-arming a
    /// watchdog for work that already finished.
    private struct PendingAdmission: Sendable {
        let token: UUID
        var sawTerminal: Bool
    }

    private static let failureTitle = "Model stopped responding"
    private static let failureDetail =
        "The model stopped responding before it finished. Retry this response, or choose another model below and try again."

    private let runtime: any AgentRuntime
    private let policy: OpenAICompatibleAgentTurnLivenessPolicy
    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private var eventPump: Task<Void, Never>?
    private var activeTurns: [String: ActiveTurn] = [:]
    private var pendingAdmissions: [String: PendingAdmission] = [:]
    private var interactionThreads: [RuntimeRequestID: String] = [:]
    private var isRetiring = false

    init(
        runtime: any AgentRuntime,
        policy: OpenAICompatibleAgentTurnLivenessPolicy = .production
    ) {
        self.runtime = runtime
        self.policy = policy
        kind = runtime.kind
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        eventPump?.cancel()
        for turn in activeTurns.values { turn.watchdog?.cancel() }
        eventContinuation.finish()
    }

    private func ensureEventPump() {
        guard eventPump == nil else { return }
        let upstreamEvents = runtime.events
        eventPump = Task { [weak self] in
            for await event in upstreamEvents {
                guard !Task.isCancelled, let self else { return }
                await self.receive(event)
            }
            guard !Task.isCancelled, let self else { return }
            await self.upstreamEventStreamEnded()
        }
    }

    private func receive(_ event: AgentRuntimeEvent) {
        guard !isRetiring else { return }

        switch event {
        case let .turnStarted(threadID, turnID):
            beginOrTouchTurn(threadID: threadID, turnID: turnID)
        case let .itemStarted(threadID, _),
             let .itemDelta(threadID, _, _),
             let .itemCompleted(threadID, _),
             let .planUpdated(threadID, _):
            touchTurn(threadID: threadID)
        case let .threadStatusChanged(threadID, status):
            switch status {
            case .running:
                beginOrTouchTurn(threadID: threadID, turnID: nil)
            case .waitingForInput, .waitingForApproval:
                pauseTurn(threadID: threadID)
            case .idle, .failed, .unknown:
                markAdmissionTerminal(threadID: threadID)
                finishTurn(threadID: threadID)
            }
        case let .turnCompleted(threadID, _):
            markAdmissionTerminal(threadID: threadID)
            finishTurn(threadID: threadID)
        case let .userInteractionRequested(interaction):
            if let threadID = interaction.threadID {
                interactionThreads[interaction.id] = threadID
                pauseTurn(threadID: threadID)
            }
        case let .userInteractionResolved(requestID):
            if let threadID = interactionThreads.removeValue(forKey: requestID) {
                resumeTurn(threadID: threadID)
            }
        case let .threadArchived(threadID),
             let .threadDeleted(threadID):
            finishTurn(threadID: threadID)
        case .connectionChanged(.failed), .connectionChanged(.disconnected):
            cancelAllWatchdogs()
        default:
            break
        }

        eventContinuation.yield(event)
    }

    private func beginOrTouchTurn(threadID: String, turnID: String?) {
        guard !isRetiring else { return }
        if var turn = activeTurns[threadID] {
            if let turnID { turn.turnID = turnID }
            turn.isPausedForInteraction = false
            activeTurns[threadID] = turn
            armWatchdog(threadID: threadID, token: turn.token)
            return
        }
        let turn = ActiveTurn(
            token: UUID(),
            turnID: turnID,
            watchdog: nil,
            isPausedForInteraction: false
        )
        activeTurns[threadID] = turn
        armWatchdog(threadID: threadID, token: turn.token)
    }

    private func beginAdmission(threadID: String) -> UUID {
        let token = UUID()
        pendingAdmissions[threadID] = PendingAdmission(
            token: token,
            sawTerminal: false
        )
        return token
    }

    private func markAdmissionTerminal(threadID: String) {
        guard var admission = pendingAdmissions[threadID] else { return }
        admission.sawTerminal = true
        pendingAdmissions[threadID] = admission
    }

    private func finishAcceptedAdmission(
        threadID: String,
        token: UUID,
        turnID: String? = nil
    ) {
        guard let admission = pendingAdmissions[threadID], admission.token == token else { return }
        pendingAdmissions[threadID] = nil
        guard !admission.sawTerminal else { return }
        beginOrTouchTurn(threadID: threadID, turnID: turnID)
    }

    private func finishRejectedAdmission(threadID: String, token: UUID) {
        guard pendingAdmissions[threadID]?.token == token else { return }
        pendingAdmissions[threadID] = nil
    }

    private func touchTurn(threadID: String) {
        guard let turn = activeTurns[threadID], !turn.isPausedForInteraction else { return }
        armWatchdog(threadID: threadID, token: turn.token)
    }

    private func pauseTurn(threadID: String) {
        guard var turn = activeTurns[threadID] else { return }
        turn.watchdog?.cancel()
        turn.watchdog = nil
        turn.isPausedForInteraction = true
        activeTurns[threadID] = turn
    }

    private func resumeTurn(threadID: String) {
        guard var turn = activeTurns[threadID] else { return }
        turn.isPausedForInteraction = false
        activeTurns[threadID] = turn
        armWatchdog(threadID: threadID, token: turn.token)
    }

    private func armWatchdog(threadID: String, token: UUID) {
        guard var turn = activeTurns[threadID], turn.token == token else { return }
        turn.watchdog?.cancel()
        let timeout = policy.inactivityTimeout
        turn.watchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.expireTurn(threadID: threadID, token: token)
        }
        activeTurns[threadID] = turn
    }

    private func finishTurn(threadID: String) {
        guard let turn = activeTurns.removeValue(forKey: threadID) else { return }
        turn.watchdog?.cancel()
        interactionThreads = interactionThreads.filter { $0.value != threadID }
    }

    private func cancelAllWatchdogs() {
        for turn in activeTurns.values { turn.watchdog?.cancel() }
        activeTurns.removeAll()
        pendingAdmissions.removeAll()
        interactionThreads.removeAll()
    }

    private func expireTurn(threadID: String, token: UUID) {
        guard activeTurns[threadID]?.token == token else { return }
        failActiveTurnsAndRetireLane()
    }

    private func upstreamEventStreamEnded() {
        guard !activeTurns.isEmpty, !isRetiring else {
            eventContinuation.finish()
            return
        }
        failActiveTurnsAndRetireLane()
        eventContinuation.finish()
    }

    /// A private app-server runtime is shared by the provider's agent tasks.
    /// Once one accepted turn loses its event stream, retire that entire lane:
    /// it prevents late events from the abandoned response from completing a
    /// later Retry, and the adaptive facade will create a clean app-server and
    /// proxy for the next attempt.
    private func failActiveTurnsAndRetireLane() {
        guard !isRetiring else { return }
        isRetiring = true
        let failures = activeTurns
        cancelAllWatchdogs()

        for (threadID, turn) in failures {
            // A few compatible app-server/provider combinations accept a turn
            // and emit progress without ever publishing `turnStarted`.  The
            // app model needs a real turn boundary to attach the optimistic
            // user message and this terminal failure to the same failed turn;
            // otherwise the task stops, but its visible Retry action has no
            // provider-history boundary to target.
            if turn.turnID == nil {
                eventContinuation.yield(
                    .turnStarted(
                        threadID: threadID,
                        turnID: "onyx-provider-liveness-turn:\(turn.token.uuidString)"
                    )
                )
            }
            let item = TimelineItem(
                id: "onyx-provider-liveness:\(turn.turnID ?? turn.token.uuidString)",
                kind: .error,
                title: Self.failureTitle,
                body: Self.failureDetail,
                status: .failed,
                timestamp: .now,
                detail: nil
            )
            eventContinuation.yield(.itemCompleted(threadID: threadID, item: item))
            eventContinuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
            eventContinuation.yield(.turnCompleted(threadID: threadID, status: .failed))
        }

        // The adaptive facade treats a terminal private-lane connection event
        // as a request to stop its proxy/runtime pair. It deliberately keeps
        // the provider's public connection and other chat tasks available.
        eventContinuation.yield(
            .connectionChanged(.failed(Self.failureDetail))
        )
    }

    func connect() async throws -> RuntimeSession {
        ensureEventPump()
        return try await runtime.connect()
    }

    func disconnect() async {
        cancelAllWatchdogs()
        isRetiring = true
        await runtime.disconnect()
    }

    func startLogin(methodID: String) async throws -> RuntimeLoginStart {
        try await runtime.startLogin(methodID: methodID)
    }

    func cancelLogin(id: String) async throws {
        try await runtime.cancelLogin(id: id)
    }

    func logout() async throws {
        try await runtime.logout()
    }

    func refreshAccount() async throws -> RuntimeSession {
        try await runtime.refreshAccount()
    }

    func listThreads(limit: Int, archived: Bool) async throws -> [RuntimeThread] {
        try await runtime.listThreads(limit: limit, archived: archived)
    }

    func listAllThreads(archived: Bool) async throws -> [RuntimeThread] {
        try await runtime.listAllThreads(archived: archived)
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        try await runtime.readThread(id: id)
    }

    func readThread(
        id: String,
        initialHistoryPage: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        try await runtime.readThread(id: id, initialHistoryPage: initialHistoryPage)
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await runtime.resumeThread(id: id)
    }

    func resumeThread(
        id: String,
        initialHistoryPage: RuntimeInitialThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        try await runtime.resumeThread(id: id, initialHistoryPage: initialHistoryPage)
    }

    func listThreadHistory(
        id: String,
        page: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadHistoryPage {
        try await runtime.listThreadHistory(id: id, page: page)
    }

    func revertThread(id: String, beforeTurnID: String) async throws -> RuntimeThreadRevertResult {
        try await runtime.revertThread(id: id, beforeTurnID: beforeTurnID)
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        try await runtime.startThread(request)
    }

    func forkThread(id: String) async throws -> RuntimeThread {
        try await runtime.forkThread(id: id)
    }

    func forkEphemeralThread(id: String) async throws -> RuntimeConversation {
        try await runtime.forkEphemeralThread(id: id)
    }

    func compactThread(id: String) async throws {
        try await runtime.compactThread(id: id)
    }

    func deleteThread(id: String) async throws {
        finishTurn(threadID: id)
        try await runtime.deleteThread(id: id)
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        ensureEventPump()
        let admission = beginAdmission(threadID: request.threadID)
        do {
            try await runtime.startTurn(request)
            finishAcceptedAdmission(threadID: request.threadID, token: admission)
        } catch {
            finishRejectedAdmission(threadID: request.threadID, token: admission)
            throw error
        }
    }

    func startReview(_ request: StartReviewRequest) async throws -> RuntimeReviewRun {
        ensureEventPump()
        let admission = beginAdmission(threadID: request.threadID)
        do {
            let run = try await runtime.startReview(request)
            finishAcceptedAdmission(
                threadID: request.threadID,
                token: admission,
                turnID: run.turnID
            )
            return run
        } catch {
            finishRejectedAdmission(threadID: request.threadID, token: admission)
            throw error
        }
    }

    func steer(threadID: String, text: String) async throws {
        let admission = beginAdmission(threadID: threadID)
        do {
            try await runtime.steer(threadID: threadID, text: text)
            finishAcceptedAdmission(threadID: threadID, token: admission)
        } catch {
            finishRejectedAdmission(threadID: threadID, token: admission)
            throw error
        }
    }

    func steer(threadID: String, inputs: [RuntimeTurnInput]) async throws {
        let admission = beginAdmission(threadID: threadID)
        do {
            try await runtime.steer(threadID: threadID, inputs: inputs)
            finishAcceptedAdmission(threadID: threadID, token: admission)
        } catch {
            finishRejectedAdmission(threadID: threadID, token: admission)
            throw error
        }
    }

    func interrupt(threadID: String) async throws {
        try await runtime.interrupt(threadID: threadID)
        touchTurn(threadID: threadID)
    }

    func respond(
        to interactionID: RuntimeRequestID,
        with response: RuntimeUserInteractionResponse
    ) async throws {
        let threadID = interactionThreads[interactionID]
        try await runtime.respond(to: interactionID, with: response)
        if let threadID { resumeTurn(threadID: threadID) }
    }

    func renameThread(id: String, name: String) async throws {
        try await runtime.renameThread(id: id, name: name)
    }

    func archiveThread(id: String) async throws {
        finishTurn(threadID: id)
        try await runtime.archiveThread(id: id)
    }

    func unarchiveThread(id: String) async throws {
        try await runtime.unarchiveThread(id: id)
    }
}
