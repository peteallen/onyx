import AppKit
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class OnyxVisualSnapshotTests: XCTestCase {
    func testRendersConversationAndInlineWaitingStateWhenEnabled() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ONYX_TRANSCRIPT_SNAPSHOT_PATH"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set ONYX_TRANSCRIPT_SNAPSHOT_PATH to render the conversation transcript")
        }

        let items = [
            TimelineItem(
                id: "visual-user-one",
                kind: .userMessage,
                title: nil,
                body: "hi",
                status: .completed,
                timestamp: .now,
                detail: nil
            ),
            TimelineItem(
                id: "visual-assistant",
                kind: .assistantMessage,
                title: nil,
                body: "Hi Pete! What are we working on?",
                status: .completed,
                timestamp: .now,
                detail: "final_answer"
            ),
            TimelineItem(
                id: "visual-user-two",
                kind: .userMessage,
                title: nil,
                body: "Can you review the current changes?",
                status: .completed,
                timestamp: .now,
                detail: nil
            ),
            TimelineItem(
                id: "visual-tool",
                kind: .tool,
                title: "Inspect changes",
                body: "Read the working tree and compared the modified files.",
                status: .running,
                timestamp: .now,
                detail: "4 files"
            ),
            TimelineItem(
                id: "visual-failed-tool",
                kind: .tool,
                title: "node_repl · js",
                body: "Invalid app: app.onyx.preview",
                status: .failed,
                timestamp: .now,
                detail: nil
            ),
        ]

        let environment = ProcessInfo.processInfo.environment
        let size = NSSize(
            width: snapshotDimension(environment["ONYX_TRANSCRIPT_SNAPSHOT_WIDTH"], fallback: 840),
            height: snapshotDimension(environment["ONYX_TRANSCRIPT_SNAPSHOT_HEIGHT"], fallback: 620)
        )
        let appearance = snapshotAppearance(from: environment)
        let hostingView = NSHostingView(
            rootView: NativeTranscriptView(
                items: items,
                isAwaitingResponse: true,
                workingLabel: "Working on a response…"
            )
            .frame(width: size.width, height: size.height)
            .background(OnyxTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
        )
        hostingView.appearance = NSAppearance(named: appearance.nsAppearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not allocate the transcript snapshot bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode the transcript snapshot as PNG")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(data.count, 10_000)
    }

    func testRendersBusyTaskWorkspaceWhenEnabled() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ONYX_BUSY_SNAPSHOT_PATH"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set ONYX_BUSY_SNAPSHOT_PATH to render a busy task workspace")
        }

        let suiteName = "OnyxBusyTaskVisualSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "Onyx.sidebarVisible")
        defaults.set(true, forKey: "Onyx.inspectorVisible")
        defaults.set(false, forKey: "Onyx.bottomPanelVisible")
        defaults.set(InspectorTab.summary.rawValue, forKey: "Onyx.inspectorTab")
        defaults.set(BusyTaskSnapshotFixture.selectedThread.id, forKey: "Onyx.selectedThreadID")
        defaults.set(278.0, forKey: WorkspacePaneLayout.sidebarWidthPreferenceSuffix)
        defaults.set(352.0, forKey: WorkspacePaneLayout.inspectorWidthPreferenceSuffix)

        let catalogDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxBusyTaskVisualSnapshotTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: catalogDirectory) }
        let catalogStore = ProjectCatalogStore(
            fileURL: catalogDirectory.appendingPathComponent("projects.json")
        )
        try await catalogStore.importProject(
            folderPath: BusyTaskSnapshotFixture.projectPath,
            displayName: "Onyx"
        )
        let projectCatalog = ProjectCatalogModel(store: catalogStore)
        await projectCatalog.reload()
        projectCatalog.replaceTasks(
            for: .codexDefault,
            providerDisplayName: "Codex",
            scope: .active,
            threads: BusyTaskSnapshotFixture.threads
        )

        let runtime = BusyTaskSnapshotRuntime()
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        model.start()

        await waitUntil("The busy snapshot runtime did not load its selected task") {
            model.connectionState == .connected("ChatGPT Pro")
                && model.selectedThreadID == BusyTaskSnapshotFixture.selectedThread.id
                && model.timeline == BusyTaskSnapshotFixture.timeline
                && model.isTurnRunning
                && model.collaborationAgents.count == 2
        }

        let environment = ProcessInfo.processInfo.environment
        let size = NSSize(
            width: snapshotDimension(environment["ONYX_BUSY_SNAPSHOT_WIDTH"], fallback: 1_500),
            height: snapshotDimension(environment["ONYX_BUSY_SNAPSHOT_HEIGHT"], fallback: 940)
        )
        let appearance = snapshotAppearance(from: environment)
        let hostingView = NSHostingView(
            rootView: OnyxWorkspaceView(
                model: model,
                defaults: defaults,
                projectCatalog: projectCatalog
            )
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance.colorScheme)
        )
        hostingView.appearance = NSAppearance(named: appearance.nsAppearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not allocate the busy task snapshot bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode the busy task snapshot as PNG")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(data.count, 10_000)
    }

    func testRendersSignedOutWorkspaceWhenEnabled() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ONYX_SNAPSHOT_PATH"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set ONYX_SNAPSHOT_PATH to render the signed-out workspace")
        }

        let model = OnyxAppModel(runtime: nil)
        let browserLogin = RuntimeLoginMethod(
            id: "codex.chatgpt.browser",
            displayName: "Continue with ChatGPT",
            detail: "Sign in securely in your browser",
            ceremony: .browser
        )
        let deviceLogin = RuntimeLoginMethod(
            id: "codex.chatgpt.device-code",
            displayName: "Use a device code",
            detail: "Enter a one-time code at OpenAI",
            ceremony: .deviceCode
        )
        model.session = RuntimeSession(
            runtime: .codex,
            displayName: "Codex app-server",
            accountLabel: nil,
            planLabel: nil,
            auth: .signedOut,
            availableLoginMethods: [browserLogin, deviceLogin],
            availableModels: [
                RuntimeModel(
                    id: "gpt-5.6-sol",
                    displayName: "GPT-5.6-Sol",
                    description: "Latest frontier agentic coding model.",
                    isDefault: true,
                    defaultReasoningEffort: "low",
                    reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]
                ),
            ],
            capabilities: [.streaming, .reasoning, .approvals, .tools]
        )
        model.authState = .signedOut
        model.connectionState = .connected("Codex")
        model.selectedModelID = "gpt-5.6-sol"
        model.selectedReasoningEffort = "low"
        model.isInspectorVisible = true
        model.isBottomPanelVisible = false

        let environment = ProcessInfo.processInfo.environment
        let size = NSSize(
            width: snapshotDimension(environment["ONYX_SNAPSHOT_WIDTH"], fallback: 1_380),
            height: snapshotDimension(environment["ONYX_SNAPSHOT_HEIGHT"], fallback: 860)
        )
        let appearance = snapshotAppearance(from: environment)
        let hostingView = NSHostingView(
            rootView: OnyxWorkspaceView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, appearance.colorScheme)
        )
        hostingView.appearance = NSAppearance(named: appearance.nsAppearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not allocate the visual snapshot bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode the visual snapshot as PNG")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(data.count, 10_000)
    }

    private func snapshotDimension(_ rawValue: String?, fallback: CGFloat) -> CGFloat {
        guard let rawValue,
              let value = Double(rawValue),
              value.isFinite,
              value > 0 else { return fallback }
        return CGFloat(value)
    }

    private func snapshotAppearance(
        from environment: [String: String]
    ) -> (colorScheme: ColorScheme, nsAppearance: NSAppearance.Name) {
        switch environment["ONYX_SNAPSHOT_APPEARANCE"]?.lowercased() {
        case "light": (.light, .aqua)
        default: (.dark, .darkAqua)
        }
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

private enum BusyTaskSnapshotFixture {
    static let projectPath = "/Users/peteallen/Projects/Onyx"
    static let baseDate = Date(timeIntervalSince1970: 1_775_100_000)

    static let selectedThread = RuntimeThread(
        id: "snapshot-busy-task",
        title: "Polish the workspace UI",
        preview: "Tighten the task layout and keep noisy activity out of the way",
        cwd: projectPath,
        updatedAt: baseDate.addingTimeInterval(40),
        status: .running,
        isPinned: true,
        runtime: .codex,
        model: "gpt-5.6-sol",
        branch: "ui-polish"
    )

    static let threads = [
        selectedThread,
        RuntimeThread(
            id: "snapshot-provider-task",
            title: "Probe vLLM model capabilities",
            preview: "Infer tools and input modalities from the models endpoint",
            cwd: projectPath,
            updatedAt: baseDate.addingTimeInterval(20),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "qwen3-coder",
            branch: "providers"
        ),
        RuntimeThread(
            id: "snapshot-release-task",
            title: "Prepare the first preview release",
            preview: "Verify signing, packaging, and the stable app identity",
            cwd: projectPath,
            updatedAt: baseDate,
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "gpt-5.6-sol",
            branch: "main"
        ),
    ]

    static let plan = RuntimePlan(
        turnID: "snapshot-busy-turn",
        explanation: "Keep the main conversation calm while preserving every implementation detail on demand.",
        steps: [
            RuntimePlanStep(text: "Compare the current workspace against the reference", status: .completed),
            RuntimePlanStep(text: "Refine transcript hierarchy and pane spacing", status: .completed),
            RuntimePlanStep(text: "Render and inspect a realistic busy task", status: .inProgress),
            RuntimePlanStep(text: "Run the focused UI checks", status: .pending),
        ]
    )

    static let timeline: [TimelineItem] = [
        TimelineItem(
            id: "snapshot-busy-user",
            kind: .userMessage,
            title: nil,
            body: "Codex feels much cleaner. Please simplify ours without hiding what the agent is doing.",
            status: .completed,
            timestamp: baseDate.addingTimeInterval(1),
            detail: nil
        ),
        .planUpdate(plan, timestamp: baseDate.addingTimeInterval(2)),
        TimelineItem(
            id: "snapshot-busy-reasoning",
            kind: .reasoning,
            title: "Mapped the visual hierarchy",
            body: "The conversation should own the center of gravity; project navigation and task context should stay quieter at the edges.",
            status: .completed,
            timestamp: baseDate.addingTimeInterval(3),
            detail: "Design pass"
        ),
        TimelineItem(
            id: "snapshot-busy-command",
            kind: .command,
            title: "Inspected the current workspace",
            body: "rg -n \"NativeTranscriptView|ContextInspectorView|ComposerView\" Sources/Onyx",
            status: .completed,
            timestamp: baseDate.addingTimeInterval(4),
            detail: "Finished in 0.2s"
        ),
        TimelineItem(
            id: "snapshot-busy-spawn",
            kind: .tool,
            title: "Started 2 agents",
            body: "Contrast Audit and Snapshot Review are checking the visual system in parallel.",
            status: .completed,
            timestamp: baseDate.addingTimeInterval(5),
            detail: "2 agents · GPT-5.6-Sol",
            collaboration: RuntimeCollaborationActivity(
                action: .spawn,
                agents: [
                    RuntimeCollaborationAgent(
                        id: "snapshot-agent-contrast",
                        path: "/root/contrast_audit",
                        status: .starting,
                        message: "Checking light and dark contrast",
                        updatedAt: baseDate.addingTimeInterval(5)
                    ),
                    RuntimeCollaborationAgent(
                        id: "snapshot-agent-review",
                        path: "/root/snapshot_review",
                        status: .starting,
                        message: "Comparing the busy task composition",
                        updatedAt: baseDate.addingTimeInterval(5)
                    ),
                ]
            )
        ),
        TimelineItem(
            id: "snapshot-busy-file-change",
            kind: .fileChange,
            title: "Refined the transcript surface",
            body: "Reduced card chrome, tightened routine activity rows, and kept the disclosure hit targets accessible.",
            status: .completed,
            timestamp: baseDate.addingTimeInterval(6),
            detail: "NativeTranscriptView.swift · +84 −31"
        ),
        TimelineItem(
            id: "snapshot-busy-assistant",
            kind: .assistantMessage,
            title: nil,
            body: """
            The cleanup pass is in place:

            - **Conversation first:** the transcript now carries the active work state.
            - **Quiet by default:** commands, reasoning, file edits, and tool calls stay collapsed.
            - **Details on demand:** every activity row still exposes its complete output.

            I’m rendering the busy state now and will tighten anything that still competes with the response.
            """,
            status: .completed,
            timestamp: baseDate.addingTimeInterval(7),
            detail: "commentary"
        ),
        TimelineItem(
            id: "snapshot-busy-test-command",
            kind: .command,
            title: "Ran focused UI checks",
            body: "swift test --filter OnyxVisualSnapshotTests/testRendersBusyTaskWorkspaceWhenEnabled",
            status: .completed,
            timestamp: baseDate.addingTimeInterval(8),
            detail: "Snapshot rendering"
        ),
        TimelineItem(
            id: "snapshot-busy-agent-wait",
            kind: .tool,
            title: "Waiting for 2 agents",
            body: "Contrast Audit is done; Snapshot Review is finishing the final visual comparison.",
            status: .running,
            timestamp: baseDate.addingTimeInterval(9),
            detail: "1 working · 1 completed",
            collaboration: RuntimeCollaborationActivity(
                action: .wait,
                agents: [
                    RuntimeCollaborationAgent(
                        id: "snapshot-agent-contrast",
                        path: "/root/contrast_audit",
                        status: .completed,
                        message: "Contrast checks passed in both appearances",
                        updatedAt: baseDate.addingTimeInterval(9)
                    ),
                    RuntimeCollaborationAgent(
                        id: "snapshot-agent-review",
                        path: "/root/snapshot_review",
                        status: .working,
                        message: "Finishing the side-by-side review",
                        updatedAt: baseDate.addingTimeInterval(9)
                    ),
                ]
            )
        ),
    ]

    static let session = RuntimeSession(
        runtime: .codex,
        displayName: "Codex app-server",
        accountLabel: "ChatGPT Pro",
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
            .threadForking,
            .threadArchiving,
            .reasoning,
            .tools,
            .diffs,
            .usage,
            .ephemeralThreadForking,
        ]
    )
}

private actor BusyTaskSnapshotRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        eventContinuation.yield(.connectionChanged(.connected("ChatGPT Pro")))
        return BusyTaskSnapshotFixture.session
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : BusyTaskSnapshotFixture.threads
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        guard id == BusyTaskSnapshotFixture.selectedThread.id else {
            throw AgentRuntimeError.missingField("busy snapshot conversation for \(id)")
        }
        return RuntimeConversation(
            thread: BusyTaskSnapshotFixture.selectedThread,
            items: BusyTaskSnapshotFixture.timeline
        )
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("starting a thread in the busy snapshot")
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
}
