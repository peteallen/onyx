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

    func testReturnSubmissionResignsBeforeSwiftUIReplacesComposer() async throws {
        let fixture = ComposerSubmitLifecycleFixture()
        let submitted = expectation(description: "Deferred composer submission")
        let hostingView = NSHostingView(
            rootView: ComposerSubmitLifecycleHarness(
                fixture: fixture,
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

        await fulfillment(of: [submitted], timeout: 1)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(fixture.didSubmit)
        XCTAssertEqual(fixture.submitCount, 1)
        XCTAssertNil(hostingView.firstDescendant(ofType: ComposerTextView.self))

        // Reproduce the matching key-up that previously reached a removed
        // NSHostingView responder node and crashed the app.
        window.sendEvent(try returnKeyEvent(type: .keyUp, window: window))
    }

    private func makeTextView() -> ComposerTextView {
        let textView = ComposerTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 80)
        )
        textView.placeholder = "Describe what you want to build or change"
        textView.font = .systemFont(ofSize: 14.5)
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

    var didSubmit: Bool { submitCount > 0 }
}

private struct ComposerSubmitLifecycleHarness: View {
    @ObservedObject var fixture: ComposerSubmitLifecycleFixture
    let onSubmit: () -> Void

    var body: some View {
        Group {
            if fixture.didSubmit {
                Text("Working")
            } else {
                NativeComposerTextView(
                    text: $fixture.text,
                    measuredHeight: $fixture.measuredHeight,
                    isEnabled: true,
                    onSubmit: {
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
