import Foundation
import XCTest
@testable import Onyx

/// Opt-in integration coverage for the adaptive OpenAI-compatible lane. It is
/// intentionally separate from the deterministic adaptive tests. The focused
/// probe check only uses the network; the full project-agent test starts the
/// real bundled app-server and asks the configured endpoint to use a local tool
/// inside a temporary workspace.
final class OpenAICompatibleAdaptiveRuntimeLiveTests: XCTestCase {
    /// A focused wire-level check for the inexpensive capability probe. Unlike
    /// the full test below, this does not start the bundled helper or launch an
    /// app; it only performs the bounded, side-effect-free Responses probe
    /// (one two-request round plus at most one complete fallback round).
    func testConfiguredVLLMResponsesCompatibilityProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["ONYX_LIVE_QWEN_COMPATIBILITY_PROBE_TEST"] == "1",
            "Set ONYX_LIVE_QWEN_COMPATIBILITY_PROBE_TEST=1 to run the live vLLM Responses compatibility check."
        )

        let connection = try await configuredConnection(environment: environment)
        try XCTSkipUnless(
            connection.authMode == .none,
            "The focused live probe only accepts a credential-free local endpoint."
        )
        let record = try await OpenAICompatibleResponsesCompatibilityProbe(
            credentialStore: InMemoryCredentialStore()
        ).probe(
            connection: connection,
            modelID: try modelID(connection)
        )

        XCTAssertEqual(
            record.outcome,
            .compatible(.init(
                usedServerSentEvents: true,
                receivedFunctionCall: true,
                submittedCorrelatedOutput: true,
                completedAfterFunctionOutput: true
            ))
        )
    }

    func testConfiguredVLLMProjectAgentCanCreateAndVerifyMarkerFile() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["ONYX_LIVE_QWEN_ADAPTIVE_AGENT_TEST"] == "1",
            "Set ONYX_LIVE_QWEN_ADAPTIVE_AGENT_TEST=1 to run the real vLLM project-agent proof."
        )

        var connection = try await configuredConnection(environment: environment)
        guard connection.authMode == .none else {
            throw XCTSkip(
                "The configured vLLM connection uses bearer authentication; this live proof only accepts the credential-free local setup."
            )
        }
        // Deliberately discard catalog capability metadata. This proof must
        // exercise optimistic generic-provider admission, not an advertised
        // tool bit or a synthetic compatibility-probe result.
        connection.discovery = .init()
        XCTAssertTrue(connection.discovery.discoveredModels.isEmpty)

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "OnyxLiveAdaptiveVLLM-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspaceURL = fixtureRoot.appendingPathComponent("workspace", isDirectory: true)
        let applicationSupportURL = fixtureRoot.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let stateURL = fixtureRoot.appendingPathComponent("adaptive-state.json")
        let conversationsURL = fixtureRoot.appendingPathComponent(
            "conversations.json",
            isDirectory: false
        )
        let markerURL = workspaceURL.appendingPathComponent(
            "ONYX_VLLM_AGENT_MARKER.txt",
            isDirectory: false
        )
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try Data("This directory is an isolated Onyx live-agent fixture.\n".utf8)
            .write(to: workspaceURL.appendingPathComponent("README.txt"))
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let credentialStore = InMemoryCredentialStore()
        let stateStore = OpenAICompatibleAdaptiveStateStore(fileURL: stateURL)
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: OpenAICompatibleResponsesCompatibilityProbe(
                credentialStore: credentialStore
            ),
            stateStore: stateStore
        )
        let appURL = try bundledPreviewURL(environment: environment, fileManager: fileManager)
        let runtimeEnvironment: [String: String] = [
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": environment["LANG"] ?? "en_US.UTF-8",
        ]
        let agentFactory = OpenAICompatibleAgentRuntimeFactory(
            credentialStore: credentialStore,
            runtimeFactory: { [appURL, applicationSupportURL, runtimeEnvironment] binding, handler in
                let launchConfiguration = try CodexRuntimeLaunchConfiguration.production(
                    bundleURL: appURL,
                    userApplicationSupportURL: applicationSupportURL,
                    inheritedEnvironment: runtimeEnvironment,
                    modelProvider: binding
                )
                return CodexRuntime(
                    launchConfiguration: launchConfiguration,
                    dynamicToolHandler: handler
                )
            }
        )
        let runtime = OpenAICompatibleAdaptiveRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            conversationStore: OpenAICompatibleConversationStore(fileURL: conversationsURL),
            stateStore: stateStore,
            resolver: resolver,
            agentFactory: agentFactory
        )

        let eventLog = LiveAdaptiveEventLog()
        let collector = Task { () throws -> LiveAdaptiveTurnResult in
            for await event in runtime.events {
                try Task.checkCancellation()
                await eventLog.append(event)
                if case let .userInteractionRequested(interaction) = event {
                    // The fixture is an isolated workspace. Accept only the
                    // standard approval prompt; questions/forms are evidence
                    // that the model did not follow the deterministic request.
                    if case .approval = interaction.kind {
                        try? await runtime.respond(
                            to: interaction.id,
                            with: .approval(.accept)
                        )
                    }
                }
                if case let .turnCompleted(threadID, status) = event,
                   await eventLog.isTargetTurn(threadID),
                   !status.isBusy {
                    return await eventLog.result(status: status)
                }
            }
            throw AgentRuntimeError.protocolFailure(
                "The adaptive vLLM event stream ended before the project turn completed."
            )
        }

        do {
            _ = try await runtime.connect()
            let thread = try await runtime.startThread(
                StartThreadRequest(
                    cwd: workspaceURL.path,
                    model: try modelID(connection),
                    sandboxMode: .workspaceWrite,
                    approvalPolicy: .onRequest
                )
            )
            await eventLog.setTargetTurn(threadID: thread.id)

            try await runtime.startTurn(
                StartTurnRequest(
                    threadID: thread.id,
                    inputs: [.text(livePrompt(markerURL: markerURL))],
                    model: try modelID(connection),
                    cwd: workspaceURL.path,
                    reasoningEffort: "medium",
                    sandboxMode: .workspaceWrite,
                    approvalPolicy: .onRequest
                )
            )

            let result = try await withThrowingTaskGroup(of: LiveAdaptiveTurnResult.self) { group in
                group.addTask { try await collector.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(180))
                    throw AgentRuntimeError.protocolFailure(
                        "The configured vLLM project-agent turn timed out after 180 seconds."
                    )
                }
                guard let first = try await group.next() else {
                    throw AgentRuntimeError.protocolFailure(
                        "The configured vLLM project-agent turn produced no result."
                    )
                }
                group.cancelAll()
                return first
            }

            guard fileManager.fileExists(atPath: markerURL.path) else {
                XCTFail(
                    "The live agent completed without creating the marker file. \(result.eventSummary) assistant=\(result.assistantText)"
                )
                throw AgentRuntimeError.protocolFailure(
                    "The live vLLM task completed without the requested workspace file."
                )
            }
            let marker = try String(contentsOf: markerURL, encoding: .utf8)
            XCTAssertEqual(marker, "ONYX_VLLM_AGENT_FILE_OK\n")
            XCTAssertFalse(result.commandOrToolItemIDs.isEmpty, result.eventSummary)
            XCTAssertFalse(result.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(result.status, .idle, result.eventSummary)
            print(
                "Onyx live vLLM adaptive agent: model=\(try modelID(connection)) "
                    + "thread=\(thread.id) toolItems=\(result.commandOrToolItemIDs.count) "
                    + "file=\(markerURL.lastPathComponent)"
            )
        } catch {
            collector.cancel()
            await runtime.disconnect()
            _ = await collector.result
            throw error
        }

        collector.cancel()
        await runtime.disconnect()
        _ = await collector.result
    }

    private func configuredConnection(
        environment: [String: String]
    ) async throws -> ProviderConnectionRecord {
        let endpointText = environment["ONYX_LIVE_QWEN_ENDPOINT"]
            ?? environment["ONYX_LIVE_OPENAI_COMPATIBLE_URL"]
        let modelText = environment["ONYX_LIVE_QWEN_MODEL"]
            ?? environment["ONYX_LIVE_OPENAI_COMPATIBLE_MODEL"]

        if let endpointText, let modelText,
           let endpoint = URL(string: endpointText),
           !modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try ProviderConnectionRecord(
                id: ProviderConnectionID("live.vllm"),
                displayName: "Live vLLM",
                baseURL: endpoint,
                selectedModelID: modelText,
                authMode: .none,
                transportSecurity: endpoint.scheme?.lowercased() == "http"
                    ? .allowInsecureHTTP
                    : .requireTLS,
                transportCapabilities: [.streaming]
            )
        }

        let configuredConnections = try await ProviderConnectionStore().connections()
        let configured = configuredConnections.first { connection in
            connection.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "vllm"
        }
        guard let configured,
              configured.selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty == false else {
            throw XCTSkip(
                "Set ONYX_LIVE_QWEN_ENDPOINT and ONYX_LIVE_QWEN_MODEL, or save a connection named vLLM in Onyx settings."
            )
        }
        return configured
    }

    private func modelID(_ connection: ProviderConnectionRecord) throws -> String {
        guard let modelID = connection.selectedModelID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !modelID.isEmpty else {
            throw XCTSkip("The configured vLLM connection has no selected model.")
        }
        return modelID
    }

    private func bundledPreviewURL(
        environment: [String: String],
        fileManager: FileManager
    ) throws -> URL {
        let candidates = [
            environment["ONYX_BUNDLED_CODEX_APP_PATH"],
            environment["ONYX_LIVE_QWEN_BUNDLED_APP_PATH"],
            fileManager.currentDirectoryPath + "/dist-preview/Onyx Preview.app",
        ].compactMap { $0 }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let candidate = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw XCTSkip(
                "Set ONYX_BUNDLED_CODEX_APP_PATH to the canonical dist-preview/Onyx Preview.app before running this live test."
            )
        }
        return candidate
    }

    private func livePrompt(markerURL: URL) -> String {
        """
        Work only inside the current project directory. First inspect the project with pwd and ls. Then use your command/file tools to create exactly one file at \(markerURL.path) with exactly this one line: ONYX_VLLM_AGENT_FILE_OK. Read the file back to verify it. Do not merely describe the steps: perform them. After verification, reply with the exact marker ONYX_VLLM_AGENT_DONE.
        """
    }
}

