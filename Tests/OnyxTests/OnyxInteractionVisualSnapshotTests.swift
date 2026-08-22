import AppKit
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class OnyxInteractionVisualSnapshotTests: XCTestCase {
    func testRendersRequestUserInputWhenEnabled() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ONYX_INTERACTION_SNAPSHOT_PATH"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set ONYX_INTERACTION_SNAPSHOT_PATH to render the typed interaction workspace")
        }

        let suiteName = "OnyxInteractionVisualSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "Onyx.sidebarVisible")
        defaults.set(true, forKey: "Onyx.inspectorVisible")
        defaults.set(false, forKey: "Onyx.bottomPanelVisible")
        defaults.set(InteractionSnapshotFixture.thread.id, forKey: "Onyx.selectedThreadID")

        let runtime = InteractionSnapshotRuntime()
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        model.start()

        await waitUntil("The snapshot runtime did not finish loading its task") {
            model.connectionState == .connected("Snapshot account")
                && model.selectedThreadID == InteractionSnapshotFixture.thread.id
                && model.timeline == InteractionSnapshotFixture.timeline
        }

        await runtime.emit(
            .userInteractionRequested(InteractionSnapshotFixture.interaction)
        )
        await waitUntil("The requestUserInput event did not reach the app model") {
            model.activeUserInteraction == InteractionSnapshotFixture.interaction
        }

        let size = NSSize(width: 1_440, height: 900)
        let hostingView = NSHostingView(
            rootView: OnyxWorkspaceView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not allocate the interaction snapshot bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode the interaction snapshot as PNG")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(data.count, 10_000)
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), failureMessage)
    }
}

private enum InteractionSnapshotFixture {
    static let thread = RuntimeThread(
        id: "snapshot-request-user-input",
        title: "Plan the provider architecture",
        preview: "Choose the first provider path and supply a test credential",
        cwd: "/tmp/onyx",
        updatedAt: .now,
        status: .running,
        isPinned: true,
        runtime: .codex,
        model: "gpt-5.6-sol",
        branch: "main"
    )

    static let timeline = [
        TimelineItem(
            id: "snapshot-user-message",
            kind: .userMessage,
            title: nil,
            body: "Set up the first provider adapter, but ask me before choosing the authentication path.",
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1_775_000_001),
            detail: nil
        ),
        TimelineItem(
            id: "snapshot-assistant-message",
            kind: .assistantMessage,
            title: nil,
            body: "I mapped the provider boundary. I need two choices before I can finish the integration.",
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1_775_000_002),
            detail: nil
        ),
    ]

    static let interaction = RuntimeUserInteraction(
        id: .integer(731),
        threadID: thread.id,
        providerMethod: "item/tool/requestUserInput",
        title: "Your input is needed",
        detail: "Codex is waiting for three details before it continues this task.",
        kind: .questions(
            RuntimeQuestionPrompt(
                questions: [
                    RuntimeQuestion(
                        id: "provider-path",
                        header: "Provider path",
                        prompt: "Which integration should Onyx optimize first?",
                        options: [
                            RuntimeQuestionOption(
                                label: "ChatGPT subscription",
                                detail: "Use Codex OAuth and subscription entitlements while keeping credentials entirely inside the Codex runtime."
                            ),
                            RuntimeQuestionOption(
                                label: "OpenRouter",
                                detail: "Use one API surface for many model vendors, with provider routing and usage-based billing managed separately from Codex."
                            ),
                        ],
                        allowsOther: true,
                        isSecret: false
                    ),
                    RuntimeQuestion(
                        id: "test-credential",
                        header: "Test credential",
                        prompt: "Paste the temporary credential to use for this local test.",
                        options: [],
                        allowsOther: true,
                        isSecret: true
                    ),
                    RuntimeQuestion(
                        id: "rollout-scope",
                        header: "Rollout scope",
                        prompt: "Where should the first working adapter be enabled?",
                        options: [
                            RuntimeQuestionOption(
                                label: "Preview build only",
                                detail: "Keep the experiment isolated while the provider-neutral interaction contract is verified."
                            ),
                            RuntimeQuestionOption(
                                label: "All local builds",
                                detail: "Make the adapter available everywhere on this Mac as soon as its smoke tests pass."
                            ),
                        ],
                        allowsOther: false,
                        isSecret: false
                    ),
                ],
                isBlocking: true
            )
        )
    )

    static let session = RuntimeSession(
        runtime: .codex,
        displayName: "Snapshot runtime",
        accountLabel: "Snapshot account",
        planLabel: "Pro",
        auth: RuntimeAuthState(
            mode: .chatgpt,
            email: "snapshot@example.com",
            planLabel: "Pro",
            requiresAuthentication: true
        ),
        availableLoginMethods: [],
        availableModels: [
            RuntimeModel(
                id: "gpt-5.6-sol",
                displayName: "GPT-5.6-Sol",
                description: "Latest frontier agentic coding model.",
                isDefault: true,
                defaultReasoningEffort: "high",
                reasoningEfforts: ["low", "medium", "high", "xhigh"]
            ),
        ],
        capabilities: [
            .streaming,
            .steering,
            .interruption,
            .approvals,
            .reasoning,
            .tools,
            .diffs,
            .usage,
        ]
    )
}

private actor InteractionSnapshotRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        eventContinuation.yield(.connectionChanged(.connected("Snapshot account")))
        return InteractionSnapshotFixture.session
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : [InteractionSnapshotFixture.thread]
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        guard id == InteractionSnapshotFixture.thread.id else {
            throw AgentRuntimeError.missingField("interaction snapshot conversation for \(id)")
        }
        return RuntimeConversation(
            thread: InteractionSnapshotFixture.thread,
            items: InteractionSnapshotFixture.timeline
        )
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("starting a thread in the interaction snapshot")
    }

    func startTurn(_: StartTurnRequest) async throws {}
    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(
        to interactionID: RuntimeRequestID,
        with response: RuntimeUserInteractionResponse
    ) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}

    func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }
}
