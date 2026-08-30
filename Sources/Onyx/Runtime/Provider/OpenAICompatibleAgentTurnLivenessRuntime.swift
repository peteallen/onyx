import Foundation

/// A caller can request shutdown while this actor is busy settling a provider
/// admission.  Keep that intent outside the actor so a watchdog or queued
/// connection event cannot turn an ordinary app shutdown into a task failure
/// before the actor gets a chance to run `disconnect`.
private final class OpenAICompatibleDisconnectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

/// Bounds a private OpenAI-compatible app-server turn after the provider has
/// accepted it but stops producing lifecycle events. The ordinary Codex
/// runtime remains authoritative while it is making progress; this wrapper
/// only supplies the missing terminal boundary that prevents an Onyx task
/// from remaining `Working` forever after a malformed or stalled stream.
struct OpenAICompatibleAgentTurnLivenessPolicy: Sendable, Equatable {
    let inactivityTimeout: Duration
    /// Bounds the window in which a provider request may remain suspended,
    /// both while its lane is healthy and while that lane is being retired.
    /// A provider that never resumes must not keep Onyx's public event stream
    /// (and therefore a task row) alive forever.
    let admissionSettlementTimeout: Duration

    init(
        inactivityTimeout: Duration = .seconds(300),
        admissionSettlementTimeout: Duration = .seconds(15)
    ) {
        self.inactivityTimeout = max(.milliseconds(50), inactivityTimeout)
        self.admissionSettlementTimeout = max(
            .milliseconds(50),
            admissionSettlementTimeout
        )
    }

    static let production = OpenAICompatibleAgentTurnLivenessPolicy()
}

