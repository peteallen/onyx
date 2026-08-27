import AppKit
import SwiftUI
import XCTest
@testable import Onyx

/// Hosted interaction coverage for the primary composer. Model-level
/// `canEditComposer` assertions do not prove that the native NSTextView can
/// become first responder or that input updates the SwiftUI binding; this is
/// the shortest regression for the user-visible "I cannot type" failure.
@MainActor
final class ComposerTypingInteractionTests: XCTestCase {
    func testNewTaskAlwaysAdvancesComposerFocusRequest() {
        let suiteName = "ComposerTypingInteractionTests.focus-request.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = OnyxAppModel(runtime: nil, defaults: defaults)
        let initialRequest = model.composerFocusRequest

        model.newTask()
        let firstRequest = model.composerFocusRequest
        model.newTask()

        XCTAssertNotEqual(firstRequest, initialRequest)
        XCTAssertNotEqual(model.composerFocusRequest, firstRequest)
    }

    func testCancellingProjectPickerReturnsFocusToActiveComposer() {
        let suiteName = "ComposerTypingInteractionTests.picker-cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = OnyxAppModel(runtime: nil, defaults: defaults)
        let initialRequest = model.composerFocusRequest

        model.resolveWorkspaceChoice(response: .cancel, path: nil)

        XCTAssertNotEqual(model.composerFocusRequest, initialRequest)
    }

    func testCancellingProjectPickerDoesNotLeaveLatentFocusInArchivedHistory() {
        let suiteName = "ComposerTypingInteractionTests.picker-cancel-archive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = OnyxAppModel(runtime: nil, defaults: defaults)
        model.threadListScope = .archived
        let initialRequest = model.composerFocusRequest

        model.resolveWorkspaceChoice(response: .cancel, path: nil)

        XCTAssertEqual(model.composerFocusRequest, initialRequest)
    }

    func testFocusedComposerAcceptsTypedTextAndUpdatesTheBoundDraft() async throws {
        let fixture = ComposerTypingFixture()
        let size = NSSize(width: 520, height: 120)
        let (hostingView, window) = makeHostedComposer(fixture: fixture, size: size)
        defer { close(window: window) }

        hostingView.layoutSubtreeIfNeeded()
        let textView: ComposerTextView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: ComposerTextView.self)
        )
        XCTAssertTrue(textView.isEditable)
        XCTAssertGreaterThan(textView.bounds.width, 0)
        XCTAssertGreaterThan(textView.bounds.height, 0)
        XCTAssertTrue(window.makeFirstResponder(textView))

        for (character, keyCode) in [("h", 4), ("e", 14), ("l", 37), ("l", 37), ("o", 31)] {
            try sendKey(character, keyCode: UInt16(keyCode), to: textView, window: window)
        }
        await settleMainRunLoop()
        XCTAssertEqual(fixture.text, "hello")
        XCTAssertEqual(textView.string, "hello")
    }

    func testExplicitFocusRequestMovesFocusFromAnotherControlIntoComposer() async throws {
        let fixture = ComposerTypingFixture()
        let size = NSSize(width: 520, height: 160)
        let hostingView = NSHostingView(rootView: ComposerTypingHarness(fixture: fixture))
        hostingView.frame = NSRect(x: 0, y: 40, width: size.width, height: 120)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(hostingView)
        let otherEditor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: size.width, height: 32))
        otherEditor.isEditable = true
        otherEditor.string = "Other control"
        container.addSubview(otherEditor)

        let window = ComposerTypingTestWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { close(window: window) }

        hostingView.layoutSubtreeIfNeeded()
        let textView: ComposerTextView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: ComposerTextView.self)
        )
        XCTAssertTrue(window.makeFirstResponder(otherEditor))
        XCTAssertTrue(window.firstResponder === otherEditor)

        fixture.focusRequest = UUID()
        await waitUntil("The explicit focus request did not move focus to the composer") {
            hostingView.layoutSubtreeIfNeeded()
            return window.firstResponder === textView
        }
        try sendKey("x", keyCode: 7, to: textView, window: window)
        await settleMainRunLoop()
        XCTAssertEqual(fixture.text, "x")
    }

    private func makeHostedComposer(
        fixture: ComposerTypingFixture,
        size: NSSize
    ) -> (NSHostingView<some View>, NSWindow) {
        let hostingView = NSHostingView(
            rootView: ComposerTypingHarness(fixture: fixture)
                .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = ComposerTypingTestWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        return (hostingView, window)
    }

    private func close(window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func sendKey(
        _ character: String,
        keyCode: UInt16,
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
            keyCode: keyCode
        ))
        textView.keyDown(with: event)
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), failureMessage)
    }

    private func settleMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class ComposerTypingFixture: ObservableObject {
    @Published var text = ""
    @Published var measuredHeight: CGFloat = 46
    @Published var focusRequest: UUID?
}

private struct ComposerTypingHarness: View {
    @ObservedObject var fixture: ComposerTypingFixture

    var body: some View {
        NativeComposerTextView(
            text: $fixture.text,
            measuredHeight: $fixture.measuredHeight,
            isEnabled: true,
            focusRequest: fixture.focusRequest,
            onSubmit: {},
            onPasteImages: { _ in }
        )
    }
}

private final class ComposerTypingTestWindow: NSWindow {
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
