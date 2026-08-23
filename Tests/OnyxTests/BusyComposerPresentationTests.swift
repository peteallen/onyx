import XCTest
@testable import Onyx

final class BusyComposerPresentationTests: XCTestCase {
    func testActiveTaskWithAnEmptyDraftUsesCompactStrip() {
        XCTAssertTrue(usesCompactStrip(isTurnRunning: true))
        XCTAssertTrue(usesCompactStrip(isReviewRunning: true))
    }

    func testReviewStartupWaitsForAnInterruptibleTurn() {
        XCTAssertFalse(usesCompactStrip(isTurnRunning: true, isReviewStarting: true))
        XCTAssertFalse(usesCompactStrip(isReviewStarting: true))
    }

    func testContentAndRequiredInteractionKeepFullComposerAvailable() {
        XCTAssertFalse(usesCompactStrip(isTurnRunning: true, draftText: "Follow up"))
        XCTAssertFalse(usesCompactStrip(isTurnRunning: true, draftText: "  \n ", attachmentCount: 1))
        XCTAssertFalse(usesCompactStrip(isTurnRunning: true, hasPendingInteraction: true))
        XCTAssertFalse(usesCompactStrip(isTurnRunning: true, canInterrupt: false))
        XCTAssertFalse(usesCompactStrip(isTurnRunning: true, userRequestedExpansion: true))
    }

    func testIdleAndUnsafeNewTaskStartupDoNotCollapseComposer() {
        XCTAssertFalse(usesCompactStrip())
        XCTAssertFalse(usesCompactStrip(isTurnRunning: true, isComposingNewTask: true))
    }

    func testBusyLabelDistinguishesReviewWork() {
        XCTAssertEqual(
            BusyComposerPresentation.label(isReviewRunning: false, isReviewStarting: false),
            "Working on a response…"
        )
        XCTAssertEqual(
            BusyComposerPresentation.label(isReviewRunning: true, isReviewStarting: false),
            "Reviewing changes…"
        )
        XCTAssertEqual(
            BusyComposerPresentation.label(isReviewRunning: false, isReviewStarting: true),
            "Reviewing changes…"
        )
    }

    private func usesCompactStrip(
        isTurnRunning: Bool = false,
        isReviewRunning: Bool = false,
        isReviewStarting: Bool = false,
        hasPendingInteraction: Bool = false,
        draftText: String = "",
        attachmentCount: Int = 0,
        canInterrupt: Bool = true,
        isComposingNewTask: Bool = false,
        userRequestedExpansion: Bool = false
    ) -> Bool {
        BusyComposerPresentation.usesCompactStrip(
            isTurnRunning: isTurnRunning,
            isReviewRunning: isReviewRunning,
            isReviewStarting: isReviewStarting,
            hasPendingInteraction: hasPendingInteraction,
            draftText: draftText,
            attachmentCount: attachmentCount,
            canInterrupt: canInterrupt,
            isComposingNewTask: isComposingNewTask,
            userRequestedExpansion: userRequestedExpansion
        )
    }
}
