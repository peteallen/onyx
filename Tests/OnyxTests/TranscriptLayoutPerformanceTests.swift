import AppKit
import XCTest
@testable import Onyx

final class TranscriptLayoutPerformanceTests: XCTestCase {
    func testUnchangedSnapshotReusesEveryMeasuredHeight() {
        let items = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
            makeItem(id: "three", body: "Third"),
        ]
        var state = TranscriptLayoutState()
        XCTAssertFalse(state.readableWidthDidChange(to: 640))
        _ = measure(items, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: items, to: items)
        XCTAssertEqual(update, .unchanged)
        state.prepare(for: update, newItems: items)
        _ = measure(items, width: 640, state: &state)

        XCTAssertEqual(state.instrumentation.measurementCount, 3)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 3)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 0)
    }

    func testTailStreamingInvalidatesAndMeasuresOnlyTheTailRow() {
        let oldItems = [
            makeItem(id: "one", body: "Stable one"),
            makeItem(id: "two", body: "Stable two"),
            makeItem(id: "stream", body: "Partial"),
        ]
        var newItems = oldItems
        newItems[2].body = "Partial response with the next streamed delta"
        var state = TranscriptLayoutState()
        _ = state.readableWidthDidChange(to: 640)
        _ = measure(oldItems, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: oldItems, to: newItems)
        XCTAssertEqual(update, .tailChange(2))
        state.prepare(for: update, newItems: newItems)
        _ = measure(newItems, width: 640, state: &state)

        XCTAssertEqual(state.instrumentation.measurementCount, 4)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 2)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 1)
    }

    func testAppendMeasuresOnlyNewRows() {
        let oldItems = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
        ]
        let newItems = oldItems + [makeItem(id: "three", body: "Third")]
        var state = TranscriptLayoutState()
        _ = state.readableWidthDidChange(to: 640)
        _ = measure(oldItems, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: oldItems, to: newItems)
        XCTAssertEqual(update, .append(2..<3))
        state.prepare(for: update, newItems: newItems)
        _ = measure(newItems, width: 640, state: &state)

        XCTAssertEqual(state.instrumentation.measurementCount, 3)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 2)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 0)
    }

    func testSameIdentityEditsInvalidateOnlyTheirRows() {
        let oldItems = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
            makeItem(id: "three", body: "Third"),
            makeItem(id: "four", body: "Fourth"),
        ]
        var newItems = oldItems
        newItems[0].body += " changed"
        newItems[2].detail = "Changed detail"
        var state = TranscriptLayoutState()
        _ = state.readableWidthDidChange(to: 640)
        _ = measure(oldItems, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: oldItems, to: newItems)
        XCTAssertEqual(update, .rowChanges(IndexSet([0, 2])))
        state.prepare(for: update, newItems: newItems)
        _ = measure(newItems, width: 640, state: &state)

        XCTAssertEqual(state.instrumentation.measurementCount, 6)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 2)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 2)
    }

    func testReorderUsesSafeReloadWhileRetainingIdentityCorrectHeights() {
        let oldItems = [
            makeItem(id: "short", body: "A"),
            makeItem(id: "medium", body: "A medium body"),
            makeItem(id: "long", body: "A substantially longer body for this row"),
        ]
        let reordered = [oldItems[2], oldItems[0], oldItems[1]]
        var state = TranscriptLayoutState()
        _ = state.readableWidthDidChange(to: 640)
        let originalHeights = measure(oldItems, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: oldItems, to: reordered)
        XCTAssertEqual(update, .reloadAll)
        state.prepare(for: update, newItems: reordered)
        let reorderedHeights = measure(reordered, width: 640, state: &state)

        XCTAssertEqual(reorderedHeights, [originalHeights[2], originalHeights[0], originalHeights[1]])
        XCTAssertEqual(state.instrumentation.measurementCount, 3)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 3)
        XCTAssertEqual(
            TranscriptCollectionUpdate.plan(from: oldItems, to: Array(oldItems.dropLast())),
            .reloadAll
        )

        var middleInsertion = oldItems
        middleInsertion.insert(makeItem(id: "inserted", body: "Inserted"), at: 1)
        XCTAssertEqual(
            TranscriptCollectionUpdate.plan(from: oldItems, to: middleInsertion),
            .reloadAll
        )
    }

    func testOnlyARealReadableWidthChangeGloballyInvalidatesHeights() {
        let items = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
        ]
        var state = TranscriptLayoutState()

        XCTAssertFalse(state.readableWidthDidChange(to: 640))
        _ = measure(items, width: 640, state: &state)
        XCTAssertFalse(state.readableWidthDidChange(to: 640))
        _ = measure(items, width: 640, state: &state)
        XCTAssertEqual(state.instrumentation.measurementCount, 2)
        XCTAssertEqual(state.instrumentation.globalInvalidationCount, 0)

        XCTAssertTrue(state.readableWidthDidChange(to: 600))
        _ = measure(items, width: 600, state: &state)
        XCTAssertEqual(state.instrumentation.measurementCount, 4)
        XCTAssertEqual(state.instrumentation.globalInvalidationCount, 1)
        XCTAssertFalse(state.readableWidthDidChange(to: 600))
        XCTAssertEqual(state.instrumentation.globalInvalidationCount, 1)
    }

    func testRevisionBoundTailHintsKeepLargeHistoryPlanningBounded() {
        var oldItems = (0..<20_000).map { index in
            makeItem(id: "item-\(index)", body: "Stable \(index)")
        }
        var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()
        var revision: UInt64 = 10

        for delta in 0..<100 {
            var newItems = oldItems
            newItems[newItems.count - 1].body += " delta-\(delta)"
            let nextRevision = revision + 1
            let update = TranscriptCollectionUpdate.plan(
                from: oldItems,
                to: newItems,
                oldRevision: revision,
                newRevision: nextRevision,
                hint: .rowsChanged(
                    indices: IndexSet(integer: newItems.count - 1),
                    fromRevision: revision,
                    toRevision: nextRevision
                ),
                instrumentation: &instrumentation
            )

            XCTAssertEqual(update, .tailChange(newItems.count - 1))
            oldItems = newItems
            revision = nextRevision
        }

        XCTAssertEqual(instrumentation.inspectedItemCount, 100)
        XCTAssertEqual(instrumentation.hintedUpdateCount, 100)
    }

    func testHintWithBrokenRevisionContinuityFallsBackToStructuralPlanning() {
        let oldItems = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
            makeItem(id: "three", body: "Third"),
        ]
        let reordered = [oldItems[2], oldItems[1], oldItems[0]]
        var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()

        let update = TranscriptCollectionUpdate.plan(
            from: oldItems,
            to: reordered,
            oldRevision: 4,
            newRevision: 5,
            hint: .rowsChanged(
                indices: IndexSet(integer: 2),
                fromRevision: 3,
                toRevision: 5
            ),
            instrumentation: &instrumentation
        )

        XCTAssertEqual(update, .reloadAll)
        XCTAssertEqual(instrumentation.hintedUpdateCount, 0)
    }

    private func measure(
        _ items: [TimelineItem],
        width: CGFloat,
        state: inout TranscriptLayoutState
    ) -> [CGFloat] {
        var heights: [CGFloat] = []
        heights.reserveCapacity(items.count)
        for item in items {
            heights.append(
                state.height(for: item, width: width) {
                    CGFloat(item.body.utf8.count) + width / 100
                }
            )
        }
        return heights
    }

    private func makeItem(id: String, body: String) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: .assistantMessage,
            title: nil,
            body: body,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1_000),
            detail: nil
        )
    }
}
