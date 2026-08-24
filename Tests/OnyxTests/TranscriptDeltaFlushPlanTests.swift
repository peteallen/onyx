import XCTest
@testable import Onyx

final class TranscriptDeltaFlushPlanTests: XCTestCase {
    func testLargeTranscriptBuildsOneIndexAndPreservesExistingAndMissingRows() {
        let items = (0..<50_000).map { index in
            TimelineItem(
                id: "history-\(index)",
                kind: .assistantMessage,
                title: nil,
                body: "History \(index)",
                status: .completed,
                timestamp: Date(timeIntervalSince1970: Double(index)),
                detail: nil
            )
        }
        let deltas = [
            TranscriptDeltaFlushPlan.Delta(itemID: "history-1", text: " first"),
            TranscriptDeltaFlushPlan.Delta(itemID: "history-25000", text: " middle"),
            TranscriptDeltaFlushPlan.Delta(itemID: "history-49999", text: " last"),
            TranscriptDeltaFlushPlan.Delta(itemID: "streaming-new", text: " new row"),
            TranscriptDeltaFlushPlan.Delta(itemID: "empty", text: ""),
        ]

        let plan = TranscriptDeltaFlushPlan.make(items: items, deltas: deltas)

        XCTAssertEqual(plan.inspectedItemCount, items.count)
        XCTAssertEqual(
            plan.existingUpdates,
            [
                .init(index: 1, text: " first"),
                .init(index: 25_000, text: " middle"),
                .init(index: 49_999, text: " last"),
            ]
        )
        XCTAssertEqual(
            plan.appendedUpdates,
            [.init(itemID: "streaming-new", text: " new row")]
        )
    }

    func testDuplicateTimelineIDsKeepTheSameFirstMatchAsTheOldFlushPath() {
        let items = [
            makeItem(id: "duplicate", body: "first"),
            makeItem(id: "duplicate", body: "second"),
        ]

        let plan = TranscriptDeltaFlushPlan.make(
            items: items,
            deltas: [.init(itemID: "duplicate", text: " delta")]
        )

        XCTAssertEqual(plan.existingUpdates, [.init(index: 0, text: " delta")])
        XCTAssertTrue(plan.appendedUpdates.isEmpty)
    }

    private func makeItem(id: String, body: String) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: .assistantMessage,
            title: nil,
            body: body,
            status: .completed,
            timestamp: .now,
            detail: nil
        )
    }
}
