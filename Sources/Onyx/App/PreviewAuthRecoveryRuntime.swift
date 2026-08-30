#if DEBUG
import Foundation

/// A deterministic, credential-free runtime used only by the canonical debug
/// preview when it is launched with `--onyx-auth-fixture=expired`.
///
/// This fixture exists so the attached account-recovery surface can be
/// exercised in a real AppKit window without revoking the developer's actual
/// ChatGPT session. It deliberately owns no files, network connections, or
/// credentials and is not compiled into release builds.
actor PreviewAuthRecoveryRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private var recoveryHasBeenScheduled = false
    private var interactionHasBeenScheduled = false
    private var loginAttempt: RuntimeLoginStart?

    init() {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        eventContinuation.finish()
    }

    func connect() async throws -> RuntimeSession {
        eventContinuation.yield(.connectionChanged(.connected("Preview account")))
        schedulePreviewActivityIfNeeded()
        return Self.session
    }

    func disconnect() async {}

    func startLogin(methodID: String) async throws -> RuntimeLoginStart {
        guard let method = Self.loginMethods.first(where: { $0.id == methodID }) else {
            throw AgentRuntimeError.unsupported("preview sign-in method")
        }
        let attempt = RuntimeLoginStart(
            method: method,
            // Give every ceremony a distinct identity so cancelling and
            // immediately retrying cannot let an older delayed completion
            // settle the newer attempt.
            loginID: "preview-login-\(UUID().uuidString)",
            // Keep the browser ceremony real enough for the visible
            // “Open Sign In” action to do something useful.  The fixture
            // never sends credentials to this URL; it only lets a tester
            // verify that the button is wired to a normal HTTPS destination.
            authURL: method.ceremony == .browser
                ? URL(string: "https://chatgpt.com/auth/login")
                : nil,
            verificationURL: method.ceremony == .deviceCode ? URL(string: "https://chatgpt.com/") : nil,
            userCode: method.ceremony == .deviceCode ? "ONYX-PREVIEW" : nil
        )
        loginAttempt = attempt
        // This credential-free fixture completes its fake ceremony locally,
        // but leaves the card up long enough for a person to inspect the
        // preserved task, draft, queued follow-up, and pending approval.  The
        // browser action above is still genuinely reopenable during that
        // window; no real credential is ever read or stored here.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self else { return }
            await self.completePreviewLogin(id: attempt.loginID)
        }
        return attempt
    }

    func cancelLogin(id: String) async throws {
        guard loginAttempt?.loginID == id else { return }
        loginAttempt = nil
    }

    func logout() async throws {}

    func refreshAccount() async throws -> RuntimeSession {
        // The fixture does not complete a real ceremony. Returning the same
        // signed-in projection keeps the card stable if a test exercises the
        // Settings surface after opening it.
        Self.session
    }

    func listThreads(limit: Int, archived: Bool) async throws -> [RuntimeThread] {
        guard !archived, limit > 0 else { return [] }
        return [Self.thread]
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        guard id == Self.thread.id else {
            throw AgentRuntimeError.missingField("preview task")
        }
        scheduleRecoveryIfNeeded()
        return Self.conversation
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await readThread(id: id)
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
    }

    func forkThread(id _: String) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("preview task forking")
    }

    func compactThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("preview task compaction")
    }

    func deleteThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("preview task deletion")
    }

    func startTurn(_: StartTurnRequest) async throws {
        throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
    }

    func startReview(_: StartReviewRequest) async throws -> RuntimeReviewRun {
        throw AgentRuntimeError.unsupported("preview code review")
    }

    func steer(threadID _: String, text _: String) async throws {
        throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
    }

    func interrupt(threadID _: String) async throws {}

    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {
        throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
    }

    func renameThread(id _: String, name _: String) async throws {
        throw AgentRuntimeError.unsupported("preview task rename")
    }

    func archiveThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("preview task archive")
    }

    func unarchiveThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("preview task restore")
    }

    private func scheduleRecoveryIfNeeded() {
        guard !recoveryHasBeenScheduled else { return }
        recoveryHasBeenScheduled = true
        // The task is already mounted at this point. Leave enough time for a
        // tester to type a draft, then expire the session in place.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self else { return }
            await self.publishRecovery()
        }
    }

    /// Adds realistic, provider-owned activity to the mounted task without
    /// touching the durable Onyx history.  The app model projects the
    /// approval as non-authorizing context once recovery begins; the seeded
    /// follow-up remains app-owned and is rendered by the queue strip.
    private func schedulePreviewActivityIfNeeded() {
        guard !interactionHasBeenScheduled else { return }
        interactionHasBeenScheduled = true
        Task { [weak self] in
            // Let the initial catalog/read settle so the activity is visible
            // on the selected task rather than racing the welcome screen.
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            eventContinuation.yield(.turnStarted(
                threadID: Self.fixtureThreadID,
                turnID: Self.fixtureTurnID
            ))
            eventContinuation.yield(.userInteractionRequested(Self.fixtureInteraction))
        }
    }

    private func publishRecovery() {
        eventContinuation.yield(.authenticationRecoveryRequired(.signInExpired))
    }

    private func completePreviewLogin(id: String) {
        guard loginAttempt?.loginID == id else { return }
        loginAttempt = nil
        eventContinuation.yield(.loginCompleted(RuntimeLoginCompletion(
            loginID: id,
            success: true,
            error: nil
        )))
    }

    private static let loginMethods: [RuntimeLoginMethod] = [
        RuntimeLoginMethod(
            id: "codex.chatgpt.browser",
            displayName: "Continue with ChatGPT",
            detail: "Sign in securely in your browser",
            ceremony: .browser
        ),
        RuntimeLoginMethod(
            id: "codex.chatgpt.device-code",
            displayName: "Use a device code",
            detail: "Enter a one-time code at OpenAI",
            ceremony: .deviceCode
        ),
    ]

    static let fixtureThreadID = "onyx-preview-auth-task"
    static let fixtureTurnID = "onyx-preview-auth-turn"
    static let fixtureComposerDraft = "Keep this draft while I sign back in"
    static let fixtureWorkspacePath = "/tmp/onyx-auth-recovery-preview"
    static let fixtureQueuedFollowUp = "Continue the current plan after sign-in"

    static let fixtureInteraction = RuntimeUserInteraction(
        id: .string("onyx-preview-approval"),
        threadID: fixtureThreadID,
        providerMethod: "preview/approval",
        title: "Approval needed",
        detail: "Review this pending command before the task continues.",
        kind: .approval(RuntimeApprovalPrompt(
            subject: .command,
            command: "git status",
            supportsSessionApproval: false
        ))
    )

    private static let model = RuntimeModel(
        id: "onyx-preview-model",
        displayName: "Preview model",
        description: "Credential-free auth recovery preview",
        isDefault: true,
        defaultReasoningEffort: nil,
        reasoningEfforts: [],
        inputModalities: [.text],
        capabilityEvidence: .advertised,
        executionMode: .inherited
    )

    private static let session = RuntimeSession(
        runtime: .codex,
        displayName: "Codex",
        accountLabel: "preview@example.com",
        planLabel: "pro",
        auth: RuntimeAuthState(
            mode: .chatgpt,
            email: "preview@example.com",
            planLabel: "pro",
            requiresAuthentication: true
        ),
        availableLoginMethods: loginMethods,
        availableModels: [model],
        capabilities: [.streaming, .steering, .approvals, .reasoning, .tools]
    )

    static let thread = RuntimeThread(
        id: fixtureThreadID,
        title: "Keep this task open",
        preview: "Your task stays here while you sign back in.",
        cwd: fixtureWorkspacePath,
        updatedAt: Date(timeIntervalSince1970: 1_787_500_000),
        status: .running,
        isPinned: false,
        runtime: .codex,
        model: model.id,
        branch: nil
    )

    private static let conversation = RuntimeConversation(
        thread: thread,
        items: [
            TimelineItem(
                id: "onyx-preview-auth-user",
                kind: .userMessage,
                title: nil,
                body: "Keep my task and draft intact while I sign back in.",
                status: .completed,
                timestamp: Date(timeIntervalSince1970: 1_787_499_940),
                detail: nil
            ),
            TimelineItem(
                id: "onyx-preview-auth-assistant",
                kind: .assistantMessage,
                title: nil,
                body: "Your work is still mounted in Onyx. Sign in again when you are ready.",
                status: .completed,
                timestamp: Date(timeIntervalSince1970: 1_787_499_950),
                detail: nil
            ),
        ]
    )
}

