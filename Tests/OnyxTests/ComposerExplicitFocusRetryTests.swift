import AppKit
import SwiftUI
import XCTest
@testable import Onyx

/// Exercises the AppKit handoff that occurs after New Task navigation. A
/// hosted editor can already have a window while that window is still
/// replacing its responder chain, in which case its first focus request may
/// be rejected even though the editor is otherwise ready.
@MainActor
final class ComposerExplicitFocusRetryTests: XCTestCase {
    func testTransientFocusRejectionRetriesOnceOnNextMainQueueTurn() async throws {
        let fixture = ComposerExplicitFocusRetryFixture()
        let (hostingView, window) = makeHostedComposer(fixture: fixture)
        defer { close(window) }

        hostingView.layoutSubtreeIfNeeded()
        let textView: ComposerTextView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: ComposerTextView.self)
        )
        window.rejectionMode = .firstComposerAttempt

        fixture.focusRequest = UUID()
        await waitUntil("The composer did not recover from its transient focus rejection") {
            hostingView.layoutSubtreeIfNeeded()
            return window.firstResponder === textView
        }

        XCTAssertEqual(window.composerFocusAttempts, 2)
        await settleMainQueue(turns: 3)
        XCTAssertEqual(
            window.composerFocusAttempts,
            2,
            "A successful retry must consume the request instead of focusing repeatedly"
        )
    }

    func testSecondFocusRejectionConsumesRequestWithoutUnboundedRetries() async throws {
        let fixture = ComposerExplicitFocusRetryFixture()
        let (hostingView, window) = makeHostedComposer(fixture: fixture)
        defer { close(window) }

        hostingView.layoutSubtreeIfNeeded()
        let textView: ComposerTextView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: ComposerTextView.self)
        )
        window.rejectionMode = .everyComposerAttempt

        fixture.focusRequest = UUID()
        await waitUntil("The bounded retry did not run") {
            hostingView.layoutSubtreeIfNeeded()
            return window.composerFocusAttempts == 2
        }
        XCTAssertFalse(window.firstResponder === textView)

        // Force another representable update. The exhausted request must not
        // wake up later and steal focus after unrelated state changes.
        fixture.text = "Unrelated update"
        await settleMainQueue(turns: 3)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.composerFocusAttempts, 2)
    }

    private func makeHostedComposer(
        fixture: ComposerExplicitFocusRetryFixture
    ) -> (NSHostingView<some View>, ComposerFocusRejectingWindow) {
        let size = NSSize(width: 520, height: 120)
        let hostingView = NSHostingView(
            rootView: ComposerExplicitFocusRetryHarness(fixture: fixture)
                .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = ComposerFocusRejectingWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        return (hostingView, window)
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
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

    private func settleMainQueue(turns: Int) async {
        for _ in 0..<turns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class ComposerExplicitFocusRetryFixture: ObservableObject {
    @Published var text = ""
    @Published var measuredHeight: CGFloat = 46
    @Published var focusRequest: UUID?
}

private struct ComposerExplicitFocusRetryHarness: View {
    @ObservedObject var fixture: ComposerExplicitFocusRetryFixture

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

private final class ComposerFocusRejectingWindow: NSWindow {
    enum RejectionMode {
        case none
        case firstComposerAttempt
        case everyComposerAttempt
    }

    var rejectionMode: RejectionMode = .none
    private(set) var composerFocusAttempts = 0

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard responder is ComposerTextView else {
            return super.makeFirstResponder(responder)
        }
        composerFocusAttempts += 1
        switch rejectionMode {
        case .none:
            return super.makeFirstResponder(responder)
        case .firstComposerAttempt where composerFocusAttempts == 1:
            return false
        case .firstComposerAttempt:
            return super.makeFirstResponder(responder)
        case .everyComposerAttempt:
            return false
        }
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
