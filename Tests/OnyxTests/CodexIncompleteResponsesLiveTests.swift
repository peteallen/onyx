import Foundation
import XCTest
@testable import Onyx

/// Opt-in characterization of the pinned app-server's behavior when a
/// Responses provider emits partial assistant text and then exhausts
/// `max_output_tokens`. The fixture uses a fresh private CODEX_HOME and a
/// literal-loopback endpoint; it never reads or writes normal Onyx/Codex state.
final class CodexIncompleteResponsesLiveTests: XCTestCase {
    private static let optInKey = "ONYX_LIVE_CODEX_INCOMPLETE_TEST"
    private static let executableOverrideKey = "ONYX_CODEX_INCOMPLETE_APP_SERVER_PATH"

    func testPinnedAppServerPreservesPartialOutputAsDurableFailedTurnWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[Self.optInKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.optInKey)=1 to run the local Responses incomplete-turn proof."
            )
        }

        let executable = try appServerExecutable(environment: environment)
        let version = try appServerVersion(executable)
        XCTAssertEqual(version, "codex-app-server 0.149.0")

        let fixture = try await CodexIncompleteResponsesLiveFixture.start()
        defer { fixture.stop() }

        let fileManager = FileManager.default
        // Use the canonical macOS spelling so app-server's initialization
        // response and the launch configuration agree byte-for-byte; `/var`
        // aliases to `/private/var` and would otherwise trip the isolation
        // guard even though both paths identify the same temporary folder.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("OnyxCodexIncompleteProof-\(UUID().uuidString)", isDirectory: true)
        let baseCodexHome = root.appendingPathComponent("Codex", isDirectory: true)
        let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let provider = CodexRuntimeModelProviderBinding(
            id: "onyx_incomplete_proof",
            baseURL: fixture.baseURL,
            apiKey: "fixture-loopback-token",
            stateIdentifier: "incompleteproof"
        )
        let configuration = try CodexRuntimeLaunchConfiguration.developmentInstalled(
            explicitExecutableURL: executable,
            codexHomeURL: baseCodexHome,
            inheritedEnvironment: [
                "HOME": NSHomeDirectory(),
                "PATH": environment["PATH"] ?? "/usr/bin:/bin",
            ],
            modelProvider: provider
        )
        let client = CodexAppServerClient(
            executableURL: configuration.executableURL,
            processArguments: configuration.processArguments,
            processEnvironment: configuration.processEnvironment,
            stateDirectoryPreparation: {
                try configuration.prepareStateDirectory()
            }
        )
        let initialConnection = try await client.start()
        let reportedCodexHome = initialConnection.initializeResponse["codexHome"]?.stringValue
        print(
            "ONYX_INCOMPLETE_CODEX_HOME expected=\(configuration.codexHomeURL.path) "
                + "reported=\(reportedCodexHome ?? "missing")"
        )
        XCTAssertEqual(
            reportedCodexHome.map { URL(fileURLWithPath: $0).standardizedFileURL },
            configuration.codexHomeURL.standardizedFileURL
        )
        let runtime = CodexRuntime(
            client: client,
            expectedCodexHomeURL: nil,
            modelProviderID: configuration.modelProviderID
        )

        do {
            _ = try await runtime.connect()
            let thread = try await runtime.startThread(
                StartThreadRequest(
                    cwd: workspace.path,
                    model: "fixture-incomplete-model",
                    ephemeral: false,
                    sandboxMode: .readOnly,
                    approvalPolicy: .never
                )
            )

            let eventCollector = Task { () -> [AgentRuntimeEvent] in
                var values: [AgentRuntimeEvent] = []
                for await event in runtime.events {
                    values.append(event)
                    if case let .turnCompleted(threadID, _) = event, threadID == thread.id {
                        return values
                    }
                }
                return values
            }

            try await runtime.startTurn(
                StartTurnRequest(
                    threadID: thread.id,
                    text: "Return a short answer without tools.",
                    model: "fixture-incomplete-model",
                    cwd: workspace.path,
                    sandboxMode: .readOnly,
                    approvalPolicy: .never
                )
            )

            let events = try await waitForEvents(
                eventCollector,
                runtime: runtime,
                threadID: thread.id
            )
            let conversation = try await runtime.readThread(id: thread.id)
            let listed = try await runtime.listThreads(limit: 20, archived: false)
            await runtime.disconnect()

            let observed = Self.observation(events: events, conversation: conversation)
            print(observed.summary)
            print("ONYX_INCOMPLETE_REQUEST_COUNT=\(fixture.requestBodies.count)")

            XCTAssertEqual(observed.turnStatus, .failed)
            // Pinned app-server 0.149.0 treats `response.incomplete` as a
            // disconnected stream. Onyx's custom-provider launch contract
            // disables automatic stream retries so visible partial output is
            // represented once instead of duplicated on every retry.
            XCTAssertEqual(observed.streamedPartialDeltaCount, 1)
            XCTAssertEqual(observed.completedPartialItemCount, 1)
            XCTAssertEqual(observed.liveFailureBodies.count, 1)
            XCTAssertEqual(
                observed.liveFailureBodies,
                ["The provider reached its output limit before completing this response."],
                "The app-server's transport-looking output-limit diagnostic should be normalized in the transcript."
            )
            XCTAssertEqual(observed.durablePartialItemCount, 1)
            XCTAssertEqual(observed.durableFailureItemCount, 1)
            XCTAssertEqual(conversation.thread.status, .failed)
            XCTAssertTrue(
                listed.contains(where: { $0.id == thread.id }),
                "The failed custom-provider task should remain in its isolated durable catalog."
            )
            XCTAssertEqual(fixture.requestBodies.count, 1)
        } catch {
            await runtime.disconnect()
            throw error
        }
    }

    private func appServerExecutable(environment: [String: String]) throws -> URL {
        if let override = environment[Self.executableOverrideKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw XCTSkip("The configured app-server proof binary is not executable: \(url.path)")
            }
            return url
        }

        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("dist-preview", isDirectory: true)
            .appendingPathComponent("Onyx Preview.app", isDirectory: true)
            .appendingPathComponent(
                CodexRuntimeLaunchConfiguration.bundledHelperRelativePath,
                isDirectory: false
            )
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip(
                "Build the canonical preview or set \(Self.executableOverrideKey) to the pinned codex-app-server."
            )
        }
        return url
    }

    private func appServerVersion(_ executable: URL) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodexIncompleteLiveProofError.versionCheckFailed
        }
        return String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForEvents(
        _ collector: Task<[AgentRuntimeEvent], Never>,
        runtime: CodexRuntime,
        threadID: String
    ) async throws -> [AgentRuntimeEvent] {
        try await withThrowingTaskGroup(of: [AgentRuntimeEvent].self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                try? await runtime.interrupt(threadID: threadID)
                throw CodexIncompleteLiveProofError.turnTimedOut
            }
            defer {
                group.cancelAll()
                collector.cancel()
            }
            guard let first = try await group.next() else {
                throw CodexIncompleteLiveProofError.turnTimedOut
            }
            return first
        }
    }

    private struct Observation {
        let turnStatus: RuntimeThreadStatus?
        let streamedPartialDeltaCount: Int
        let completedPartialItemCount: Int
        let liveFailureBodies: [String]
        let durablePartialItemCount: Int
        let durableFailureItemCount: Int

        var summary: String {
            "ONYX_INCOMPLETE_OBSERVED "
                + "turn=\(turnStatus?.rawValue ?? "missing") "
                + "streamedPartialDeltas=\(streamedPartialDeltaCount) "
                + "completedPartialItems=\(completedPartialItemCount) "
                + "liveFailures=\(liveFailureBodies) "
                + "durablePartialItems=\(durablePartialItemCount) "
                + "durableFailureItems=\(durableFailureItemCount)"
        }
    }

    private static func observation(
        events: [AgentRuntimeEvent],
        conversation: RuntimeConversation
    ) -> Observation {
        var turnStatus: RuntimeThreadStatus?
        var streamedPartialDeltaCount = 0
        var completedPartialItemCount = 0
        var liveFailureBodies: [String] = []
        for event in events {
            switch event {
            case let .itemDelta(_, _, delta):
                if delta.contains(CodexIncompleteResponsesLiveFixture.partialText) {
                    streamedPartialDeltaCount += 1
                }
            case let .itemCompleted(_, item):
                if item.kind == .assistantMessage,
                   item.body.contains(CodexIncompleteResponsesLiveFixture.partialText) {
                    completedPartialItemCount += 1
                }
                if item.kind == .error { liveFailureBodies.append(item.body) }
            case let .turnCompleted(_, status):
                turnStatus = status
            default:
                break
            }
        }

        return Observation(
            turnStatus: turnStatus,
            streamedPartialDeltaCount: streamedPartialDeltaCount,
            completedPartialItemCount: completedPartialItemCount,
            liveFailureBodies: liveFailureBodies,
            durablePartialItemCount: conversation.items.count { item in
                item.kind == .assistantMessage
                    && item.body.contains(CodexIncompleteResponsesLiveFixture.partialText)
            },
            durableFailureItemCount: conversation.items.count { $0.kind == .error }
        )
    }
}

private enum CodexIncompleteLiveProofError: Error {
    case versionCheckFailed
    case turnTimedOut
}