actor OpenAICompatibleAgentTurnLivenessRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private struct ActiveTurn: Sendable {
        let token: UUID
        /// The admission that created this turn, when its request response
        /// arrived before the lifecycle start. Keeping this link lets a
        /// terminal notification settle the right request when multiple
        /// same-thread admissions are in flight.
        var admissionToken: UUID?
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
        let threadID: String
        var turnID: String?
        var sawTerminal: Bool
    }

    private enum RetirementReason: Sendable, Equatable {
        case unexpected
        case explicitDisconnect
    }

    private static let failureTitle = "Model stopped responding"
    private static let failureDetail =
        "The model stopped responding before it finished. Retry this response, or choose another model below and try again."

    private let runtime: any AgentRuntime
    private let policy: OpenAICompatibleAgentTurnLivenessPolicy
    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    /// This is intentionally nonisolated: `disconnect()` marks it before
    /// hopping back to the actor, giving explicit shutdown precedence over a
    /// watchdog callback that is already queued on the actor executor.
    private nonisolated let disconnectGate = OpenAICompatibleDisconnectGate()
    private var eventPump: Task<Void, Never>?
    private var activeTurns: [String: ActiveTurn] = [:]
    /// Admissions are keyed by their own token.  More than one request can be
    /// suspended for a single thread (for example, a steering request racing
    /// a fresh start), so a thread-keyed dictionary would silently overwrite
    /// one request and leave its caller waiting forever.
    private var pendingAdmissions: [UUID: PendingAdmission] = [:]
    private var pendingAdmissionTokensByThreadID: [String: [UUID]] = [:]
    private var admissionSettlementWatchdogs: [UUID: Task<Void, Never>] = [:]
    private var interactionThreads: [RuntimeRequestID: String] = [:]
    /// The upstream stream can terminate in the small interval between an
    /// accepted start request and the request method returning. Keep this
    /// state separate from `isRetiring`: the wrapper must leave its own
    /// stream open until that admission resolves, otherwise a later
    /// watchdog failure has nowhere to publish its recovery events.
    private var hasUpstreamEventStreamEnded = false
    private var isRetiring = false
    private var retirementReason: RetirementReason?
    private var pendingTerminalConnectionState: RuntimeConnectionState?
    private var failedTurnTokens: Set<UUID> = []
    private var terminalConnectionEventEmitted = false
    private var outputStreamFinished = false

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
        for watchdog in admissionSettlementWatchdogs.values { watchdog.cancel() }
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
        if disconnectGate.isRequested {
            // Every event is stale after caller-owned shutdown. The actor-side
            // disconnect cleanup owns stream completion; do not let an
            // upstream terminal event finish it out from under that cleanup.
            return
        }
        // A connection terminal is itself the retirement signal for the
        // private lane.  Do this before the normal `isRetiring` guard so the
        // first terminal is retained and delivered only after all requests
        // that crossed admission have settled.
        switch event {
        case let .connectionChanged(.failed(detail)):
            receiveUnexpectedConnectionTerminal(.failed(detail))
            return
        case .connectionChanged(.disconnected):
            receiveUnexpectedConnectionTerminal(.disconnected)
            return
        default:
            break
        }

        guard !isRetiring else {
            // A late lifecycle terminal can still correspond to an accepted
            // request whose response raced the connection boundary.  Record
            // it for admission settlement, but never forward stale events
            // after a lane has been retired.
            switch event {
            case let .threadStatusChanged(threadID, status)
                where status == .idle || status == .failed || status == .unknown:
                finishTurnOrMarkAdmissionTerminal(threadID: threadID)
            case let .turnCompleted(threadID, _):
                finishTurnOrMarkAdmissionTerminal(threadID: threadID)
            default:
                break
            }
            return
        }

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
                finishTurnOrMarkAdmissionTerminal(threadID: threadID)
            }
        case let .turnCompleted(threadID, _):
            finishTurnOrMarkAdmissionTerminal(threadID: threadID)
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
        default:
            break
        }

        eventContinuation.yield(event)
    }

    /// Handles a terminal connection notification from the upstream lane.
    /// The notification is held until every already-admitted request has
    /// either returned, rejected, or crossed the bounded settlement deadline.
    /// This prevents the adaptive facade from tearing down the wrapper while
    /// a provider request is still deciding whether it was accepted.
    private func receiveUnexpectedConnectionTerminal(_ state: RuntimeConnectionState) {
        guard !outputStreamFinished else { return }
        if disconnectGate.isRequested || retirementReason == .explicitDisconnect {
            // Explicit caller shutdown is quiet and must not be converted into
            // a synthetic task failure. The owning facade emits its own
            // disconnected boundary; discard any late upstream terminal here.
            return
        }
        beginUnexpectedRetirement(terminalState: state)
    }

    private func beginOrTouchTurn(
        threadID: String,
        turnID: String?,
        admissionToken: UUID? = nil
    ) {
        guard !isRetiring else { return }
        if var turn = activeTurns[threadID] {
            if turn.admissionToken == nil {
                turn.admissionToken = admissionToken ?? firstPendingAdmissionToken(threadID: threadID)
            }
            if let turnID { turn.turnID = turnID }
            turn.isPausedForInteraction = false
            activeTurns[threadID] = turn
            armWatchdog(threadID: threadID, token: turn.token)
            return
        }
        let turn = ActiveTurn(
            token: UUID(),
            admissionToken: admissionToken ?? firstPendingAdmissionToken(threadID: threadID),
            turnID: turnID,
            watchdog: nil,
            isPausedForInteraction: false
        )
        activeTurns[threadID] = turn
        armWatchdog(threadID: threadID, token: turn.token)
    }

    private func firstPendingAdmissionToken(threadID: String) -> UUID? {
        pendingAdmissionTokensByThreadID[threadID]?.first { token in
            guard let admission = pendingAdmissions[token] else { return false }
            return !admission.sawTerminal
        }
    }

    private func beginAdmission(threadID: String) throws -> UUID {
        guard !disconnectGate.isRequested,
              !isRetiring,
              retirementReason == nil,
              !hasUpstreamEventStreamEnded,
              !outputStreamFinished else {
            throw AgentRuntimeError.runtimeStateUnavailable(Self.failureDetail)
        }
        let token = UUID()
        pendingAdmissions[token] = PendingAdmission(
            token: token,
            threadID: threadID,
            turnID: nil,
            sawTerminal: false
        )
        pendingAdmissionTokensByThreadID[threadID, default: []].append(token)
        // A request that never returns is itself a broken admission even if
        // the upstream event stream stays open. Start the same bounded timer
        // used during lane retirement; a normal response cancels it when the
        // admission settles.
        armAdmissionSettlementWatchdog(for: token)
        return token
    }

    private func markAdmissionTerminal(threadID: String) {
        guard let tokens = pendingAdmissionTokensByThreadID[threadID] else { return }
        // Lifecycle notifications do not carry the request token. Consume
        // them in admission order so concurrent same-thread starts/steers do
        // not overwrite one another or both claim the same terminal event.
        for token in tokens {
            guard var admission = pendingAdmissions[token], !admission.sawTerminal else {
                continue
            }
            admission.sawTerminal = true
            pendingAdmissions[token] = admission
            return
        }
    }

    private func removePendingAdmission(token: UUID) -> PendingAdmission? {
        guard let admission = pendingAdmissions.removeValue(forKey: token) else {
            return nil
        }
        admissionSettlementWatchdogs.removeValue(forKey: token)?.cancel()
        if var tokens = pendingAdmissionTokensByThreadID[admission.threadID] {
            tokens.removeAll { $0 == token }
            if tokens.isEmpty {
                pendingAdmissionTokensByThreadID[admission.threadID] = nil
            } else {
                pendingAdmissionTokensByThreadID[admission.threadID] = tokens
            }
        }
        return admission
    }

    private func finishAcceptedAdmission(
        threadID: String,
        token: UUID,
        turnID: String? = nil
    ) {
        if disconnectGate.isRequested || retirementReason == .explicitDisconnect {
            _ = removePendingAdmission(token: token)
            return
        }
        guard var admission = pendingAdmissions[token], admission.threadID == threadID else {
            // A settlement watchdog may have already retired this request.
            // Its eventual provider response is stale and must not re-arm a
            // watchdog or publish a second failure.
            return
        }
        if let turnID { admission.turnID = turnID }
        pendingAdmissions[token] = admission
        guard let settled = removePendingAdmission(token: token) else { return }
        guard !settled.sawTerminal else {
            finishRetirementIfSettled()
            return
        }
        if isRetiring || hasUpstreamEventStreamEnded {
            guard !failedTurnTokens.contains(settled.token) else {
                finishRetirementIfSettled()
                return
            }
            // The request was accepted, but its private event lane ended
            // before a lifecycle event could arrive. Materialize the active
            // boundary and retire it through the same user-facing failure
            // path as an already-running silent turn.
            emitTerminalFailure(
                threadID: threadID,
                turn: ActiveTurn(
                    token: token,
                    admissionToken: settled.token,
                    turnID: settled.turnID,
                    watchdog: nil,
                    isPausedForInteraction: false
                )
            )
            finishRetirementIfSettled()
            return
        }
        beginOrTouchTurn(
            threadID: threadID,
            turnID: turnID,
            admissionToken: settled.token
        )
    }

    private func finishRejectedAdmission(threadID: String, token: UUID) {
        guard pendingAdmissions[token]?.threadID == threadID else { return }
        _ = removePendingAdmission(token: token)
        guard !disconnectGate.isRequested,
              retirementReason != .explicitDisconnect else { return }
        finishRetirementIfSettled()
    }

    private func finishRetirementIfSettled() {
        guard !disconnectGate.isRequested,
              retirementReason == .unexpected,
              isRetiring,
              pendingAdmissions.isEmpty else { return }
        guard !terminalConnectionEventEmitted else {
            finishOutputStreamIfNeeded()
            return
        }
        // The adaptive facade treats this terminal private-lane event as the
        // handoff to a fresh app-server/proxy pair. Delay it until every
        // already-admitted request has reported acceptance or rejection. If
        // EOF was the only signal, synthesize exactly one friendly failure;
        // this remains necessary even when every pending request rejects.
        terminalConnectionEventEmitted = true
        eventContinuation.yield(
            .connectionChanged(
                pendingTerminalConnectionState
                    ?? .failed(Self.failureDetail)
            )
        )
        finishOutputStreamIfNeeded()
    }

    private func finishOutputStreamIfNeeded() {
        guard !outputStreamFinished else { return }
        for watchdog in admissionSettlementWatchdogs.values { watchdog.cancel() }
        admissionSettlementWatchdogs.removeAll()
        // There is no useful work left on the abandoned upstream lane. Stop
        // its pump as well as our public continuation; otherwise an endpoint
        // whose stream remains open after a terminal failure would retain the
        // wrapper indefinitely.
        eventPump?.cancel()
        outputStreamFinished = true
        eventContinuation.finish()
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
        if let admissionToken = turn.admissionToken,
           var admission = pendingAdmissions[admissionToken] {
            admission.sawTerminal = true
            pendingAdmissions[admissionToken] = admission
        } else if turn.admissionToken == nil {
            markAdmissionTerminal(threadID: threadID)
        }
        interactionThreads = interactionThreads.filter { $0.value != threadID }
    }

    private func finishTurnOrMarkAdmissionTerminal(threadID: String) {
        guard activeTurns[threadID] != nil else {
            markAdmissionTerminal(threadID: threadID)
            return
        }
        finishTurn(threadID: threadID)
    }

    private func cancelActiveTurns() {
        for turn in activeTurns.values { turn.watchdog?.cancel() }
        activeTurns.removeAll()
        interactionThreads.removeAll()
    }

    private func cancelPendingAdmissions() {
        for watchdog in admissionSettlementWatchdogs.values { watchdog.cancel() }
        admissionSettlementWatchdogs.removeAll()
        pendingAdmissions.removeAll()
        pendingAdmissionTokensByThreadID.removeAll()
    }

    /// Starts the one-way retirement of an unexpectedly dead private lane.
    /// Existing admissions stay in the token table until their provider call
    /// returns or the bounded settlement watchdog expires.  The connection
    /// terminal is queued so consumers cannot tear down the lane before that
    /// bookkeeping is complete.
    private func beginUnexpectedRetirement(
        terminalState: RuntimeConnectionState? = nil
    ) {
        guard !outputStreamFinished,
              !disconnectGate.isRequested,
              retirementReason != .explicitDisconnect else { return }
        if retirementReason == nil {
            retirementReason = .unexpected
        }
        isRetiring = true
        if let terminalState, pendingTerminalConnectionState == nil {
            pendingTerminalConnectionState = terminalState
        }
        failActiveTurnsAndRetireLane()
        armAdmissionSettlementWatchdogs()
        finishRetirementIfSettled()
    }

    private func armAdmissionSettlementWatchdogs() {
        guard retirementReason != .explicitDisconnect,
              !outputStreamFinished else { return }
        for token in pendingAdmissions.keys where admissionSettlementWatchdogs[token] == nil {
            armAdmissionSettlementWatchdog(for: token)
        }
    }

    private func armAdmissionSettlementWatchdog(for token: UUID) {
        guard admissionSettlementWatchdogs[token] == nil,
              !outputStreamFinished else { return }
        let timeout = policy.admissionSettlementTimeout
        admissionSettlementWatchdogs[token] = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.expirePendingAdmission(token: token)
        }
    }

    private func expirePendingAdmission(token: UUID) {
        guard pendingAdmissions[token] != nil else { return }
        guard !disconnectGate.isRequested,
              retirementReason != .explicitDisconnect else {
            _ = removePendingAdmission(token: token)
            return
        }
        // A request that remains unresolved on a live stream is just as
        // unsafe as one that races EOF. Retire the lane first so all sibling
        // turns are fenced, then settle this admission below.
        if retirementReason == nil {
            beginUnexpectedRetirement()
        }
        guard let admission = removePendingAdmission(token: token) else { return }
        // We cannot know whether a non-cooperative provider call was accepted
        // once its lane has ended. Treat that ambiguity as an accepted turn so
        // the user receives one attached failure rather than an indefinitely
        // working task. A lifecycle terminal already observed is authoritative
        // and needs no synthetic duplicate.
        if !admission.sawTerminal,
           !failedTurnTokens.contains(admission.token) {
            emitTerminalFailure(
                threadID: admission.threadID,
                turn: ActiveTurn(
                    token: admission.token,
                    admissionToken: admission.token,
                    turnID: admission.turnID,
                    watchdog: nil,
                    isPausedForInteraction: false
                )
            )
        }
        finishRetirementIfSettled()
    }

    private func expireTurn(threadID: String, token: UUID) {
        guard !disconnectGate.isRequested,
              activeTurns[threadID]?.token == token else { return }
        beginUnexpectedRetirement()
    }

    private func upstreamEventStreamEnded() {
        hasUpstreamEventStreamEnded = true
        guard !outputStreamFinished else { return }
        if disconnectGate.isRequested || retirementReason == .explicitDisconnect {
            return
        }
        beginUnexpectedRetirement()
    }

    /// A private app-server runtime is shared by the provider's agent tasks.
    /// Once one accepted turn loses its event stream, retire that entire lane:
    /// it prevents late events from the abandoned response from completing a
    /// later Retry, and the adaptive facade will create a clean app-server and
    /// proxy for the next attempt.
    private func failActiveTurnsAndRetireLane() {
        guard !outputStreamFinished,
              !disconnectGate.isRequested,
              retirementReason != .explicitDisconnect else { return }
        isRetiring = true
        let failures = activeTurns
        cancelActiveTurns()

        for threadID in failures.keys.sorted() {
            guard let turn = failures[threadID] else { continue }
            // A lifecycle start observed before the request response belongs
            // to this same pending admission. Mark it terminal before the
            // response returns so it cannot receive a duplicate synthetic
            // failure during admission settlement.
            if let admissionToken = turn.admissionToken,
               var admission = pendingAdmissions[admissionToken] {
                admission.sawTerminal = true
                pendingAdmissions[admissionToken] = admission
            } else if turn.admissionToken == nil {
                markAdmissionTerminal(threadID: threadID)
            }
            emitTerminalFailure(threadID: threadID, turn: turn)
        }

        finishRetirementIfSettled()
    }

    private func emitTerminalFailure(threadID: String, turn: ActiveTurn) {
        guard !disconnectGate.isRequested,
              retirementReason != .explicitDisconnect,
              !failedTurnTokens.contains(turn.token) else { return }
        failedTurnTokens.insert(turn.token)
        // A few compatible app-server/provider combinations accept a turn
        // and emit progress without ever publishing `turnStarted`. The app
        // model needs a real turn boundary to attach the optimistic user
        // message and this terminal failure to the same failed turn.
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

    /// Deterministic lifecycle seam for the suspended-admission regressions.
    /// It exposes no provider data and is internal to the Onyx module.
    func hasObservedUpstreamEventStreamEndForTesting() -> Bool {
        hasUpstreamEventStreamEnded
    }

    func hasBegunRetirementForTesting() -> Bool {
        retirementReason != nil
    }

    func connect() async throws -> RuntimeSession {
        ensureEventPump()
        return try await runtime.connect()
    }

    nonisolated func disconnect() async {
        // Mark caller intent before the actor hop. This tiny synchronous
        // section is what makes explicit shutdown win a queued watchdog/EOF
        // race on a busy hosted runner.
        disconnectGate.request()
        await disconnectOnActor()
    }

    private func disconnectOnActor() async {
        // Caller-initiated shutdown is a different boundary from an
        // unexpected provider failure.  Cancel every local watchdog and drop
        // pending admissions so a normal window close cannot manufacture a
        // task error or hold the stream open waiting for a provider call.
        retirementReason = .explicitDisconnect
        isRetiring = true
        cancelActiveTurns()
        cancelPendingAdmissions()
        pendingTerminalConnectionState = nil
        await runtime.disconnect()
        finishOutputStreamIfNeeded()
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
        let admission = try beginAdmission(threadID: request.threadID)
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
        let admission = try beginAdmission(threadID: request.threadID)
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
        let admission = try beginAdmission(threadID: threadID)
        do {
            try await runtime.steer(threadID: threadID, text: text)
            finishAcceptedAdmission(threadID: threadID, token: admission)
        } catch {
            finishRejectedAdmission(threadID: threadID, token: admission)
            throw error
        }
    }

    func steer(threadID: String, inputs: [RuntimeTurnInput]) async throws {
        let admission = try beginAdmission(threadID: threadID)
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
