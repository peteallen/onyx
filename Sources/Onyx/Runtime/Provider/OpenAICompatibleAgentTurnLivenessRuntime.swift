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

/// Returned to the caller when a provider admission completed only after the
/// private app-server lane had already been retired.  The provider operation
/// may eventually return successfully (some transports cannot be cancelled),
/// but that late result must not make Onyx clear the user's draft or queued
/// follow-up as if it were a live turn.
enum OpenAICompatibleAgentTurnLivenessError: LocalizedError, Sendable, Equatable {
    case laneRetired

    var errorDescription: String? {
        switch self {
        case .laneRetired:
            "The model stopped responding before it finished. Retry this response, or choose another model below and try again."
        }
    }
}

actor OpenAICompatibleAgentTurnLivenessRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private struct ActiveTurn: Sendable {
        let token: UUID
        let threadID: String
        /// The admission that created this turn, when its request response
        /// arrived before the lifecycle start. Keeping this link lets a
        /// terminal notification settle the right request when multiple
        /// same-thread admissions are in flight.
        var admissionToken: UUID?
        var turnID: String?
        /// Whether this active record has observed a lifecycle/progress event
        /// for its own admission. A no-ID terminal that arrives before that
        /// boundary may be a delayed duplicate from an earlier same-thread
        /// turn, so it must not consume this record.
        var sawLifecycleStart: Bool
        var watchdog: Task<Void, Never>?
        /// Unique generation for the currently armed inactivity watchdog.
        /// Cancelling a Swift task is cooperative: a callback that already
        /// woke up can still be queued on this actor after a fresh progress
        /// event re-arms the watchdog.  Validate this generation at expiry so
        /// an old callback cannot retire a healthy turn.
        var watchdogToken: UUID?
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
        /// A terminal status without a turn ID is only attributable to this
        /// admission after its lifecycle has begun.  This guard prevents a
        /// delayed terminal from an earlier same-thread turn consuming a new
        /// admission that has not emitted any start/progress event yet.
        var sawLifecycleStart: Bool
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
    /// Keep one record per accepted admission.  A thread can briefly have
    /// multiple provider requests in flight (for example a start racing a
    /// steer); keying this table by thread ID loses the later request and can
    /// leave its caller reporting success without a terminal boundary.
    private var activeTurns: [UUID: ActiveTurn] = [:]
    private var activeTurnTokensByThreadID: [String: [UUID]] = [:]
    /// Admissions are keyed by their own token.  More than one request can be
    /// suspended for a single thread (for example, a steering request racing
    /// a fresh start), so a thread-keyed dictionary would silently overwrite
    /// one request and leave its caller waiting forever.
    private var pendingAdmissions: [UUID: PendingAdmission] = [:]
    private var pendingAdmissionTokensByThreadID: [String: [UUID]] = [:]
    private var admissionSettlementWatchdogs: [UUID: Task<Void, Never>] = [:]
    /// Keep the complete unresolved-interaction set instead of a single
    /// request-to-thread lookup. A provider can ask several questions before
    /// resolving any of them, and a threadless request is a lane-wide pause
    /// rather than an interaction we can safely ignore.
    private var interactionThreads: [RuntimeRequestID: String] = [:]
    private var interactionIDsByThreadID: [String: Set<RuntimeRequestID>] = [:]
    private var globalInteractionIDs: Set<RuntimeRequestID> = []
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
    /// Admission tokens that were converted into a synthetic failure after
    /// the private lane retired.  A provider call may return after that point;
    /// this tombstone lets its caller throw instead of treating the late
    /// success as a valid turn.
    private var retiredAdmissionTokens: Set<UUID> = []
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
                finishTurnOrMarkAdmissionTerminal(threadID: threadID, finishAll: true)
            }
        case let .turnCompleted(threadID, _):
            finishTurnOrMarkAdmissionTerminal(threadID: threadID)
        case let .userInteractionRequested(interaction):
            registerInteraction(interaction)
        case let .userInteractionResolved(requestID):
            resolveInteraction(requestID)
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
        // Prefer an explicitly supplied admission token, then an existing
        // turn ID, then the oldest accepted turn without a turn ID.  This
        // keeps concurrent same-thread admissions distinct while preserving
        // the provider's usual FIFO lifecycle ordering.
        let token = admissionToken
            ?? turnID.flatMap { activeTurnToken(threadID: threadID, turnID: $0) }
            ?? (turnID == nil
                ? activeTurnTokensByThreadID[threadID]?.first
                : activeTurnTokensByThreadID[threadID]?.first(where: { token in
                    activeTurns[token]?.turnID == nil
                }))
        if let token, var turn = activeTurns[token] {
            if let turnID { turn.turnID = turnID }
            turn.sawLifecycleStart = true
            turn.isPausedForInteraction = hasUnresolvedInteraction(for: threadID)
            activeTurns[token] = turn
            if turn.isPausedForInteraction {
                cancelWatchdog(for: turn.token)
            } else {
                armWatchdog(threadID: threadID, token: turn.token)
            }
            return
        }

        // A lifecycle event can arrive before the request response that
        // admitted it. Keep the turn ID on that pending admission and wait
        // for the response before arming its activity watchdog; the bounded
        // admission watchdog still covers a request that never returns.
        if admissionToken == nil,
           let pendingToken = firstPendingAdmissionToken(
               threadID: threadID,
               withoutLifecycleStart: true
           ),
           var pending = pendingAdmissions[pendingToken] {
            if pending.turnID == nil { pending.turnID = turnID }
            pending.sawLifecycleStart = true
            pendingAdmissions[pendingToken] = pending
            return
        }

        // Events for an externally resumed turn may have no corresponding
        // admission. Keep monitoring it with a synthetic token so EOF and
        // inactivity still produce an attached failure.
        let synthetic = ActiveTurn(
            token: UUID(),
            threadID: threadID,
            admissionToken: nil,
            turnID: turnID,
            sawLifecycleStart: true,
            watchdog: nil,
            watchdogToken: nil,
            isPausedForInteraction: hasUnresolvedInteraction(for: threadID)
        )
        insertActiveTurn(synthetic)
        if !synthetic.isPausedForInteraction {
            armWatchdog(threadID: threadID, token: synthetic.token)
        }
    }

    private func activeTurnToken(threadID: String, turnID: String) -> UUID? {
        activeTurnTokensByThreadID[threadID]?.first { token in
            activeTurns[token]?.turnID == turnID
        }
    }

    private func activeTurnTokens(threadID: String) -> [UUID] {
        activeTurnTokensByThreadID[threadID]?.filter { activeTurns[$0] != nil } ?? []
    }

    private func insertActiveTurn(_ turn: ActiveTurn) {
        activeTurns[turn.token] = turn
        activeTurnTokensByThreadID[turn.threadID, default: []].append(turn.token)
    }

    @discardableResult
    private func removeActiveTurn(token: UUID) -> ActiveTurn? {
        guard let turn = activeTurns.removeValue(forKey: token) else { return nil }
        turn.watchdog?.cancel()
        if var tokens = activeTurnTokensByThreadID[turn.threadID] {
            tokens.removeAll { $0 == token }
            activeTurnTokensByThreadID[turn.threadID] = tokens.isEmpty ? nil : tokens
        }
        return turn
    }

    private func updatePendingTurnID(threadID: String, turnID: String?) {
        guard let turnID,
              let pendingToken = firstPendingAdmissionToken(threadID: threadID),
              var pending = pendingAdmissions[pendingToken],
              pending.turnID == nil else { return }
        pending.turnID = turnID
        pendingAdmissions[pendingToken] = pending
    }

    private func firstPendingAdmissionToken(
        threadID: String,
        withoutLifecycleStart: Bool = false
    ) -> UUID? {
        pendingAdmissionTokensByThreadID[threadID]?.first { token in
            guard let admission = pendingAdmissions[token] else { return false }
            return !admission.sawTerminal
                && (!withoutLifecycleStart || !admission.sawLifecycleStart)
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
            sawLifecycleStart: false,
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
        // A terminal with no matching active turn is only attributable after
        // that admission observed a lifecycle start. Otherwise it may be a
        // delayed duplicate from an earlier same-thread turn.
        for token in tokens {
            guard var admission = pendingAdmissions[token],
                  !admission.sawTerminal,
                  admission.sawLifecycleStart else {
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

    private enum AdmissionSettlement: Sendable, Equatable {
        case accepted
        case alreadyTerminal
        case laneRetired
        case callerDisconnected
    }

    private func finishAcceptedAdmission(
        threadID: String,
        token: UUID,
        turnID: String? = nil
    ) -> AdmissionSettlement {
        if disconnectGate.isRequested || retirementReason == .explicitDisconnect {
            _ = removePendingAdmission(token: token)
            return .callerDisconnected
        }
        guard var admission = pendingAdmissions[token], admission.threadID == threadID else {
            // A settlement watchdog may have already retired this request.
            // Its eventual provider response is stale and must not re-arm a
            // watchdog or publish a second failure.
            return retiredAdmissionTokens.contains(token)
                ? .laneRetired
                : .alreadyTerminal
        }
        if let turnID { admission.turnID = turnID }
        pendingAdmissions[token] = admission
        guard let settled = removePendingAdmission(token: token) else {
            return retiredAdmissionTokens.contains(token)
                ? .laneRetired
                : .alreadyTerminal
        }
        guard !settled.sawTerminal else {
            finishRetirementIfSettled()
            return .alreadyTerminal
        }
        if isRetiring || hasUpstreamEventStreamEnded {
            guard !failedTurnTokens.contains(settled.token) else {
                finishRetirementIfSettled()
                return .laneRetired
            }
            // The request was accepted, but its private event lane ended
            // before a lifecycle event could arrive. Materialize the active
            // boundary and retire it through the same user-facing failure
            // path as an already-running silent turn.
            emitTerminalFailure(
                threadID: threadID,
                turn: ActiveTurn(
                    token: token,
                    threadID: threadID,
                    admissionToken: settled.token,
                    turnID: settled.turnID,
                    sawLifecycleStart: settled.sawLifecycleStart,
                    watchdog: nil,
                    watchdogToken: nil,
                    isPausedForInteraction: false
                )
            )
            finishRetirementIfSettled()
            return .laneRetired
        }
        let acceptedTurn = ActiveTurn(
            token: settled.token,
            threadID: threadID,
            admissionToken: settled.token,
            turnID: settled.turnID ?? turnID,
            sawLifecycleStart: settled.sawLifecycleStart,
            watchdog: nil,
            watchdogToken: nil,
            isPausedForInteraction: hasUnresolvedInteraction(for: threadID)
        )
        // A lifecycle start may have created a matching active record in a
        // future adapter revision. Reuse it if present; otherwise retain one
        // independent record for this admission.
        if var existing = activeTurns[settled.token] {
            if existing.turnID == nil { existing.turnID = acceptedTurn.turnID }
            existing.isPausedForInteraction = hasUnresolvedInteraction(for: threadID)
            activeTurns[settled.token] = existing
        } else {
            insertActiveTurn(acceptedTurn)
        }
        if activeTurns[settled.token]?.isPausedForInteraction == true {
            cancelWatchdog(for: settled.token)
        } else {
            armWatchdog(threadID: threadID, token: settled.token)
        }
        return .accepted
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
        for token in activeTurnTokens(threadID: threadID) {
            guard let turn = activeTurns[token], !turn.isPausedForInteraction else { continue }
            armWatchdog(threadID: threadID, token: turn.token)
        }
    }

    private func hasUnresolvedInteraction(for threadID: String) -> Bool {
        !globalInteractionIDs.isEmpty
            || !(interactionIDsByThreadID[threadID]?.isEmpty ?? true)
    }

    /// Cancels the current watchdog and invalidates any callback that may
    /// already be queued on the actor executor.
    private func cancelWatchdog(for token: UUID) {
        guard var turn = activeTurns[token] else { return }
        turn.watchdog?.cancel()
        turn.watchdog = nil
        turn.watchdogToken = nil
        activeTurns[token] = turn
    }

    private func registerInteraction(_ interaction: RuntimeUserInteraction) {
        // A raw provider request ID can be reused. Remove an older mapping
        // before inserting the new request so one resolution cannot leave a
        // stale count that pauses every later turn forever.
        removeInteractionTracking(for: interaction.id)
        if let threadID = interaction.threadID {
            interactionThreads[interaction.id] = threadID
            interactionIDsByThreadID[threadID, default: []].insert(interaction.id)
            pauseTurn(threadID: threadID)
        } else {
            globalInteractionIDs.insert(interaction.id)
            pauseAllTurns()
        }
    }

    private func resolveInteraction(_ requestID: RuntimeRequestID) {
        if let threadID = interactionThreads.removeValue(forKey: requestID) {
            interactionIDsByThreadID[threadID]?.remove(requestID)
            if interactionIDsByThreadID[threadID]?.isEmpty == true {
                interactionIDsByThreadID[threadID] = nil
            }
            if !hasUnresolvedInteraction(for: threadID) {
                resumeTurn(threadID: threadID)
            }
            return
        }

        guard globalInteractionIDs.remove(requestID) != nil else { return }
        guard globalInteractionIDs.isEmpty else { return }
        // A global prompt blocks every current and subsequently admitted
        // turn. Once the last global prompt resolves, only threads without a
        // remaining thread-specific prompt may resume.
        let threadIDs = Set(activeTurns.values.map(\.threadID))
        for threadID in threadIDs where !hasUnresolvedInteraction(for: threadID) {
            resumeTurn(threadID: threadID)
        }
    }

    @discardableResult
    private func removeInteractionTracking(for requestID: RuntimeRequestID) -> String? {
        if let threadID = interactionThreads.removeValue(forKey: requestID) {
            interactionIDsByThreadID[threadID]?.remove(requestID)
            if interactionIDsByThreadID[threadID]?.isEmpty == true {
                interactionIDsByThreadID[threadID] = nil
            }
            return threadID
        }
        globalInteractionIDs.remove(requestID)
        return nil
    }

    private func pauseAllTurns() {
        let threadIDs = Set(activeTurns.values.map(\.threadID))
        for threadID in threadIDs { pauseTurn(threadID: threadID) }
    }

    private func pauseTurn(threadID: String) {
        for token in activeTurnTokens(threadID: threadID) {
            guard var turn = activeTurns[token] else { continue }
            turn.isPausedForInteraction = true
            activeTurns[token] = turn
            cancelWatchdog(for: token)
        }
    }

    private func resumeTurn(threadID: String) {
        guard !hasUnresolvedInteraction(for: threadID) else { return }
        for token in activeTurnTokens(threadID: threadID) {
            guard var turn = activeTurns[token] else { continue }
            turn.isPausedForInteraction = false
            activeTurns[token] = turn
            armWatchdog(threadID: threadID, token: turn.token)
        }
    }

    private func armWatchdog(threadID: String, token: UUID) {
        guard var turn = activeTurns[token],
              turn.threadID == threadID,
              turn.token == token else { return }
        turn.watchdog?.cancel()
        let watchdogToken = UUID()
        let timeout = policy.inactivityTimeout
        turn.watchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.expireTurn(
                threadID: threadID,
                token: token,
                watchdogToken: watchdogToken
            )
        }
        turn.watchdogToken = watchdogToken
        activeTurns[token] = turn
    }

    private func finishTurn(threadID: String) {
        let tokens = activeTurnTokens(threadID: threadID)
        for token in tokens {
            guard let turn = removeActiveTurn(token: token) else { continue }
            if let admissionToken = turn.admissionToken,
               var admission = pendingAdmissions[admissionToken] {
                admission.sawTerminal = true
                pendingAdmissions[admissionToken] = admission
            }
        }
        guard activeTurnTokens(threadID: threadID).isEmpty else { return }
        clearInteractions(for: threadID)
    }

    private func finishTurnOrMarkAdmissionTerminal(
        threadID: String,
        turnID: String? = nil,
        finishAll: Bool = false
    ) {
        let tokens: [UUID]
        if finishAll {
            // A thread-level idle/failed status is only attributable to
            // active records that have observed this turn's lifecycle. Keep
            // newly admitted, not-yet-started records alive for their own
            // admission/idle watchdog instead of consuming a delayed status
            // from the previous same-thread turn.
            tokens = activeTurnTokens(threadID: threadID).filter {
                activeTurns[$0]?.sawLifecycleStart == true
            }
        } else if let turnID,
                  let token = activeTurnToken(threadID: threadID, turnID: turnID) {
            tokens = [token]
        } else if let token = activeTurnTokens(threadID: threadID).first(where: {
            activeTurns[$0]?.sawLifecycleStart == true
        }) {
            tokens = [token]
        } else {
            markAdmissionTerminal(threadID: threadID)
            return
        }
        for token in tokens {
            guard let turn = removeActiveTurn(token: token) else { continue }
            if let admissionToken = turn.admissionToken,
               var admission = pendingAdmissions[admissionToken] {
                admission.sawTerminal = true
                pendingAdmissions[admissionToken] = admission
            }
        }
        if activeTurnTokens(threadID: threadID).isEmpty {
            clearInteractions(for: threadID)
        }
    }

    private func cancelActiveTurns() {
        for turn in activeTurns.values { turn.watchdog?.cancel() }
        activeTurns.removeAll()
        activeTurnTokensByThreadID.removeAll()
        clearAllInteractionTracking()
    }

    private func clearInteractions(for threadID: String) {
        guard let IDs = interactionIDsByThreadID.removeValue(forKey: threadID) else {
            return
        }
        for ID in IDs { interactionThreads.removeValue(forKey: ID) }
    }

    private func clearAllInteractionTracking() {
        interactionThreads.removeAll()
        interactionIDsByThreadID.removeAll()
        globalInteractionIDs.removeAll()
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
                    threadID: admission.threadID,
                    admissionToken: admission.token,
                    turnID: admission.turnID,
                    sawLifecycleStart: admission.sawLifecycleStart,
                    watchdog: nil,
                    watchdogToken: nil,
                    isPausedForInteraction: false
                )
            )
        }
        finishRetirementIfSettled()
    }

    private func expireTurn(
        threadID: String,
        token: UUID,
        watchdogToken: UUID
    ) {
        guard !disconnectGate.isRequested,
              let turn = activeTurns[token],
              turn.threadID == threadID,
              turn.watchdogToken == watchdogToken,
              !turn.isPausedForInteraction else { return }
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

        for turn in failures.values.sorted(by: { $0.token.uuidString < $1.token.uuidString }) {
            let threadID = turn.threadID
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
        if let admissionToken = turn.admissionToken {
            retiredAdmissionTokens.insert(admissionToken)
        }
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
            let settlement = finishAcceptedAdmission(
                threadID: request.threadID,
                token: admission
            )
            if settlement == .laneRetired {
                throw OpenAICompatibleAgentTurnLivenessError.laneRetired
            }
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
            let settlement = finishAcceptedAdmission(
                threadID: request.threadID,
                token: admission,
                turnID: run.turnID
            )
            if settlement == .laneRetired {
                throw OpenAICompatibleAgentTurnLivenessError.laneRetired
            }
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
            let settlement = finishAcceptedAdmission(threadID: threadID, token: admission)
            if settlement == .laneRetired {
                throw OpenAICompatibleAgentTurnLivenessError.laneRetired
            }
        } catch {
            finishRejectedAdmission(threadID: threadID, token: admission)
            throw error
        }
    }

    func steer(threadID: String, inputs: [RuntimeTurnInput]) async throws {
        let admission = try beginAdmission(threadID: threadID)
        do {
            try await runtime.steer(threadID: threadID, inputs: inputs)
            let settlement = finishAcceptedAdmission(threadID: threadID, token: admission)
            if settlement == .laneRetired {
                throw OpenAICompatibleAgentTurnLivenessError.laneRetired
            }
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
        // Keep the turn paused until the provider's lifecycle stream confirms
        // `userInteractionResolved`. A successful response RPC only means the
        // answer was accepted; the model may still be processing it, and
        // resuming here can let a queued watchdog expire that same turn.
        try await runtime.respond(to: interactionID, with: response)
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
