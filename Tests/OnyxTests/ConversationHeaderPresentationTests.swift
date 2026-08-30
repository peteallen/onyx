import XCTest
@testable import Onyx

final class ConversationHeaderPresentationTests: XCTestCase {
    func testHeaderStaysCompactWhileSwitcherTargetRemainsGenerous() {
        XCTAssertEqual(ConversationHeaderPresentation.headerHeight, 48)
        XCTAssertGreaterThanOrEqual(
            ConversationHeaderPresentation.minimumSwitcherTargetHeight,
            32
        )
    }

    func testSelectedTaskKeepsWorkspaceAndBranchAttachedToItsTitle() {
        let presentation = ConversationHeaderPresentation.resolve(
            taskTitle: "Repair authentication recovery",
            workspacePath: "/Users/pete/work/onyx.worktrees/auth-recovery",
            branch: "codex/auth-recovery",
            isShowingArchivedThreads: false
        )

        XCTAssertEqual(presentation.taskTitle, "Repair authentication recovery")
        XCTAssertEqual(presentation.workspaceName, "onyx / auth-recovery")
        XCTAssertEqual(presentation.contextLabel, "onyx / auth-recovery · codex/auth-recovery")
        XCTAssertEqual(
            presentation.helpText,
            "/Users/pete/work/onyx.worktrees/auth-recovery · branch codex/auth-recovery"
        )
        XCTAssertEqual(
            presentation.accessibilityValue,
            "Task Repair authentication recovery. Workspace /Users/pete/work/onyx.worktrees/auth-recovery. Branch codex/auth-recovery."
        )
    }

    func testImportedProjectKeepsItsRelativeCheckoutVisible() {
        let presentation = ConversationHeaderPresentation.resolve(
            taskTitle: "Fix release packaging",
            workspacePath: "/Users/pete/work/onyx/worktrees/release",
            workspaceProjectName: "Onyx",
            workspaceProjectPath: "/Users/pete/work/onyx",
            branch: "codex/release",
            isShowingArchivedThreads: false
        )

        XCTAssertEqual(presentation.workspaceName, "Onyx / worktrees/release")
        XCTAssertEqual(
            presentation.contextLabel,
            "Onyx / worktrees/release · codex/release"
        )
    }

    func testNewTaskShowsItsDraftWorkspaceWithoutInventingABranch() {
        let presentation = ConversationHeaderPresentation.resolve(
            taskTitle: nil,
            workspacePath: "/Users/pete/Documents/ChatGPT/onyx/",
            branch: "  ",
            isShowingArchivedThreads: false
        )

        XCTAssertEqual(presentation.taskTitle, "New task")
        XCTAssertEqual(presentation.workspaceName, "onyx")
        XCTAssertEqual(presentation.contextLabel, "onyx")
        XCTAssertNil(presentation.branchName)
    }

    func testMissingContextUsesCompactActionableFallbacks() {
        let active = ConversationHeaderPresentation.resolve(
            taskTitle: " ",
            workspacePath: "\n",
            branch: nil,
            isShowingArchivedThreads: false
        )
        let archived = ConversationHeaderPresentation.resolve(
            taskTitle: nil,
            workspacePath: nil,
            branch: nil,
            isShowingArchivedThreads: true
        )

        XCTAssertEqual(active.taskTitle, "New task")
        XCTAssertEqual(active.workspaceName, "Choose workspace")
        XCTAssertEqual(active.helpText, "Choose a project or worktree")
        XCTAssertEqual(active.accessibilityValue, "Task New task. Workspace not selected.")
        XCTAssertEqual(archived.taskTitle, "Archived tasks")
        XCTAssertEqual(archived.workspaceName, "Choose workspace")
    }
}
