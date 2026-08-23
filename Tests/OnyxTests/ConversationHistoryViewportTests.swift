import AppKit
import SwiftUI
import XCTest
@testable import Onyx

final class ConversationHistoryViewportTests: XCTestCase {
    @MainActor
    func testFinalEarlierPageDoesNotResizeOrMoveTranscriptViewport() throws {
        let fixture = ConversationHistoryViewportFixture()
        let hostingView = NSHostingView(
            rootView: ConversationHistoryViewportHarness(fixture: fixture)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        func layout() {
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            hostingView.layoutSubtreeIfNeeded()
        }

        layout()
        let collectionView = try XCTUnwrap(
            hostingView.historyFirstDescendant(ofType: NSCollectionView.self)
        )
        let scrollView = try XCTUnwrap(collectionView.enclosingScrollView)
        let scrollSuperview = try XCTUnwrap(scrollView.superview)
        let loadingFrame = hostingView.convert(scrollView.frame, from: scrollSuperview)

        fixture.isLoadingEarlierHistory = false
        fixture.canLoadEarlierHistory = false
        layout()

        let finalFrame = hostingView.convert(scrollView.frame, from: scrollSuperview)
        XCTAssertEqual(finalFrame.minY, loadingFrame.minY, accuracy: 0.5)
        XCTAssertEqual(finalFrame.height, loadingFrame.height, accuracy: 0.5)
        XCTAssertEqual(
            ConversationHistoryViewportLayout.affordanceHeight,
            OnyxHitTarget.compact + 4
        )
    }
}

@MainActor
private final class ConversationHistoryViewportFixture: ObservableObject {
    @Published var canLoadEarlierHistory = true
    @Published var isLoadingEarlierHistory = true

    let items = (0..<24).map { index in
        TimelineItem(
            id: "history-viewport-\(index)",
            kind: .assistantMessage,
            title: nil,
            body: "Message \(index)",
            status: .completed,
            timestamp: Date(timeIntervalSince1970: Double(index)),
            detail: nil
        )
    }
}

private struct ConversationHistoryViewportHarness: View {
    @ObservedObject var fixture: ConversationHistoryViewportFixture

    var body: some View {
        ConversationHistoryViewport(
            canLoadEarlierHistory: fixture.canLoadEarlierHistory,
            isLoadingEarlierHistory: fixture.isLoadingEarlierHistory,
            onLoadEarlierHistory: {}
        ) {
            NativeTranscriptView(items: fixture.items)
        }
    }
}

private extension NSView {
    func historyFirstDescendant<View: NSView>(ofType type: View.Type) -> View? {
        if let match = self as? View { return match }
        for subview in subviews {
            if let match = subview.historyFirstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }
}
