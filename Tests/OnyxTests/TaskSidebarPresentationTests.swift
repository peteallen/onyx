import XCTest
@testable import Onyx

final class TaskSidebarPresentationTests: XCTestCase {
    func testRoutineStatesUseIndicatorsWithoutSidebarLabels() {
        XCTAssertFalse(RuntimeTaskAttention.ready.showsSidebarAttentionLabel)
        XCTAssertFalse(RuntimeTaskAttention.working.showsSidebarAttentionLabel)

        let visibleStates: [RuntimeTaskAttention] = [
            .needsInput,
            .needsApproval,
            .failed,
            .unknown,
        ]
        for state in visibleStates {
            XCTAssertTrue(
                state.showsSidebarAttentionLabel,
                "\(state.label) should remain visually distinguishable in the sidebar"
            )
        }
    }

    func testCompactTimestampUsesOneShortUnit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(TaskSidebarTimestamp.compact(now, relativeTo: now), "now")
        XCTAssertEqual(
            TaskSidebarTimestamp.compact(now.addingTimeInterval(-4 * 60 * 60), relativeTo: now),
            "4h"
        )
        XCTAssertEqual(
            TaskSidebarTimestamp.compact(now.addingTimeInterval(-140 * 24 * 60 * 60), relativeTo: now),
            "4mo"
        )
        XCTAssertEqual(
            TaskSidebarTimestamp.compact(now.addingTimeInterval(2 * 60), relativeTo: now),
            "in 2m"
        )
    }

    func testProjectDisclosureDefaultsToOnlyTheSelectedProject() {
        let selected = ProjectID("selected")

        XCTAssertEqual(
            TaskSidebarProjectDisclosure.defaultExpandedProjectIDs(
                selectedProjectID: selected
            ),
            [selected]
        )
        XCTAssertEqual(
            TaskSidebarProjectDisclosure.defaultExpandedProjectIDs(
                selectedProjectID: nil
            ),
            []
        )
    }

    func testSearchRevealsMatchesWithoutChangingDisclosureState() {
        let project = ProjectID("project")
        let collapsed: Set<ProjectID> = []

        XCTAssertFalse(TaskSidebarProjectDisclosure.isExpanded(
            project,
            expandedProjectIDs: collapsed,
            searchText: ""
        ))
        XCTAssertFalse(TaskSidebarProjectDisclosure.isExpanded(
            project,
            expandedProjectIDs: collapsed,
            searchText: "   "
        ))
        XCTAssertTrue(TaskSidebarProjectDisclosure.isExpanded(
            project,
            expandedProjectIDs: collapsed,
            searchText: "capabilities"
        ))
        XCTAssertTrue(TaskSidebarProjectDisclosure.mayToggle(searchText: ""))
        XCTAssertFalse(TaskSidebarProjectDisclosure.mayToggle(
            searchText: "capabilities"
        ))
    }

    func testProjectDisclosureExpandsWhenSelectedTaskMovesToAnotherProject() {
        let first = ProjectID("first")
        let second = ProjectID("second")

        XCTAssertTrue(TaskSidebarProjectDisclosure.shouldExpandResolvedSelection(
            first,
            after: nil
        ))
        XCTAssertTrue(TaskSidebarProjectDisclosure.shouldExpandResolvedSelection(
            second,
            after: first
        ))
        XCTAssertFalse(TaskSidebarProjectDisclosure.shouldExpandResolvedSelection(
            first,
            after: first
        ))
        XCTAssertFalse(TaskSidebarProjectDisclosure.shouldExpandResolvedSelection(
            nil,
            after: first
        ))
    }
}
