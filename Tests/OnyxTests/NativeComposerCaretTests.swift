import AppKit
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class NativeComposerCaretTests: XCTestCase {
    func testPlaceholderOriginMatchesHostedInsertionPoint() throws {
        let textView = makeTextView()
        let window = host(textView)
        defer { release(window) }

        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let caretRect = textView.convert(
            textView.firstRect(
                forCharacterRange: NSRange(location: 0, length: 0),
                actualRange: nil
            ),
            from: nil
        )

        XCTAssertEqual(
            textView.placeholderOrigin.x,
            caretRect.minX,
            accuracy: 0.01
        )
        XCTAssertEqual(
            textView.placeholderOrigin.y,
            caretRect.minY,
            accuracy: 0.01
        )
    }

    func testPlaceholderUsesSameFirstLineGeometryAsTypedText() throws {
        let textView = makeTextView()
        let window = host(textView)
        defer { release(window) }

        let textContainer = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: textView.string.utf16.count),
            with: NSAttributedString(
                string: "D",
                attributes: [.font: try XCTUnwrap(textView.font)]
            )
        )
        layoutManager.ensureLayout(for: textContainer)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: 0, length: 1),
            in: textContainer
        )
        let typedOrigin = NSPoint(
            x: textView.textContainerOrigin.x + glyphRect.minX,
            y: textView.textContainerOrigin.y + glyphRect.minY
        )

        XCTAssertEqual(
            textView.placeholderOrigin.x,
            typedOrigin.x,
            accuracy: 0.01
        )
        XCTAssertEqual(
            textView.placeholderOrigin.y,
            typedOrigin.y,
            accuracy: 0.01
        )
    }

    func testWideComposerKeepsFullHitSurfaceWhileCappingLineMeasure() throws {
        let textView = makeTextView()
        textView.maximumTextContainerWidth = OnyxWorkspaceMetrics.maximumConversationTextWidth
        textView.setFrameSize(NSSize(width: 1_120, height: 80))

        let textContainer = try XCTUnwrap(textView.textContainer)
        XCTAssertEqual(textView.bounds.width, 1_120, accuracy: 0.1)
        XCTAssertEqual(
            textContainer.containerSize.width,
            OnyxWorkspaceMetrics.maximumConversationTextWidth,
            accuracy: 0.1
        )
        XCTAssertFalse(textContainer.widthTracksTextView)

        textView.setFrameSize(NSSize(width: 640, height: 80))
        XCTAssertEqual(
            textContainer.containerSize.width,
            640 - textView.textContainerInset.width * 2,
            accuracy: 0.1,
            "Compact composers should use the complete available line width"
        )
    }

    func testReturnSubmissionResignsBeforeSwiftUIReplacesComposer() async throws {
        let fixture = ComposerSubmitLifecycleFixture()
        let submitted = expectation(description: "Deferred composer submission")
        let focusRestorationSettled = expectation(description: "Removed composer stayed unfocused")
        let hostingView = NSHostingView(
            rootView: ComposerSubmitLifecycleHarness(
                fixture: fixture,
                replacesComposerAfterSubmit: true,
                onSubmit: {
                    submitted.fulfill()
                    DispatchQueue.main.async {
                        DispatchQueue.main.async {
                            focusRestorationSettled.fulfill()
                        }
                    }
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { release(window) }

        hostingView.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: ComposerTextView.self)
        )
        XCTAssertTrue(window.makeFirstResponder(textView))

        let keyDown = try returnKeyEvent(type: .keyDown, window: window)
        textView.keyDown(with: keyDown)
        textView.keyDown(with: keyDown)

        XCTAssertFalse(
            window.firstResponder === textView,
            "The editor must leave the responder chain before submission can remove its hosting node"
        )
        XCTAssertFalse(
            fixture.didSubmit,
            "Submission must wait until the key-down event has unwound"
        )

        await fulfillment(of: [submitted, focusRestorationSettled], timeout: 1)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(fixture.didSubmit)
        XCTAssertEqual(fixture.submitCount, 1)
        XCTAssertNil(hostingView.firstDescendant(ofType: ComposerTextView.self))
        XCTAssertFalse(window.firstResponder === textView)

        // Reproduce the matching key-up that previously reached a removed
        // NSHostingView responder node and crashed the app.
        window.sendEvent(try returnKeyEvent(type: .keyUp, window: window))
    }

    func testReturnSubmissionRestoresFocusWhenHostedComposerRemainsAvailable() async throws {
        let fixture = ComposerSubmitLifecycleFixture()
        let submitted = expectation(description: "Deferred composer submission")
        let hostingView = NSHostingView(
            rootView: ComposerSubmitLifecycleHarness(
                fixture: fixture,
                replacesComposerAfterSubmit: false,
                onSubmit: submitted.fulfill
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { release(window) }

        hostingView.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: ComposerTextView.self)
        )
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.keyDown(with: try returnKeyEvent(type: .keyDown, window: window))
        XCTAssertFalse(
            window.firstResponder === textView,
            "The crash-safe submit path must still resign before invoking SwiftUI"
        )

        await fulfillment(of: [submitted], timeout: 1)
        await waitForMainQueueTurns()
        XCTAssertFalse(
            window.firstResponder === textView,
            "The composer must stay unfocused until the matching Return key-up"
        )

        NSApplication.shared.sendEvent(try returnKeyEvent(type: .keyUp, window: window))
        await waitUntil("The surviving composer did not regain keyboard focus") {
            hostingView.layoutSubtreeIfNeeded()
            return window.firstResponder === textView
        }

        XCTAssertEqual(fixture.submitCount, 1)
        XCTAssertEqual(fixture.text, "")
        XCTAssertTrue(
            hostingView.firstDescendant(ofType: ComposerTextView.self) === textView,
            "Focus restoration should target the editor that survived submission"
        )

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testSurvivingComposerCanBeReplacedBeforeKeyUpWithoutReenteringResponderChain() async throws {
        let fixture = ComposerSubmitLifecycleFixture()
        let submitted = expectation(description: "Deferred composer submission")
        let hostingView = NSHostingView(
            rootView: ComposerSubmitLifecycleHarness(
                fixture: fixture,
                replacesComposerAfterSubmit: false,
                onSubmit: submitted.fulfill
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { release(window) }

        hostingView.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: ComposerTextView.self)
        )
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.keyDown(with: try returnKeyEvent(type: .keyDown, window: window))
        await fulfillment(of: [submitted], timeout: 1)
        await waitForMainQueueTurns()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            hostingView.firstDescendant(ofType: ComposerTextView.self) === textView,
            "The hosted composer should initially survive the submit update"
        )
        XCTAssertFalse(
            window.firstResponder === textView,
            "The surviving editor must not regain focus while Return is still down"
        )

        fixture.forceReplacement = true
        await waitUntil("The delayed busy-state update did not replace the composer") {
            hostingView.layoutSubtreeIfNeeded()
            return hostingView.firstDescendant(ofType: ComposerTextView.self) == nil
        }

        // This was the missing crash sequence: submit, initially survive,
        // replace on a later state update, then receive the original key-up.
        NSApplication.shared.sendEvent(try returnKeyEvent(type: .keyUp, window: window))
        XCTAssertNil(hostingView.firstDescendant(ofType: ComposerTextView.self))
        XCTAssertFalse(window.firstResponder === textView)
    }

    func testSwiftUIUpdateCannotRestoreFocusBeforeDeferredSubmission() async throws {
        let textView = makeTextView()
        let window = host(textView)
        defer { release(window) }
        let submitted = expectation(description: "Deferred submission completed")
        textView.onSubmit = submitted.fulfill
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.keyDown(with: try returnKeyEvent(type: .keyDown, window: window))
        textView.restoreFocusAfterSubmitIfAvailable()

        XCTAssertFalse(
            window.firstResponder === textView,
            "A SwiftUI update before the submit callback must not rearm the crash-prone responder chain"
        )
        await fulfillment(of: [submitted], timeout: 1)
        await waitForMainQueueTurns()
        XCTAssertFalse(
            window.firstResponder === textView,
            "Submission completion alone is not enough to restore focus before key-up"
        )
    }

    func testRejectedReturnKeepsFocusWithoutSubmitting() throws {
        let textView = makeTextView()
        let window = host(textView)
        defer { release(window) }
        var submitCount = 0
        textView.canSubmit = { false }
        textView.onSubmit = { submitCount += 1 }
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.keyDown(with: try returnKeyEvent(type: .keyDown, window: window))
        textView.keyUp(with: try returnKeyEvent(type: .keyUp, window: window))

        XCTAssertEqual(submitCount, 0)
        XCTAssertTrue(
            window.firstResponder === textView,
            "An empty or temporarily locked composer should keep its caret"
        )
    }

    func testSubmitDoesNotStealFocusFromAnotherControl() async throws {
        let composer = makeTextView()
        let otherEditor = makeTextView()
        otherEditor.frame.origin.y = 90
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        container.addSubview(composer)
        container.addSubview(otherEditor)

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { release(window) }

        let submitted = expectation(description: "Submission focused another control")
        composer.onSubmit = {
            XCTAssertTrue(window.makeFirstResponder(otherEditor))
            submitted.fulfill()
        }
        XCTAssertTrue(window.makeFirstResponder(composer))

        composer.keyDown(with: try returnKeyEvent(type: .keyDown, window: window))
        await fulfillment(of: [submitted], timeout: 1)
        NSApplication.shared.sendEvent(try returnKeyEvent(type: .keyUp, window: window))
        await waitForMainQueueTurns()

        XCTAssertTrue(window.firstResponder === otherEditor)
        XCTAssertFalse(window.firstResponder === composer)
    }

    private func makeTextView() -> ComposerTextView {
        let textView = ComposerTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 80)
        )
        textView.placeholder = "Describe what you want to build or change"
        textView.font = .systemFont(ofSize: OnyxTypography.reading)
        textView.textContainerInset = NSSize(width: 2, height: 7)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        return textView
    }

    private func host(_ textView: ComposerTextView) -> NSWindow {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 80)
        )
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func returnKeyEvent(type: NSEvent.EventType, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
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

    private func waitForMainQueueTurns(_ count: Int = 2) async {
        for _ in 0..<count {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func release(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class ComposerSubmitLifecycleFixture: ObservableObject {
    @Published var text = "Send this"
    @Published var measuredHeight: CGFloat = 46
    @Published var submitCount = 0
    @Published var forceReplacement = false

    var didSubmit: Bool { submitCount > 0 }
}

private struct ComposerSubmitLifecycleHarness: View {
    @ObservedObject var fixture: ComposerSubmitLifecycleFixture
    let replacesComposerAfterSubmit: Bool
    let onSubmit: () -> Void

    var body: some View {
        Group {
            if fixture.forceReplacement || (fixture.didSubmit && replacesComposerAfterSubmit) {
                Text("Working")
            } else {
                NativeComposerTextView(
                    text: $fixture.text,
                    measuredHeight: $fixture.measuredHeight,
                    isEnabled: true,
                    onSubmit: {
                        fixture.text = ""
                        fixture.submitCount += 1
                        onSubmit()
                    },
                    onPasteImages: { _ in }
                )
            }
        }
        .frame(width: 420, height: 120)
    }
}

private extension NSView {
    func firstDescendant<View: NSView>(ofType type: View.Type) -> View? {
        if let match = self as? View { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }
}
