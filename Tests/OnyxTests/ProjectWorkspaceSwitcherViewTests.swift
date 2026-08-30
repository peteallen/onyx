import AppKit
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class ProjectWorkspaceSwitcherViewTests: XCTestCase {
    func testHostedPaletteMountsAndAcceptsFocusBeforeProjectionCompletes() async throws {
        let worker = GatedWorkspaceSwitcherProjector(gatedQueries: [""])
        let projectionModel = ProjectWorkspaceSwitcherProjectionModel(worker: worker)
        let fixture = try makeFixture(
            projectionModel: projectionModel,
            worker: worker
        )
        defer {
            fixture.close()
            Task { await worker.releaseAll() }
        }

        fixture.hostingView.layoutSubtreeIfNeeded()
        await waitUntil("The switcher search field did not mount") {
            fixture.hostingView.layoutSubtreeIfNeeded()
            return fixture.searchField != nil
        }
        await waitUntil("The initial projection did not reach its gate") {
            await worker.isBlocked(query: "")
        }

        let searchField = try XCTUnwrap(fixture.searchField)
        XCTAssertTrue(projectionModel.isRefreshing)
        XCTAssertTrue(fixture.window.makeFirstResponder(searchField))
        XCTAssertTrue(fixture.window.firstResponder is NSTextView)
    }

    func testHostedReturnCannotActivateAStaleQueryResult() async throws {
        let worker = GatedWorkspaceSwitcherProjector(gatedQueries: ["beta"])
        let projectionModel = ProjectWorkspaceSwitcherProjectionModel(worker: worker)
        let fixture = try makeFixture(
            projectionModel: projectionModel,
            worker: worker
        )
        defer {
            fixture.close()
            Task { await worker.releaseAll() }
        }

        fixture.hostingView.layoutSubtreeIfNeeded()
        await waitUntil("The initial switcher projection did not publish") {
            !projectionModel.isRefreshing
                && projectionModel.projection.rows.contains { $0.task?.thread.id == "alpha" }
        }
        let searchField = try XCTUnwrap(fixture.searchField)
        XCTAssertTrue(fixture.window.makeFirstResponder(searchField))
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        editor.insertText("beta", replacementRange: editor.selectedRange())

        await waitUntil("The beta projection did not reach its gate") {
            await worker.isBlocked(query: "beta")
        }
        XCTAssertTrue(projectionModel.isRefreshing)
        XCTAssertFalse(projectionModel.canActivateCurrentProjection)

        try sendKey(code: 36, characters: "\r", to: fixture.window)
        XCTAssertTrue(
            fixture.activations.destinations.isEmpty,
            "Return during ranking must not open a row from the previous query."
        )

        await worker.release(query: "beta")
        await waitUntil("The beta projection did not publish") {
            !projectionModel.isRefreshing
                && projectionModel.projection.rows.first?.task?.thread.id == "beta"
        }
        fixture.hostingView.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.02)
        try sendKey(code: 36, characters: "\r", to: fixture.window)

        await waitUntil("Return did not open the current beta result") {
            fixture.activations.destinations.contains {
                if case let .openTask(_, threadID, _) = $0 {
                    return threadID == "beta"
                }
                return false
            }
        }
    }

    func testHostedArrowSelectionAnnouncesTheSelectedRowToVoiceOver() async throws {
        let worker = GatedWorkspaceSwitcherProjector(gatedQueries: [])
        let projectionModel = ProjectWorkspaceSwitcherProjectionModel(worker: worker)
        let fixture = try makeFixture(
            projectionModel: projectionModel,
            worker: worker
        )
        defer {
            fixture.close()
            Task { await worker.releaseAll() }
        }

        fixture.hostingView.layoutSubtreeIfNeeded()
        await waitUntil("The initial switcher projection did not publish") {
            !projectionModel.isRefreshing && !projectionModel.projection.rows.isEmpty
        }
        let searchField = try XCTUnwrap(fixture.searchField)
        XCTAssertTrue(fixture.window.makeFirstResponder(searchField))

        try sendKey(code: 125, characters: "\u{F701}", to: fixture.window)

        await waitUntil("Arrow selection was not announced") {
            !fixture.announcements.messages.isEmpty
        }
        let message = try XCTUnwrap(fixture.announcements.messages.last)
        let expectedID = projectionModel.projection.movingSelection(
            from: projectionModel.projection.initialSelectionID,
            direction: .next
        )
        let expectedTitle = projectionModel.projection.rows.first(where: {
            $0.id == expectedID
        })?.title
        XCTAssertTrue(message.hasPrefix("Selected "))
        XCTAssertTrue(
            expectedTitle.map(message.contains) == true,
            "VoiceOver should receive the title of the newly selected row."
        )
    }

    private func makeFixture(
        projectionModel: ProjectWorkspaceSwitcherProjectionModel,
        worker _: GatedWorkspaceSwitcherProjector
    ) throws -> HostedWorkspaceSwitcherFixture {
        let project = ProjectCatalogRecord(
            id: ProjectID("onyx"),
            folderPath: "/work/onyx",
            displayName: "Onyx",
            order: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let alpha = reference(id: "alpha", title: "Alpha task", project: project)
        let beta = reference(id: "beta", title: "Beta task", project: project)
        let request = ProjectWorkspaceSwitcherRequest(
            projects: [project],
            activeTasks: [alpha, beta],
            selectedProjectID: project.id,
            selectedWorkspacePath: project.folderPath,
            selectedTaskID: alpha.id
        )
        let revision = ProjectWorkspaceSwitcherSourceRevision(
            projectRevision: 1,
            taskRevision: 1,
            scope: .active,
            providerConnectionID: .codexDefault,
            selectedThreadID: "alpha",
            selectedWorkspacePath: project.folderPath
        )
        let suiteName = "ProjectWorkspaceSwitcherViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let stateModel = ProjectWorkspaceSwitcherStateModel(
            defaults: defaults,
            preferenceKey: "state"
        )
        let activations = WorkspaceSwitcherActivationRecorder()
        let announcements = WorkspaceSwitcherAnnouncementRecorder()
        let size = NSSize(width: 900, height: 680)
        let hostingView = NSHostingView(
            rootView: AnyView(ProjectWorkspaceSwitcherView(
                baseRequest: request,
                sourceRevision: revision,
                focusRequest: 1,
                stateModel: stateModel,
                dismiss: {},
                activate: { activations.destinations.append($0) },
                projectionModel: projectionModel,
                announce: { announcements.messages.append($0) }
            )
            .frame(width: size.width, height: size.height))
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = WorkspaceSwitcherTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        return HostedWorkspaceSwitcherFixture(
            suiteName: suiteName,
            defaults: defaults,
            hostingView: hostingView,
            window: window,
            activations: activations,
            announcements: announcements
        )
    }

    private func reference(
        id: String,
        title: String,
        project: ProjectCatalogRecord
    ) -> ProjectTaskReference {
        ProjectTaskReference(
            providerConnectionID: .codexDefault,
            providerDisplayName: "Codex",
            thread: RuntimeThread(
                id: id,
                title: title,
                preview: "Preview for \(title)",
                cwd: project.folderPath,
                updatedAt: Date(timeIntervalSince1970: id == "alpha" ? 2 : 1),
                status: .idle,
                isPinned: false,
                runtime: .codex,
                model: nil,
                branch: nil
            )
        )
    }

    private func sendKey(code: UInt16, characters: String, to window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
        window.sendEvent(event)
        pumpMainRunLoop(for: 0.005)
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let didSatisfyCondition = await condition()
        XCTAssertTrue(didSatisfyCondition, failureMessage)
    }

    private func pumpMainRunLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

@MainActor
private final class WorkspaceSwitcherActivationRecorder {
    var destinations: [ProjectWorkspaceSwitcherRow.Destination] = []
}

@MainActor
private final class WorkspaceSwitcherAnnouncementRecorder {
    var messages: [String] = []
}

private actor GatedWorkspaceSwitcherProjector: ProjectWorkspaceSwitcherProjectionProviding {
    private let gatedQueries: Set<String>
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedQueries: Set<String> = []

    init(gatedQueries: Set<String>) {
        self.gatedQueries = gatedQueries
    }

    func make(
        _ request: ProjectWorkspaceSwitcherRequest
    ) async -> ProjectWorkspaceSwitcherProjection? {
        if gatedQueries.contains(request.query) {
            blockedQueries.insert(request.query)
            await withCheckedContinuation { continuation in
                continuations[request.query, default: []].append(continuation)
            }
        }
        guard !Task.isCancelled else { return nil }
        return ProjectWorkspaceSwitcherProjection.make(request)
    }

    func isBlocked(query: String) -> Bool {
        blockedQueries.contains(query)
    }

    func release(query: String) {
        blockedQueries.remove(query)
        let waiting = continuations.removeValue(forKey: query) ?? []
        waiting.forEach { $0.resume() }
    }

    func releaseAll() {
        blockedQueries.removeAll()
        let waiting = continuations.values.flatMap { $0 }
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private final class WorkspaceSwitcherTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private struct HostedWorkspaceSwitcherFixture {
    let suiteName: String
    let defaults: UserDefaults
    let hostingView: NSHostingView<AnyView>
    let window: NSWindow
    let activations: WorkspaceSwitcherActivationRecorder
    let announcements: WorkspaceSwitcherAnnouncementRecorder

    var searchField: NSTextField? {
        hostingView.firstDescendantTextField(
            withPlaceholder: "Search projects, worktrees, tasks, branches…"
        )
    }

    func close() {
        window.contentView = nil
        window.close()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private extension NSView {
    func firstDescendantTextField(withPlaceholder placeholder: String) -> NSTextField? {
        if let textField = self as? NSTextField,
           textField.placeholderString == placeholder {
            return textField
        }
        for subview in subviews {
            if let match = subview.firstDescendantTextField(withPlaceholder: placeholder) {
                return match
            }
        }
        return nil
    }
}
