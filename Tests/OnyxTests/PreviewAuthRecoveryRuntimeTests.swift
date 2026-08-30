#if DEBUG
import XCTest
@testable import Onyx

@MainActor
final class PreviewAuthRecoveryRuntimeTests: XCTestCase {
    func testBrowserLoginProvidesAReopenableHTTPSDestination() async throws {
        let runtime = PreviewAuthRecoveryRuntime()

        let attempt = try await runtime.startLogin(methodID: "codex.chatgpt.browser")

        XCTAssertEqual(attempt.authURL?.scheme, "https")
        XCTAssertEqual(attempt.authURL?.host, "chatgpt.com")
        XCTAssertEqual(attempt.authURL?.path, "/auth/login")
        XCTAssertTrue(attempt.loginID.hasPrefix("preview-login-"))

        // Stop the fixture's delayed completion task from retaining the
        // runtime for the remainder of the test process.
        try await runtime.cancelLogin(id: attempt.loginID)
    }

    func testFixtureSeedsAStableQueueAndApprovalIdentity() {
        XCTAssertEqual(
            PreviewAuthRecoveryRuntime.fixtureThreadID,
            PreviewAuthRecoveryRuntime.thread.id
        )
        XCTAssertEqual(
            PreviewAuthRecoveryRuntime.fixtureInteraction.threadID,
            PreviewAuthRecoveryRuntime.fixtureThreadID
        )
        XCTAssertEqual(
            PreviewAuthRecoveryRuntime.fixtureInteraction.id,
            .string("onyx-preview-approval")
        )
        XCTAssertFalse(PreviewAuthRecoveryRuntime.fixtureQueuedFollowUp.isEmpty)
        XCTAssertFalse(PreviewAuthRecoveryRuntime.fixtureComposerDraft.isEmpty)
    }

    func testFixtureModelLoadsDraftAndQueuedFollowUpOnMountedTask() async {
        // Exercise the same composition as the canonical preview. The host
        // wraps the fixture in SharedRuntimeCoordinator, which is exactly the
        // integration boundary that must still receive the seeded local state.
        let host = PreviewAuthRecoveryComposition.makeHost()
        let model = host.makeWindowModel(for: WorkspaceWindowID())

        model.start()
        for _ in 0..<300 {
            if model.selectedThreadID == PreviewAuthRecoveryRuntime.fixtureThreadID,
               model.composerText == PreviewAuthRecoveryRuntime.fixtureComposerDraft,
               model.pendingSteeringMessagesForSelectedThread.count == 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.selectedThreadID, PreviewAuthRecoveryRuntime.fixtureThreadID)
        XCTAssertEqual(model.composerText, PreviewAuthRecoveryRuntime.fixtureComposerDraft)
        XCTAssertEqual(
            model.pendingSteeringMessagesForSelectedThread.first?.text,
            PreviewAuthRecoveryRuntime.fixtureQueuedFollowUp
        )
    }
}
#endif
