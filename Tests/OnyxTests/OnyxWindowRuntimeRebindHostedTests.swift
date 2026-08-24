import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Onyx

/// Exercises the production SwiftUI ownership boundary rather than calling the
/// host's replacement helper directly. A deliberately unresolved Codex task
/// catalog makes the ordering observable: settings changes must update the
/// mounted workspace without waiting for that unrelated history load.
@MainActor
final class OnyxWindowRuntimeRebindHostedTests: XCTestCase {
    func testSavedProviderAutomaticallyRebindsOpenWindowBeforeSlowCatalogCompletes() async throws {
        let fixture = try await makeFixture(testName: #function)
        defer { fixture.cleanUp() }

        let hosted = host(
            OnyxWindowRootView(windowID: fixture.windowID, host: fixture.host)
        )
        defer { hosted.close() }

        let original = try XCTUnwrap(
            fixture.host.cachedRuntimeCoordinatorForTesting(fixture.providerID)
        )
        await waitUntilAsync("The hosted workspace never entered the slow catalog load") {
            fixture.slowCodexRuntime.blockedCatalogRequestCount > 0
        }
        fixture.host.providerSettingsModel.draft.displayName = "Edited endpoint"
        let saved = await fixture.host.providerSettingsModel.saveDraft()
        XCTAssertTrue(saved)

        await waitUntil("The open workspace did not bind a fresh provider runtime") {
            guard let replacement = fixture.host.cachedRuntimeCoordinatorForTesting(
                fixture.providerID
            ) else { return false }
            return ObjectIdentifier(replacement) != ObjectIdentifier(original)
        }

        let replacement = try XCTUnwrap(
            fixture.host.cachedRuntimeCoordinatorForTesting(fixture.providerID)
        )
        let replacementSession = try await replacement.connect()
        XCTAssertEqual(replacementSession.displayName, "Provider generation 2")
        XCTAssertEqual(fixture.providerRuntimeFactory.createdRuntimeCount, 2)
        XCTAssertEqual(
            fixture.slowCodexRuntime.completedCatalogRequestCount,
            0,
            "Rebinding the visible workspace must not wait for the slow full catalog to complete."
        )
    }

    func testDeletedProviderAutomaticallyFallsBackToCodexWithoutRecreatingIt() async throws {
        let fixture = try await makeFixture(testName: #function)
        defer { fixture.cleanUp() }

        let hosted = host(
            OnyxWindowRootView(windowID: fixture.windowID, host: fixture.host)
        )
        defer { hosted.close() }

        _ = try XCTUnwrap(
            fixture.host.cachedRuntimeCoordinatorForTesting(fixture.providerID)
        )
        await waitUntilAsync("The hosted workspace never entered the slow catalog load") {
            fixture.slowCodexRuntime.blockedCatalogRequestCount > 0
        }

        let deleted = await fixture.host.providerSettingsModel.delete(fixture.providerID)
        XCTAssertTrue(deleted)

        await waitUntil("The open workspace did not fall back to Codex after provider deletion") {
            fixture.host.selectedConnectionID(for: fixture.windowID) == .codexDefault
                && fixture.host.cachedRuntimeCoordinatorForTesting(fixture.providerID) == nil
        }

        XCTAssertEqual(
            fixture.host.selectedConnectionID(for: fixture.windowID),
            .codexDefault
        )
        XCTAssertNil(
            fixture.host.cachedRuntimeCoordinatorForTesting(fixture.providerID),
            "Deletion must not construct a new runtime for a provider record that no longer exists."
        )
        XCTAssertEqual(
            fixture.providerRuntimeFactory.createdRuntimeCount,
            1,
            "The mounted workspace recreated a runtime for the deleted provider before falling back."
        )
        XCTAssertEqual(
            fixture.slowCodexRuntime.completedCatalogRequestCount,
            0,
            "Provider deletion should change the mounted workspace before the full catalog completes."
        )
    }

    private func makeFixture(testName: String) async throws -> HostedRuntimeRebindFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OnyxWindowRuntimeRebindHostedTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )

        let suiteName = "OnyxWindowRuntimeRebindHostedTests.\(testName).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "Onyx.sidebarVisible")
        defaults.set(false, forKey: "Onyx.inspectorVisible")
        defaults.set(false, forKey: "Onyx.bottomPanelVisible")

        let providerID = ProviderConnectionID("local.hosted-runtime-rebind")
        let providerStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        try await providerStore.upsert(ProviderConnectionRecord(
            id: providerID,
            displayName: "Original endpoint",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none,
            transportCapabilities: [.streaming],
            discovery: ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: Date(timeIntervalSince1970: 1),
                lastSucceededAt: Date(timeIntervalSince1970: 1),
                discoveredModelIDs: ["fixture-model"]
            )
        ))

