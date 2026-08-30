import XCTest
@testable import Onyx

final class PendingSteeringPresentationTests: XCTestCase {
    func testAcceptedQueueRemainsVisibleAfterTheTurnStops() {
        XCTAssertTrue(
            PendingSteeringPresentation.shouldShow(
                isTurnRunning: false,
                messageCount: 1
            )
        )
    }

    func testEmptyIdleOrWelcomeStateDoesNotMountQueueStrip() {
        XCTAssertFalse(
            PendingSteeringPresentation.shouldShow(
                isTurnRunning: false,
                messageCount: 0
            )
        )
    }

    func testActiveTurnMountsQueueStripEvenBeforeFirstMessageIsPublished() {
        XCTAssertTrue(
            PendingSteeringPresentation.shouldShow(
                isTurnRunning: true,
                messageCount: 0
            )
        )
    }

    func testQueueTitleUsesSingularAndPluralCopy() {
        XCTAssertEqual(PendingSteeringPresentation.title(for: 1), "Follow-up queued")
        XCTAssertEqual(PendingSteeringPresentation.title(for: 2), "2 follow-ups queued")
    }

    func testQueueStateCopyDistinguishesSubmissionFromAcceptedQueue() {
        XCTAssertEqual(
            PendingSteeringPresentation.stateLabel(for: .submitting),
            "Sending…"
        )
        XCTAssertEqual(
            PendingSteeringPresentation.stateLabel(for: .queued),
            "Queued for this response"
        )
    }

    func testImageOnlyFollowUpGetsAnExplicitPreview() {
        let message = PendingSteeringMessage(
            id: UUID(),
            threadID: "thread",
            text: "  \n",
            attachmentCount: 1,
            state: .queued
        )
        XCTAssertEqual(
            PendingSteeringPresentation.messagePreview(for: message),
            "Image follow-up"
        )
    }

    func testMultipleImageFollowUpPreviewIncludesCount() {
        let message = PendingSteeringMessage(
            id: UUID(),
            threadID: "thread",
            text: "",
            attachmentCount: 3,
            state: .queued
        )
        XCTAssertEqual(
            PendingSteeringPresentation.messagePreview(for: message),
            "3 image follow-ups"
        )
    }

    func testTextPreviewTrimsOnlyOuterWhitespace() {
        let message = PendingSteeringMessage(
            id: UUID(),
            threadID: "thread",
            text: "  Keep the current plan  ",
            attachmentCount: 0,
            state: .queued
        )
        XCTAssertEqual(
            PendingSteeringPresentation.messagePreview(for: message),
            "Keep the current plan"
        )
    }
}
