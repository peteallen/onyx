import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Onyx

/// Regression coverage for typing while a long-lived task catalog is mounted.
///
/// The sidebar and workspace root observe only `OnyxAppModel`. The native
/// composer is a nested view that observes `OnyxComposerDraftModel`, so draft
/// publications cannot invalidate the 4,824-task sidebar on every keystroke.
@MainActor
final class ComposerTypingLatencyTests: XCTestCase {
    func testComposerTypingDoesNotInvalidateLargeHistorySidebar() async throws {
        let suiteName = "ComposerTypingLatencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tasks = Self.makeTasks(count: 4_824)
        let model = OnyxAppModel(runtime: nil, defaults: defaults)
        model.connectionState = .connected("Latency fixture")
        model.authState = RuntimeAuthState(
            mode: nil,
            email: nil,
            planLabel: nil,
            requiresAuthentication: false
        )
        model.threads = tasks
        model.selectedThreadID = try XCTUnwrap(tasks.first?.id)

        let sidebarRenderProbe = ComposerRenderProbe()
        let composerRenderProbe = ComposerRenderProbe()
        let root = LargeHistoryComposerIsolationHarness(
            model: model,
            tasks: tasks,
            sidebarRenderProbe: sidebarRenderProbe,
            composerRenderProbe: composerRenderProbe
        )
        let size = NSSize(width: 1_000, height: 720)
        let hostingView = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = ComposerLatencyTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        // Wait for the initial hosted root render, then exercise New Task's
        // focus handoff before taking any typing samples.
        hostingView.layoutSubtreeIfNeeded()
        await waitUntil("The large-history sidebar did not mount") {
            sidebarRenderProbe.count > 0
        }
        model.newTask()
        let composer = try await waitForComposer(in: hostingView)
        await waitUntil("New Task did not focus the composer") {
            window.firstResponder === composer
        }

        // Ignore the model publication caused by New Task itself. From this
        // point on, only draft text changes are under test.
        await settleMainRunLoop()
        let baselineSidebarRenders = sidebarRenderProbe.count
        let baselineComposerRenders = composerRenderProbe.count
        var modelPublicationCount = 0
        var draftPublicationCount = 0
        var cancellables = Set<AnyCancellable>()
        model.objectWillChange
            .sink { _ in modelPublicationCount += 1 }
            .store(in: &cancellables)
        model.composerDraftModel.objectWillChange
            .sink { _ in draftPublicationCount += 1 }
            .store(in: &cancellables)

        let input = "type-with-large-history"
        var observedDurations: [Duration] = []
        observedDurations.reserveCapacity(input.count)

        for character in input {
            let expected = model.composerDraftModel.text + String(character)
            let start = ContinuousClock.now
            try sendKey(String(character), to: composer, window: window)

            let expectedComposerRenders = baselineComposerRenders + observedDurations.count + 1
            let deadline = start.advanced(by: .milliseconds(250))
            while (model.composerDraftModel.text != expected
                || composerRenderProbe.count < expectedComposerRenders),
                  ContinuousClock.now < deadline {
                pumpMainRunLoop(for: 0.001)
                hostingView.layoutSubtreeIfNeeded()
            }
            observedDurations.append(start.duration(to: ContinuousClock.now))

            XCTAssertEqual(model.composerDraftModel.text, expected)
            XCTAssertGreaterThanOrEqual(
                composerRenderProbe.count,
                expectedComposerRenders,
                "The composer child did not render the update for '\(character)'"
            )
            XCTAssertEqual(
                sidebarRenderProbe.count,
                baselineSidebarRenders,
                "A draft keystroke invalidated the large-history sidebar"
            )
        }

        XCTAssertEqual(model.composerDraftModel.text, input)
        XCTAssertEqual(modelPublicationCount, 0)
        XCTAssertEqual(
            draftPublicationCount,
            input.count,
            "Each native key should publish exactly one isolated draft update"
        )
        let worst = observedDurations.max() ?? .zero
        XCTAssertLessThan(
            worst,
            .milliseconds(200),
            "A character update exceeded the responsive-host budget: \(observedDurations)"
        )
    }