        let slowCodexRuntime = HostedRuntimeRebindSlowCatalogRuntime()
        let providerRuntimeFactory = HostedRuntimeRebindProviderFactory()
        let codexAdapterID = RuntimeAdapterID("test.hosted-runtime-rebind.codex")
        let providerAdapterID = RuntimeAdapterID("test.hosted-runtime-rebind.provider")
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(id: codexAdapterID, displayName: "Codex") { _ in
                    slowCodexRuntime
                },
                RuntimeProviderDescriptor(
                    id: providerAdapterID,
                    displayName: "Provider"
                ) { _ in
                    providerRuntimeFactory.makeRuntime()
                },
            ],
            connections: [
                RuntimeConnectionRegistration(id: .codexDefault, adapterID: codexAdapterID),
                RuntimeConnectionRegistration(id: providerID, adapterID: providerAdapterID),
            ]
        )
        let host = OnyxApplicationHost(
            registry: registry,
            connectionID: .codexDefault,
            defaults: defaults,
            projectCatalogStore: ProjectCatalogStore(
                fileURL: directory.appendingPathComponent("projects.json")
            ),
            providerConnectionStore: providerStore,
            providerCredentialStore: InMemoryCredentialStore(),
            providerConversationStore: OpenAICompatibleConversationStore(
                fileURL: directory.appendingPathComponent("provider-conversations.json")
            )
        )
        await host.providerSettingsModel.reload()

        let windowID = WorkspaceWindowID()
        host.selectConnection(providerID, for: windowID)
        return HostedRuntimeRebindFixture(
            host: host,
            windowID: windowID,
            providerID: providerID,
            slowCodexRuntime: slowCodexRuntime,
            providerRuntimeFactory: providerRuntimeFactory,
            defaults: defaults,
            defaultsSuiteName: suiteName,
            temporaryDirectory: directory
        )
    }

    private func host<Content: View>(_ content: Content) -> HostedSwiftUIView {
        let size = NSSize(width: 1_100, height: 720)
        let hostingView = NSHostingView(
            rootView: AnyView(content.frame(width: size.width, height: size.height))
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        return HostedSwiftUIView(hostingView: hostingView, window: window)
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), failureMessage)
    }

    private func waitUntilAsync(
        _ failureMessage: String,
        timeout: Duration = .seconds(3),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let didMeetCondition = await condition()
        XCTAssertTrue(didMeetCondition, failureMessage)
    }
}

@MainActor
private struct HostedRuntimeRebindFixture {
    let host: OnyxApplicationHost
    let windowID: WorkspaceWindowID
    let providerID: ProviderConnectionID
    let slowCodexRuntime: HostedRuntimeRebindSlowCatalogRuntime
    let providerRuntimeFactory: HostedRuntimeRebindProviderFactory
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let temporaryDirectory: URL

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

@MainActor
private struct HostedSwiftUIView {
    let hostingView: NSHostingView<AnyView>
    let window: NSWindow

    func close() {
        window.contentView = nil
        window.close()
    }
}

/// `listAllThreads` remains suspended until SwiftUI cancels the stale refresh.
/// This models a slow provider/app-server catalog while still honoring the
/// cancellation contract expected by `.task(id:)`.
private final class HostedRuntimeRebindSlowCatalogRuntime: HostedRuntimeRebindRuntime, @unchecked Sendable {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated var events: AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    private let lock = NSLock()
    private var catalogRequestCount = 0
    private var activeCatalogRequestCount = 0
    private var finishedCatalogRequestCount = 0

    var blockedCatalogRequestCount: Int {
        lock.withLock { catalogRequestCount }
    }

    var hasBlockedCatalogRequest: Bool {
        lock.withLock { activeCatalogRequestCount > 0 }
    }

    var completedCatalogRequestCount: Int {
        lock.withLock { finishedCatalogRequestCount }
    }

    func connect() async throws -> RuntimeSession {
        RuntimeSession(
            runtime: .codex,
            displayName: "Codex",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: [.streaming]
        )
    }

    func disconnect() async {}

    func listThreads(limit: Int, archived _: Bool) async throws -> [RuntimeThread] {
        if limit == Int.max {
            lock.withLock {
                catalogRequestCount += 1
                activeCatalogRequestCount += 1
            }
            defer { lock.withLock { activeCatalogRequestCount -= 1 } }
            try await Task.sleep(for: .seconds(60))
            lock.withLock { finishedCatalogRequestCount += 1 }
        }
        return []
    }

}

private final class HostedRuntimeRebindProviderFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var createdRuntimeCount: Int { lock.withLock { count } }

    func makeRuntime() -> any AgentRuntime {
        let generation = lock.withLock { () -> Int in
            count += 1
            return count
        }
        return HostedRuntimeRebindProviderRuntime(generation: generation)
    }
}

private final class HostedRuntimeRebindProviderRuntime: HostedRuntimeRebindRuntime, @unchecked Sendable {
    nonisolated let kind = AgentRuntimeKind.local
    nonisolated var events: AsyncStream<AgentRuntimeEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    private let generation: Int

    init(generation: Int) {
        self.generation = generation
    }

    func connect() async throws -> RuntimeSession {
        RuntimeSession(
            runtime: .local,
            displayName: "Provider generation \(generation)",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: [.streaming]
        )
    }

    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] { [] }
}

private protocol HostedRuntimeRebindRuntime: AgentRuntime {}

private extension HostedRuntimeRebindRuntime {
    func disconnect() async {}

    func readThread(id _: String) async throws -> RuntimeConversation {
        throw AgentRuntimeError.missingField("thread")
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("test thread creation")
    }

    func startTurn(_: StartTurnRequest) async throws {}
    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}
}