extension RuntimeRegistry {
    /// Debug-only registry selected by the explicit preview launch flag.
    static let previewAuthRecovery: Self = {
        let provider = RuntimeProviderDescriptor(
            id: .codexAppServer,
            displayName: "Codex",
            factory: { _ in PreviewAuthRecoveryRuntime() }
        )
        let connection = RuntimeConnectionRegistration(
            id: .codexDefault,
            adapterID: .codexAppServer
        )
        // These fixture identifiers are compile-time constants. A registry
        // failure here is a programmer error and should fail the debug launch
        // immediately instead of silently falling back to real credentials.
        return try! Self(
            providers: [provider],
            connections: [connection]
        )
    }()
}

@MainActor
enum PreviewAuthRecoveryComposition {
    static func makeHost() -> OnyxApplicationHost {
        let defaultsSuite = "app.onyx.preview.auth-recovery-fixture"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        // This suite is fixture-owned. Resetting it guarantees the proof run
        // cannot inherit a real window selection, project, or provider choice.
        defaults.removePersistentDomain(forName: defaultsSuite)

        let stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "onyx-auth-recovery-preview-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )

        return OnyxApplicationHost(
            registry: .previewAuthRecovery,
            defaults: defaults,
            projectCatalogStore: ProjectCatalogStore(
                fileURL: stateRoot.appendingPathComponent("projects.json")
            ),
            providerConnectionStore: ProviderConnectionStore(
                storage: InMemoryProviderConnectionStorage()
            ),
            providerCredentialStore: InMemoryCredentialStore(),
            providerConversationStore: OpenAICompatibleConversationStore(
                fileURL: stateRoot.appendingPathComponent("conversations.json")
            ),
            providerAdaptiveStateStore: OpenAICompatibleAdaptiveStateStore(
                fileURL: stateRoot.appendingPathComponent("adaptive-state.json")
            ),
            previewAuthRecoveryFixtureEnabled: true
        )
    }
}
#endif
