import AppKit
import SwiftUI
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

    func testSelectionRevealsDestinationWithoutCollapsingOpenProjects() {
        let first = ProjectID("first")
        let second = ProjectID("second")

        XCTAssertEqual(
            TaskSidebarProjectDisclosure.expandedProjectIDs(
                revealing: second,
                within: [first]
            ),
            [first, second]
        )
        XCTAssertEqual(
            TaskSidebarProjectDisclosure.expandedProjectIDs(
                revealing: nil,
                within: [first]
            ),
            [first]
        )
        XCTAssertEqual(
            TaskSidebarProjectDisclosure.expandedProjectIDs(
                revealing: first,
                within: []
            ),
            [first],
            "Selecting another task in a manually collapsed project must reveal its row."
        )
    }

    func testSidebarUsesCachedRowsUntilAProviderListIsAuthoritative() {
        XCTAssertFalse(
            TaskSidebarLiveSnapshotPolicy.shouldUseLiveSnapshot(
                hasAuthoritativeThreadList: false
            )
        )
        XCTAssertTrue(
            TaskSidebarLiveSnapshotPolicy.shouldUseLiveSnapshot(
                hasAuthoritativeThreadList: true
            )
        )
    }

    func testPrimaryDesktopControlsShareGenerousCompactTargetPolicy() {
        XCTAssertGreaterThanOrEqual(OnyxHitTarget.compact, 32)
        XCTAssertGreaterThanOrEqual(OnyxHitTarget.row, OnyxHitTarget.compact)
        XCTAssertGreaterThanOrEqual(OnyxHitTarget.splitter, 10)
    }

    @MainActor
    func testClickingProjectNameTogglesTheWholeProjectHeader() throws {
        let project = ProjectCatalogRecord(
            id: ProjectID("hit-target-project"),
            folderPath: "/tmp/hit-target-project",
            displayName: "Onyx",
            order: 0
        )
        var toggleCount = 0
        let size = NSSize(width: 280, height: 36)
        let hostingView = NSHostingView(
            rootView: ProjectSidebarHeader(
                project: project,
                taskCount: 4,
                isExpanded: false,
                canMoveUp: false,
                canMoveDown: false,
                toggleExpanded: { toggleCount += 1 },
                newTask: {},
                rename: {},
                moveUp: {},
                moveDown: {},
                remove: {}
            )
            .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()

        // This is over the project label, well outside the tiny disclosure
        // glyph and trailing actions menu.
        try click(at: NSPoint(x: 76, y: size.height / 2), in: window)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertEqual(toggleCount, 1)
    }

    @MainActor
    private func click(at point: NSPoint, in window: NSWindow) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        window.sendEvent(down)
        window.sendEvent(up)
    }
}
