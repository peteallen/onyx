import XCTest
@testable import Onyx

final class TranscriptActivityGroupingTests: XCTestCase {
    @MainActor
    func testActivityRollupBodyIsARealClickTarget() throws {
        let group = TranscriptActivityGroup(
            id: "activity-group:first",
            range: 0..<2,
            itemIDs: ["first", "second"],
            title: "Ran commands",
            summary: "2 activities"
        )
        var toggles: [Bool] = []
        let row = TranscriptActivityGroupView(
            frame: NSRect(x: 0, y: 0, width: 640, height: TranscriptActivityGroupView.rowHeight)
        )
        row.configure(group: group, isExpanded: false) { toggles.append($0) }
        row.layoutSubtreeIfNeeded()

        XCTAssertLessThan(row.expansionControl.frame.maxX, row.bounds.midX)
        XCTAssertEqual(
            row.accessibilityValue() as? String,
            "Completed, 2 activities, Collapsed"
        )
        XCTAssertTrue(row.hitTest(NSPoint(x: 120, y: 17)) === row)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 120, y: 17),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        row.mouseDown(with: event)

        XCTAssertTrue(row.isExpanded)
        XCTAssertEqual(toggles, [true])
        XCTAssertEqual(
            row.accessibilityValue() as? String,
            "Completed, 2 activities, Expanded"
        )
    }

    func testGroupsAdjacentCompletedRoutineActivityIntoOneSummary() {
        let items = [
            item(id: "reasoning", kind: .reasoning, title: "Reasoned"),
            item(id: "command", kind: .command, title: "git status"),
            item(id: "file", kind: .fileChange, title: "Updated file"),
            item(id: "assistant", kind: .assistantMessage, title: nil),
        ]

        let groups = TranscriptActivityGrouping.groups(for: items)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].range, 0..<3)
        XCTAssertEqual(groups[0].itemIDs, ["reasoning", "command", "file"])
        XCTAssertEqual(groups[0].title, "Ran commands, changed files, reasoned")
        XCTAssertEqual(groups[0].summary, "3 activities")
    }

    func testLeavesLiveExceptionalAndCollaborationRowsIndependent() {
        let collaboration = RuntimeCollaborationActivity(
            action: .spawn,
            agents: [
                RuntimeCollaborationAgent(
                    id: "agent",
                    path: nil,
                    status: .working,
                    message: nil,
                    updatedAt: .now
                ),
            ]
        )
        let items = [
            item(id: "completed", kind: .command, title: "ls"),
            item(id: "running", kind: .tool, title: "Running", status: .running),
            item(id: "agent", kind: .tool, title: "Started agent", collaboration: collaboration),
            item(id: "failed", kind: .reasoning, title: "Failed", status: .failed),
            item(id: "completed-2", kind: .fileChange, title: "Changed"),
        ]

        let groups = TranscriptActivityGrouping.groups(for: items)

        XCTAssertTrue(groups.isEmpty, "Separated or exceptional rows must not be hidden in a rollup")
    }

    func testGroupSizeIsBounded() {
        let items = (0..<12).map { index in
            item(id: "command-\(index)", kind: .command, title: "command \(index)")
        }

        let groups = TranscriptActivityGrouping.groups(for: items)

        XCTAssertEqual(groups.map(\.count), [8, 4])
    }

    func testOversizedLeadingActivityRemainsIndependentEvenWhenFollowedByEmptyOutput() {
        let oversized = TimelineItem(
            id: "oversized",
            kind: .tool,
            title: "Large result",
            body: String(repeating: "x", count: TranscriptActivityGrouping.maximumBodyBytesPerGroup + 1),
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        let empty = TimelineItem(
            id: "empty",
            kind: .tool,
            title: "Empty result",
            body: "",
            status: .completed,
            timestamp: .now,
            detail: nil
        )

        XCTAssertTrue(TranscriptActivityGrouping.groups(for: [oversized, empty]).isEmpty)
        XCTAssertEqual(
            TranscriptActivityGrouping.groups(for: [empty, oversized]).first?.itemIDs,
            ["empty", "oversized"],
            "The bounded byte check must preserve the original greedy grouping semantics"
        )
    }

    func testAppendRescansOnlyTheMutableTailInsteadOfTheCompleteHistory() throws {
        let stableHistory = (0..<10_000).map { index in
            item(id: "message-\(index)", kind: .assistantMessage, title: nil)
        }
        let oldItems = stableHistory + (0..<7).map { index in
            item(id: "command-\(index)", kind: .command, title: "command \(index)")
        }
        let newItems = oldItems + (7..<9).map { index in
            item(id: "command-\(index)", kind: .command, title: "command \(index)")
        }
        var groups = TranscriptActivityGrouping.groups(for: oldItems)
        var instrumentation = TranscriptActivityGrouping.AppendInstrumentation()

        let result = try XCTUnwrap(
            TranscriptActivityGrouping.append(
                to: &groups,
                oldItems: oldItems,
                newItems: newItems,
                appendedRange: oldItems.count..<newItems.count,
                instrumentation: &instrumentation
            )
        )

        XCTAssertEqual(result.itemStart, stableHistory.count)
        XCTAssertLessThanOrEqual(
            instrumentation.inspectedItemCount,
            TranscriptActivityGrouping.maximumItemsPerGroup + 1
        )
        XCTAssertEqual(groups, TranscriptActivityGrouping.groups(for: newItems))
    }

    func testAppendCanRollUpOnePreviouslyIndependentTailActivity() throws {
        let oldItems = [
            item(id: "assistant", kind: .assistantMessage, title: nil),
            item(id: "command", kind: .command, title: "First command"),
        ]
        let newItems = oldItems + [
            item(id: "file", kind: .fileChange, title: "Changed file"),
        ]
        var groups = TranscriptActivityGrouping.groups(for: oldItems)

        let result = try XCTUnwrap(
            TranscriptActivityGrouping.append(
                to: &groups,
                oldItems: oldItems,
                newItems: newItems,
                appendedRange: oldItems.count..<newItems.count
            )
        )

        XCTAssertEqual(result.itemStart, 1)
        XCTAssertEqual(groups, TranscriptActivityGrouping.groups(for: newItems))
        XCTAssertEqual(groups.first?.itemIDs, ["command", "file"])
    }

    func testCompletingTailActivityReprojectsOnlyMutableTail() throws {
        let stableHistory = (0..<10_000).map { index in
            item(id: "message-\(index)", kind: .assistantMessage, title: nil)
        }
        let completedActivities = (0..<8).map { index in
            item(id: "command-\(index)", kind: .command, title: "command \(index)")
        }
        let oldItems = stableHistory + completedActivities + [
            item(id: "live-tool", kind: .tool, title: "Live tool", status: .running),
        ]
        var completedTool = oldItems.last!
        completedTool.status = .completed
        let newItems = Array(oldItems.dropLast()) + [completedTool]
        var groups = TranscriptActivityGrouping.groups(for: oldItems)
        var instrumentation = TranscriptActivityGrouping.AppendInstrumentation()

        let result = try XCTUnwrap(
            TranscriptActivityGrouping.replaceChangedTail(
                in: &groups,
                oldItems: oldItems,
                newItems: newItems,
                changedIndex: newItems.count - 1,
                instrumentation: &instrumentation
            )
        )

        XCTAssertEqual(result.itemStart, stableHistory.count)
        XCTAssertLessThanOrEqual(
            instrumentation.inspectedItemCount,
            TranscriptActivityGrouping.maximumItemsPerGroup + 1
        )
        XCTAssertEqual(groups, TranscriptActivityGrouping.groups(for: newItems))
    }

    func testStreamingConversationAndPlanRowsKeepGroupingProjectionBounded() {
        let oldItems = [
            item(id: "assistant", kind: .assistantMessage, title: nil, status: .running),
            item(id: "plan", kind: .plan, title: "Plan", status: .running),
        ]
        var newItems = oldItems
        newItems[0].body += " streamed"
        newItems[1].body += "\n[ ] Verify"

        XCTAssertFalse(
            TranscriptActivityGrouping.requiresProjectionRebuild(
                for: .rowChanges(IndexSet(integersIn: 0..<2)),
                from: oldItems,
                to: newItems
            )
        )
    }

    func testRoutineActivityMutationRebuildsGroupingProjection() {
        let oldItems = [
            item(id: "command", kind: .command, title: "Run tests"),
            item(id: "reasoning", kind: .reasoning, title: "Checked result"),
        ]
        var newItems = oldItems
        newItems[1].body += " with more detail"

        XCTAssertTrue(
            TranscriptActivityGrouping.requiresProjectionRebuild(
                for: .tailChange(1),
                from: oldItems,
                to: newItems
            )
        )
    }

    private func item(
        id: String,
        kind: TimelineItemKind,
        title: String?,
        status: TimelineItemStatus = .completed,
        collaboration: RuntimeCollaborationActivity? = nil
    ) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: kind,
            title: title,
            body: title ?? "",
            status: status,
            timestamp: .now,
            detail: nil,
            collaboration: collaboration
        )
    }
}