    private static func makeTasks(count: Int) -> [RuntimeThread] {
        (0..<count).map { index in
            RuntimeThread(
                id: "latency-task-\(index)",
                title: "Latency task \(index)",
                preview: "A realistic long-lived task history",
                cwd: "/work/project-\(index % 224)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                status: .idle,
                isPinned: false,
                runtime: .codex,
                model: "test-model",
                branch: nil
            )
        }
    }

    private func waitForComposer(
        in hostingView: NSView,
        timeout: Duration = .seconds(1)
    ) async throws -> ComposerTextView {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            if let composer = hostingView.firstDescendant(ofType: ComposerTextView.self) {
                return composer
            }
            pumpMainRunLoop(for: 0.001)
            await Task.yield()
        }
        return try XCTUnwrap(
            hostingView.firstDescendant(ofType: ComposerTextView.self),
            "The hosted workspace did not mount its native composer"
        )
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            pumpMainRunLoop(for: 0.001)
            await Task.yield()
        }
        XCTAssertTrue(condition(), failureMessage)
    }

    private func settleMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func pumpMainRunLoop(for seconds: TimeInterval) {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: seconds))
    }

    private func sendKey(
        _ character: String,
        to textView: ComposerTextView,
        window: NSWindow
    ) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ))
        textView.keyDown(with: event)
    }
}

/// Root/sidebar observation stays on `OnyxAppModel`; only the nested composer
/// observes its draft child. Keeping the child observation below this view is
/// the key part of the regression—adding `@ObservedObject draft` here would
/// recreate the original whole-workspace invalidation.
private struct LargeHistoryComposerIsolationHarness: View {
    @ObservedObject var model: OnyxAppModel
    let tasks: [RuntimeThread]
    let sidebarRenderProbe: ComposerRenderProbe
    let composerRenderProbe: ComposerRenderProbe

    var body: some View {
        HStack(spacing: 0) {
            LargeHistorySidebarProbe(
                model: model,
                tasks: tasks,
                renderProbe: sidebarRenderProbe
            )
            .frame(width: 280)

            IsolatedComposerSurface(
                draft: model.composerDraftModel,
                renderProbe: composerRenderProbe
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)
        }
    }
}

/// A deterministic catalog-sized sidebar probe. It intentionally walks all
/// rows whenever the app model publishes, making an accidental draft
/// subscription visible in both render counts and elapsed key latency.
private struct LargeHistorySidebarProbe: View {
    @ObservedObject var model: OnyxAppModel
    let tasks: [RuntimeThread]
    let renderProbe: ComposerRenderProbe

    var body: some View {
        let checksum = tasks.reduce(into: 0) { partial, task in
            partial = partial &+ task.id.utf8.reduce(0) { $0 &+ Int($1) }
        }
        renderProbe.record()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tasks")
            Text("\(model.catalogThreads.count)")
                .accessibilityLabel("Task count")
            Text("\(checksum)").hidden()
        }
    }
}

/// The child owns the draft observation and native text view. The parent root
/// never stores this as an observed property, so typing cannot invalidate the
/// sidebar probe above.
private struct IsolatedComposerSurface: View {
    @ObservedObject var draft: OnyxComposerDraftModel
    let renderProbe: ComposerRenderProbe
    @State private var measuredHeight: CGFloat = 46

    var body: some View {
        renderProbe.record()
        return NativeComposerTextView(
            text: $draft.text,
            measuredHeight: $measuredHeight,
            isEnabled: true,
            focusRequest: draft.focusRequest,
            onSubmit: {},
            onPasteImages: { _ in }
        )
    }
}

@MainActor
private final class ComposerRenderProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private final class ComposerLatencyTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension NSView {
    func firstDescendant<View: NSView>(ofType type: View.Type) -> View? {
        if let match = self as? View { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