private struct LiveAdaptiveTurnResult: Sendable {
    let status: RuntimeThreadStatus
    let assistantText: String
    let commandOrToolItemIDs: [String]
    let eventSummary: String
}

private actor LiveAdaptiveEventLog {
    private var targetThreadID: String?
    private var values: [AgentRuntimeEvent] = []

    func setTargetTurn(threadID: String) {
        targetThreadID = threadID
    }

    func isTargetTurn(_ threadID: String) -> Bool {
        targetThreadID == threadID
    }

    func append(_ event: AgentRuntimeEvent) {
        values.append(event)
    }

    func result(status: RuntimeThreadStatus) -> LiveAdaptiveTurnResult {
        let target = targetThreadID
        var assistantText = ""
        var commandOrToolItemIDs: [String] = []
        var itemSummaries: [String] = []
        for event in values {
            switch event {
            case let .itemDelta(threadID, _, delta) where threadID == target:
                assistantText += delta
            case let .itemCompleted(threadID, item) where threadID == target:
                itemSummaries.append(
                    "completed:\(item.kind.rawValue):\(item.status.rawValue):\(item.body.prefix(240))"
                )
                if item.kind == .assistantMessage { assistantText = item.body }
                if item.kind == .command || item.kind == .tool || item.kind == .fileChange {
                    commandOrToolItemIDs.append(item.id)
                }
            case let .itemStarted(threadID, item) where threadID == target:
                itemSummaries.append(
                    "started:\(item.kind.rawValue):\(item.status.rawValue):\(item.body.prefix(240))"
                )
                if item.kind == .command || item.kind == .tool || item.kind == .fileChange {
                    commandOrToolItemIDs.append(item.id)
                }
            default:
                continue
            }
        }
        let kinds = values.compactMap { event -> String? in
            switch event {
            case .connectionChanged: "connection"
            case .authenticationRecoveryRequired: "auth-recovery"
            case .threadUpdated: "thread"
            case .itemStarted: "item-started"
            case .itemDelta: "item-delta"
            case .itemCompleted: "item-completed"
            case .turnStarted: "turn-started"
            case .turnCompleted: "turn-completed"
            case .userInteractionRequested: "interaction"
            case .userInteractionResolved: "interaction-resolved"
            case .runtimeNotice: "notice"
            case .runtimeModelsUpdated: "models"
            case .runtimeCapabilitiesDowngraded: "capability-downgrade"
            case .accountUpdated: "account"
            case .loginCompleted: "login"
            case .threadNameChanged: "thread-name"
            case .threadStatusChanged: "thread-status"
            case .threadArchived: "thread-archived"
            case .threadUnarchived: "thread-unarchived"
            case .threadDeleted: "thread-deleted"
            case .threadRefreshRequested: "thread-refresh"
            case .planUpdated: "plan"
            }
        }
        return LiveAdaptiveTurnResult(
            status: status,
            assistantText: assistantText,
            commandOrToolItemIDs: Array(Set(commandOrToolItemIDs)),
            eventSummary: "events=\(kinds.joined(separator: ",")); items=\(itemSummaries.joined(separator: " | "))"
        )
    }
}
