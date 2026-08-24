import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxAppModelHistoryPaginationTests: XCTestCase {
    func testInitialSelectionPublishesNewestProviderPageAndRetainsTurnIdentity() async {
        let fixture = makeFixture(paginated: true)
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The newest history page did not become visible") {
            fixture.model.selectedThreadID == HistoryPaginationRuntime.thread.id
                && !fixture.model.isLoadingThread
        }

        XCTAssertEqual(
            fixture.model.timeline.map(\.id),
            ["turn-3-user", "turn-3-assistant", "turn-4-user", "turn-4-assistant"]
        )
        XCTAssertEqual(
            fixture.model.loadedConversationTurns.map(\.id),
            ["turn-3", "turn-4"],
            "Turn IDs must remain chronological for latest-message editing"
        )
        XCTAssertTrue(fixture.model.canLoadEarlierHistory)
        XCTAssertFalse(fixture.model.isLoadingEarlierHistory)

        let requests = await fixture.runtime.initialPageRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.limit, 12)
        XCTAssertEqual(requests.first?.direction, .descending)
        XCTAssertEqual(requests.first?.itemDetail, .full)
        let readCount = await fixture.runtime.readCount()
        let paginatedReadCount = await fixture.runtime.paginatedReadCount()
        let paginatedResumeCount = await fixture.runtime.paginatedResumeCount()
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(paginatedReadCount, 1)
        XCTAssertEqual(
            paginatedResumeCount,
            0,
            "Opening a task for reading must not acquire provider writer ownership"
        )
    }

    func testEarlierProviderPagePrependsWithoutBlankingVisibleTail() async {
        let fixture = makeFixture(paginated: true)
        defer { fixture.cleanUp() }
        fixture.model.start()
        await waitUntil("The newest history page did not become visible") {
            !fixture.model.isLoadingThread
                && fixture.model.timeline.last?.id == "turn-4-assistant"
        }
        let visibleTail = fixture.model.timeline

        fixture.model.loadEarlierHistory()
        await fixture.runtime.waitUntilEarlierPageRequested()

        XCTAssertEqual(fixture.model.timeline, visibleTail)
        XCTAssertTrue(fixture.model.isLoadingEarlierHistory)
        XCTAssertFalse(
            fixture.model.isLoadingThread,
            "Fetching old context must not put the ready task back behind its initial loader"
        )

        await fixture.runtime.releaseEarlierPage()
        await waitUntil("The earlier provider page did not prepend") {
            !fixture.model.isLoadingEarlierHistory
                && fixture.model.timeline.first?.id == "turn-1-user"
        }

        XCTAssertEqual(
            fixture.model.timeline.map(\.id),
            [
                "turn-1-user", "turn-1-assistant", "turn-2-user", "turn-2-assistant",
                "turn-3-user", "turn-3-assistant", "turn-4-user", "turn-4-assistant",
            ]
        )
        XCTAssertEqual(
            fixture.model.loadedConversationTurns.map(\.id),
            ["turn-1", "turn-2", "turn-3", "turn-4"]
        )
        XCTAssertFalse(fixture.model.canLoadEarlierHistory)
    }

    func testUnpaginatedProviderShowsBoundedTailThenRevealsBufferedPrefix() async {
        let fixture = makeFixture(paginated: false)
        defer { fixture.cleanUp() }
        fixture.model.start()
        await waitUntil("The buffered tail did not become visible") {
            !fixture.model.isLoadingThread
                && fixture.model.selectedThreadID == HistoryPaginationRuntime.thread.id
        }

        XCTAssertEqual(fixture.model.timeline.count, 120)
        XCTAssertEqual(fixture.model.timeline.first?.id, "full-280")
        XCTAssertEqual(fixture.model.timeline.last?.id, "full-399")
        XCTAssertTrue(fixture.model.canLoadEarlierHistory)
        let initialReadCount = await fixture.runtime.readCount()
        let paginatedResumeCount = await fixture.runtime.paginatedResumeCount()
        XCTAssertEqual(initialReadCount, 1)
        XCTAssertEqual(paginatedResumeCount, 0)

        fixture.model.loadEarlierHistory()
        await waitUntil("The buffered earlier page did not prepend") {
            !fixture.model.isLoadingEarlierHistory
                && fixture.model.timeline.count == 240
        }

        XCTAssertEqual(fixture.model.timeline.first?.id, "full-160")
        XCTAssertEqual(fixture.model.timeline.last?.id, "full-399")
        XCTAssertTrue(fixture.model.canLoadEarlierHistory)
        let finalReadCount = await fixture.runtime.readCount()
        XCTAssertEqual(
            finalReadCount,
            1,
            "Buffered pagination must not reread or re-decode the provider transcript"
        )
    }

    func testUnsupportedNativePaginationFallsBackToBoundedFullRead() async {
        for code in [-32_601, -32_602] {
            let fixture = makeFixture(
                paginated: true,
                paginationFailureCode: code
            )
            defer { fixture.cleanUp() }

            fixture.model.start()
            await waitUntil("Compatibility fallback did not publish the bounded tail") {
                !fixture.model.isLoadingThread
                    && fixture.model.timeline.first?.id == "full-280"
            }

            XCTAssertEqual(fixture.model.timeline.count, 120)
            XCTAssertEqual(fixture.model.timeline.last?.id, "full-399")
            XCTAssertTrue(fixture.model.canLoadEarlierHistory)
            XCTAssertNil(fixture.model.notice)
            let paginatedReads = await fixture.runtime.paginatedReadCount()
            let fullReads = await fixture.runtime.readCount()
            XCTAssertEqual(paginatedReads, 1)
            XCTAssertEqual(fullReads, 1)
        }
    }

    func testCompatibilityFallbackUsesLegacyResumeBeforeSending() async {
        let fixture = makeFixture(
            paginated: true,
            paginationFailureCode: -32_602
        )
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("Compatibility fallback did not load the task") {
            !fixture.model.isLoadingThread
                && fixture.model.timeline.last?.id == "full-399"
        }

        fixture.model.composerText = "Continue after fallback"
        fixture.model.sendComposer()
        await waitUntilAsync("The corrected legacy resume did not reach turn start") {
            await fixture.runtime.startedTurnTexts() == ["Continue after fallback"]
        }

        let paginatedResumes = await fixture.runtime.paginatedResumeCount()
        let legacyResumes = await fixture.runtime.legacyResumeCount()
        XCTAssertEqual(paginatedResumes, 1)
        XCTAssertEqual(legacyResumes, 1)
        XCTAssertEqual(fixture.model.timeline.count, 121)
        XCTAssertEqual(fixture.model.timeline.first?.id, "full-280")
    }

    func testNonCompatibilityPaginationFailureDoesNotTriggerFullRead() async {
        let fixture = makeFixture(
            paginated: true,
            paginationFailureCode: -32_100
        )
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The pagination failure was not surfaced") {
            !fixture.model.isLoadingThread
                && fixture.model.timeline.first?.kind == .error
        }

        XCTAssertEqual(fixture.model.timeline.first?.title, "Could not load this task")
        let fullReads = await fixture.runtime.readCount()
        XCTAssertEqual(
            fullReads,
            0,
            "Transport and provider failures must not silently trigger a full-history read"
        )
    }

    func testSuccessfulPaginatedReadWithoutInitialPageStaysUsable() async {
        let suiteName = "OnyxAppModelHistoryPaginationTests.empty-page.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let runtime = HistoryPaginationRuntime(paginated: true, returnsInitialPage: false)
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)

        model.start()
        await waitUntil("The metadata-only task did not finish loading") {
            model.selectedThreadID == HistoryPaginationRuntime.thread.id
                && !model.isLoadingThread
        }

        XCTAssertTrue(model.timeline.isEmpty)
        XCTAssertFalse(model.canLoadEarlierHistory)
        XCTAssertNil(model.notice)
        let fullReadCount = await runtime.fullReadCount()
        XCTAssertEqual(fullReadCount, 0)
    }

    func testExplicitEmptyProviderPageStaysUsable() async {
        let fixture = makeFixture(paginated: true, explicitEmptyInitialPage: true)
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The empty provider page did not finish loading") {
            fixture.model.selectedThreadID == HistoryPaginationRuntime.thread.id
                && !fixture.model.isLoadingThread
        }

        XCTAssertTrue(fixture.model.timeline.isEmpty)
        XCTAssertTrue(fixture.model.loadedConversationTurns.isEmpty)
        XCTAssertFalse(fixture.model.canLoadEarlierHistory)
        XCTAssertNil(fixture.model.notice)
    }

    func testTurnWithMultipleUserMessagesDoesNotOfferDestructiveSingleMessageEdit() async {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            latestTurnUserMessageCount: 2
        )
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The multi-message turn did not load") {
            !fixture.model.isLoadingThread
                && fixture.model.timeline.last?.id == "turn-4-assistant"
        }

        XCTAssertNil(fixture.model.latestEditableUserMessageID)
        fixture.model.editLatestUserMessage()
        await Task.yield()
        let revertedTurnIDs = await fixture.runtime.revertedTurnIDs()
        XCTAssertTrue(revertedTurnIDs.isEmpty)
    }

    func testEditPreservesDraftTypedWhileNativeRevertIsPendingAndBlocksSend() async {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            suspendsRevert: true
        )
        defer {
            Task { await fixture.runtime.releaseRevert() }
            fixture.cleanUp()
        }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            fixture.model.latestEditableUserMessageID == "turn-4-user"
        }

        fixture.model.editLatestUserMessage()
        await fixture.runtime.waitUntilRevertRequested()
        XCTAssertTrue(fixture.model.isPreparingLatestMessageEditForSelectedThread)

        fixture.model.composerText = "Follow-up typed while editing"
        fixture.model.sendComposer()
        let startedTurnTexts = await fixture.runtime.startedTurnTexts()
        XCTAssertTrue(startedTurnTexts.isEmpty)

        await fixture.runtime.releaseRevert()
        await waitUntil("The pending edit did not merge the later draft") {
            !fixture.model.isPreparingLatestMessageEdit
                && fixture.model.composerText
                    == "User message 4\n\nFollow-up typed while editing"
        }
        XCTAssertEqual(fixture.model.composerImages.first?.displayName, "reference.png")
    }

    func testPendingHistoryEditBlocksOtherWriterOperationsForThatTask() async throws {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            suspendsRevert: true
        )
        defer {
            Task { await fixture.runtime.releaseRevert() }
            fixture.cleanUp()
        }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            fixture.model.latestEditableUserMessageID == "turn-4-user"
        }
        let thread = try XCTUnwrap(fixture.model.selectedThread)
        XCTAssertTrue(fixture.model.canStartReview)
        XCTAssertTrue(fixture.model.canForkThread(thread))
        XCTAssertTrue(fixture.model.canCompactThread(thread))
        XCTAssertTrue(fixture.model.canArchiveThread(thread))
        XCTAssertTrue(fixture.model.canDeleteThread(thread))

        fixture.model.editLatestUserMessage()
        await fixture.runtime.waitUntilRevertRequested()

        XCTAssertFalse(fixture.model.canStartReview)
        XCTAssertFalse(fixture.model.canForkThread(thread))
        XCTAssertFalse(fixture.model.canCompactThread(thread))
        XCTAssertFalse(fixture.model.canArchiveThread(thread))
        XCTAssertFalse(fixture.model.canDeleteThread(thread))
    }

    func testEarlierPageCanPrependWhileEditWaitsWithoutInvalidatingTurnBoundary() async {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            suspendsRevert: true
        )
        defer {
            Task {
                await fixture.runtime.releaseEarlierPage()
                await fixture.runtime.releaseRevert()
            }
            fixture.cleanUp()
        }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            fixture.model.latestEditableUserMessageID == "turn-4-user"
        }
        fixture.model.editLatestUserMessage()
        await fixture.runtime.waitUntilRevertRequested()

        fixture.model.loadEarlierHistory()
        await fixture.runtime.waitUntilEarlierPageRequested()
        await fixture.runtime.releaseEarlierPage()
        await waitUntil("The older page did not shift the loaded turn indexes") {
            fixture.model.loadedConversationTurns.first?.id == "turn-1"
        }

        await fixture.runtime.releaseRevert()
        await waitUntil("The stable turn boundary was not removed after pagination") {
            !fixture.model.isPreparingLatestMessageEdit
                && fixture.model.timeline.last?.id == "turn-3-assistant"
        }
        XCTAssertEqual(
            fixture.model.loadedConversationTurns.map(\.id),
            ["turn-1", "turn-2", "turn-3"]
        )
        XCTAssertEqual(fixture.model.composerText, "User message 4")
    }

    func testAmbiguousRevertFailureReloadsHistoryAndPreservesOriginalMessage() async {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            revertFailsAfterCommit: true
        )
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            fixture.model.latestEditableUserMessageID == "turn-4-user"
        }
        fixture.model.editLatestUserMessage()

        await waitUntil("The ambiguous edit outcome was not reconciled") {
            !fixture.model.isPreparingLatestMessageEdit
                && fixture.model.notice?.title == "Could not confirm the edit"
        }
        XCTAssertEqual(fixture.model.timeline.last?.id, "turn-3-assistant")
        XCTAssertEqual(fixture.model.composerText, "User message 4")
        XCTAssertEqual(fixture.model.composerImages.first?.displayName, "reference.png")
        let paginatedReadCount = await fixture.runtime.paginatedReadCount()
        XCTAssertEqual(paginatedReadCount, 2)
    }

    func testFailedReconciliationKeepsSendLockedUntilAuthoritativeReopen() async {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            revertFailsAfterCommit: true,
            reconciliationReadFails: true
        )
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            fixture.model.latestEditableUserMessageID == "turn-4-user"
        }
        fixture.model.editLatestUserMessage()
        await waitUntil("The uncertain edit did not retain its safety lock") {
            fixture.model.notice?.title == "Could not confirm the edit"
                && fixture.model.isPreparingLatestMessageEditForSelectedThread
                && !fixture.model.isLoadingThread
        }

        fixture.model.composerText = "Do not send against uncertain history"
        fixture.model.sendComposer()
        let startsWhileLocked = await fixture.runtime.startedTurnTexts()
        XCTAssertTrue(startsWhileLocked.isEmpty)

        await fixture.runtime.allowReconciliationReads()
        fixture.model.newTask()
        fixture.model.selectThread(HistoryPaginationRuntime.thread.id)
        await waitUntil("Reopening the task did not clear the edit safety lock") {
            !fixture.model.isLoadingThread
                && !fixture.model.isPreparingLatestMessageEdit
                && fixture.model.timeline.last?.id == "turn-3-assistant"
        }
    }

    func testNavigateAwayDuringAmbiguousRevertKeepsOriginalTaskLockedUntilReopen() async throws {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            suspendsRevert: true,
            revertFailsAfterCommit: true
        )
        defer {
            Task { await fixture.runtime.releaseRevert() }
            fixture.cleanUp()
        }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            fixture.model.latestEditableUserMessageID == "turn-4-user"
        }

        fixture.model.editLatestUserMessage()
        await fixture.runtime.waitUntilRevertRequested()
        fixture.model.newTask()
        XCTAssertFalse(
            fixture.model.isPreparingLatestMessageEditForSelectedThread,
            "An unrelated task must remain usable while the original task is locked"
        )

        await fixture.runtime.releaseRevert()
        await waitUntil("The uncertain background edit did not retain its task lock") {
            fixture.model.notice?.title == "Could not confirm the edit"
                && fixture.model.isPreparingLatestMessageEdit
        }

        let originalThread = try XCTUnwrap(
            fixture.model.threads.first(where: { $0.id == HistoryPaginationRuntime.thread.id })
        )
        XCTAssertFalse(fixture.model.canForkThread(originalThread))
        XCTAssertFalse(fixture.model.canCompactThread(originalThread))
        XCTAssertFalse(fixture.model.canArchiveThread(originalThread))
        XCTAssertFalse(fixture.model.canDeleteThread(originalThread))

        fixture.model.selectThread(originalThread.id)
        await waitUntil("A successful reopen did not reconcile and unlock the original task") {
            !fixture.model.isLoadingThread
                && !fixture.model.isPreparingLatestMessageEdit
                && fixture.model.timeline.last?.id == "turn-3-assistant"
        }
        XCTAssertTrue(fixture.model.canForkThread(originalThread))
        XCTAssertEqual(fixture.model.composerText, "User message 4")
    }

    func testPendingEditOnOneTaskKeepsUnrelatedTaskEditAndRetryAvailable() async {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            latestTurnStatus: .failed,
            suspendsRevert: true,
            hasSecondaryThread: true
        )
        defer {
            Task { await fixture.runtime.releaseRevert() }
            fixture.cleanUp()
        }

        fixture.model.start()
        await waitUntil("The first task did not expose Retry") {
            fixture.model.retryableFailedUserMessageID == "turn-4-user"
        }

        fixture.model.editLatestUserMessage()
        await fixture.runtime.waitUntilRevertRequested()
        fixture.model.selectThread(HistoryPaginationRuntime.secondaryThread.id)
        await waitUntil("The unrelated task did not finish loading") {
            fixture.model.selectedThreadID == HistoryPaginationRuntime.secondaryThread.id
                && !fixture.model.isLoadingThread
        }

        XCTAssertFalse(fixture.model.isPreparingLatestMessageEditForSelectedThread)
        XCTAssertEqual(
            fixture.model.latestEditableUserMessageID,
            "turn-4-user",
            "A task-local history lock must not hide Edit on another task"
        )
        XCTAssertEqual(
            fixture.model.retryableFailedUserMessageID,
            "turn-4-user",
            "A task-local history lock must not hide Retry on another task"
        )
    }

    func testStaleEditCallbackCannotRevertAReplacementMessage() async {
        let fixture = makeFixture(paginated: true, supportsEditing: true)
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            fixture.model.latestEditableUserMessageID == "turn-4-user"
        }
        fixture.model.editLatestUserMessage(expectedMessageID: "stale-message-id")
        await Task.yield()

        let revertedTurnIDs = await fixture.runtime.revertedTurnIDs()
        XCTAssertTrue(revertedTurnIDs.isEmpty)
        XCTAssertFalse(fixture.model.isPreparingLatestMessageEdit)
    }

    func testLatestUserMessageUsesNativeRevertThenResendsWithoutDuplication() async {
        let fixture = makeFixture(paginated: true, supportsEditing: true)
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            !fixture.model.isLoadingThread
                && fixture.model.latestEditableUserMessageID == "turn-4-user"
        }

        fixture.model.editLatestUserMessage()
        await waitUntil("Native history revert was not requested") {
            fixture.model.composerText == "User message 4"
                && fixture.model.timeline.map(\.id) == ["turn-3-user", "turn-3-assistant"]
                && !fixture.model.isPreparingLatestMessageEdit
        }

        let reverted = await fixture.runtime.revertedTurnIDs()
        XCTAssertEqual(reverted.count, 1)
        XCTAssertEqual(reverted.first?.0, HistoryPaginationRuntime.thread.id)
        XCTAssertEqual(reverted.first?.1, "turn-4")
        XCTAssertEqual(fixture.model.composerImages.count, 1)
        XCTAssertEqual(fixture.model.composerImages.first?.displayName, "reference.png")
        XCTAssertEqual(
            fixture.model.composerImages.first?.input,
            .imageURL("data:image/png;base64,YQ==")
        )

        fixture.model.composerText = "Corrected user message"
        fixture.model.sendComposer()
        await waitUntilAsync("Corrected message did not reach the provider") {
            await fixture.runtime.startedTurnTexts() == ["Corrected user message"]
        }
        XCTAssertEqual(
            fixture.model.timeline.filter { $0.kind == .userMessage }.map(\.body),
            ["User message 3", "Corrected user message"],
            "The corrected message should be appended once, without retaining the reverted copy"
        )
    }

    func testLatestMessageStaysEditableWithAnExistingDraftAndMergesIt() async {
        let fixture = makeFixture(paginated: true, supportsEditing: true)
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The editable task did not load") {
            fixture.model.latestEditableUserMessageID == "turn-4-user"
        }
        fixture.model.composerText = "Follow-up already being drafted"
        XCTAssertEqual(
            fixture.model.latestEditableUserMessageID,
            "turn-4-user",
            "Typing a follow-up must not hide the recovery affordance"
        )

        fixture.model.editLatestUserMessage()
        await waitUntil("The previous message was not merged into the draft") {
            fixture.model.composerText
                == "User message 4\n\nFollow-up already being drafted"
        }
    }

    func testFailedLatestTurnRetriesByRevertingThenSendingOnce() async {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            latestTurnStatus: .failed
        )
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The failed task did not expose Retry") {
            fixture.model.retryableFailedUserMessageID == "turn-4-user"
        }

        fixture.model.retryLatestFailedResponse(messageID: "turn-4-user")
        await waitUntilAsync("Retry did not submit the original prompt once") {
            await fixture.runtime.startedTurnTexts() == ["User message 4"]
        }
        let reverts = await fixture.runtime.revertedTurnIDs()
        XCTAssertEqual(reverts.map(\.1), ["turn-4"])
        XCTAssertEqual(
            fixture.model.timeline.filter { $0.kind == .userMessage }.map(\.body),
            ["User message 3", "User message 4"]
        )
    }

    func testRetryPreservesDraftTypedWhileRevertWaitsAndSendsOnlyFailedPrompt() async {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            latestTurnStatus: .failed,
            suspendsRevert: true
        )
        defer {
            Task { await fixture.runtime.releaseRevert() }
            fixture.cleanUp()
        }

        fixture.model.start()
        await waitUntil("The failed task did not expose Retry") {
            fixture.model.retryableFailedUserMessageID == "turn-4-user"
        }
        fixture.model.retryLatestFailedResponse(messageID: "turn-4-user")
        await fixture.runtime.waitUntilRevertRequested()
        XCTAssertTrue(fixture.model.isPreparingFailedResponseRetry)
        fixture.model.composerText = "A separate follow-up"

        await fixture.runtime.releaseRevert()
        await waitUntilAsync("Retry did not send the exact failed prompt") {
            await fixture.runtime.startedTurnTexts() == ["User message 4"]
        }
        XCTAssertEqual(fixture.model.composerText, "A separate follow-up")
        XCTAssertFalse(fixture.model.isPreparingFailedResponseRetry)
    }

    func testRetryPreservesPreexistingDraftTextAndImages() async throws {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            latestTurnStatus: .failed
        )
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("The failed task did not expose Retry") {
            fixture.model.retryableFailedUserMessageID == "turn-4-user"
        }

        fixture.model.composerText = "A draft I was already writing"
        let laterImageView = NSImage(size: NSSize(width: 10, height: 10))
        laterImageView.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        laterImageView.unlockFocus()
        fixture.model.addPastedComposerImages([laterImageView])
        await waitUntil("The preexisting draft image did not finish preparing") {
            fixture.model.composerImages.count == 1
        }
        let laterImage = try XCTUnwrap(fixture.model.composerImages.first)
        fixture.model.retryLatestFailedResponse(messageID: "turn-4-user")

        await waitUntilAsync("Retry did not send the failed prompt exactly once") {
            await fixture.runtime.startedTurnTexts() == ["User message 4"]
        }
        XCTAssertEqual(fixture.model.composerText, "A draft I was already writing")
        XCTAssertEqual(fixture.model.composerImages, [laterImage])
    }

    func testNavigateAwayDuringRetryKeepsOriginalTaskLockedUntilReopen() async throws {
        let fixture = makeFixture(
            paginated: true,
            supportsEditing: true,
            latestTurnStatus: .failed,
            suspendsRevert: true
        )
        defer {
            Task { await fixture.runtime.releaseRevert() }
            fixture.cleanUp()
        }

        fixture.model.start()
        await waitUntil("The failed task did not expose Retry") {
            fixture.model.retryableFailedUserMessageID == "turn-4-user"
        }

        fixture.model.retryLatestFailedResponse(messageID: "turn-4-user")
        await fixture.runtime.waitUntilRevertRequested()
        fixture.model.newTask()
        XCTAssertFalse(
            fixture.model.isPreparingLatestMessageEditForSelectedThread,
            "An unrelated task must remain usable while Retry prepares the original task"
        )

        await fixture.runtime.releaseRevert()
        await waitUntil("Retry navigation did not retain the original task lock") {
            fixture.model.isPreparingLatestMessageEdit
                && fixture.model.composerText.isEmpty
        }
        let startedWhileAway = await fixture.runtime.startedTurnTexts()
        XCTAssertTrue(
            startedWhileAway.isEmpty,
            "Navigating away must never auto-send the Retry into either task"
        )

        let originalThread = try XCTUnwrap(
            fixture.model.threads.first(where: { $0.id == HistoryPaginationRuntime.thread.id })
        )
        XCTAssertFalse(fixture.model.canForkThread(originalThread))
        XCTAssertFalse(fixture.model.canArchiveThread(originalThread))

        fixture.model.selectThread(originalThread.id)
        await waitUntil("Reopening the original task did not reconcile Retry history") {
            !fixture.model.isLoadingThread
                && !fixture.model.isPreparingLatestMessageEdit
                && fixture.model.timeline.last?.id == "turn-3-assistant"
        }
        XCTAssertEqual(fixture.model.composerText, "User message 4")
        let startedAfterReopen = await fixture.runtime.startedTurnTexts()
        XCTAssertTrue(startedAfterReopen.isEmpty)
    }

    private func makeFixture(
        paginated: Bool,
        supportsEditing: Bool = false,
        paginationFailureCode: Int? = nil,
        explicitEmptyInitialPage: Bool = false,
        latestTurnUserMessageCount: Int = 1,
        latestTurnStatus: RuntimeConversationTurnStatus = .completed,
        suspendsRevert: Bool = false,
        revertFailsAfterCommit: Bool = false,
        reconciliationReadFails: Bool = false,
        hasSecondaryThread: Bool = false
    ) -> HistoryPaginationFixture {
        let suiteName = "OnyxAppModelHistoryPaginationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let runtime = HistoryPaginationRuntime(
            paginated: paginated,
            supportsEditing: supportsEditing,
            paginationFailureCode: paginationFailureCode,
            explicitEmptyInitialPage: explicitEmptyInitialPage,
            latestTurnUserMessageCount: latestTurnUserMessageCount,
            latestTurnStatus: latestTurnStatus,
            suspendsRevert: suspendsRevert,
            revertFailsAfterCommit: revertFailsAfterCommit,
            reconciliationReadFails: reconciliationReadFails,
            hasSecondaryThread: hasSecondaryThread
        )
        return HistoryPaginationFixture(
            model: OnyxAppModel(runtime: runtime, defaults: defaults),
            runtime: runtime,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(failureMessage)
    }

    private func waitUntilAsync(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail(failureMessage)
    }
}

private struct HistoryPaginationFixture {
    let model: OnyxAppModel
    let runtime: HistoryPaginationRuntime
    let defaults: UserDefaults
    let suiteName: String

    @MainActor
    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor HistoryPaginationRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind = .codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>
    nonisolated static let thread = RuntimeThread(
        id: "history-pagination-thread",
        title: "Large task",
        preview: "A long-lived task",
        cwd: "/tmp",
        updatedAt: Date(timeIntervalSince1970: 400),
        status: .idle,
        isPinned: false,
        runtime: .codex,
        model: "test-model",
        branch: nil
    )
    nonisolated static let secondaryThread = RuntimeThread(
        id: "history-pagination-secondary-thread",
        title: "Another task",
        preview: "An unrelated task",
        cwd: "/tmp",
        updatedAt: Date(timeIntervalSince1970: 300),
        status: .idle,
        isPinned: false,
        runtime: .codex,
        model: "test-model",
        branch: nil
    )

    private let paginated: Bool
    private let returnsInitialPage: Bool
    private let supportsEditing: Bool
    private let paginationFailureCode: Int?
    private let explicitEmptyInitialPage: Bool
    private let latestTurnUserMessageCount: Int
    private let latestTurnStatus: RuntimeConversationTurnStatus
    private let suspendsRevert: Bool
    private let revertFailsAfterCommit: Bool
    private let hasSecondaryThread: Bool
    private var reconciliationReadFails: Bool
    private var recordedInitialRequests: [RuntimeInitialThreadHistoryPageRequest] = []
    private var recordedReadCount = 0
    private var recordedLegacyResumeCount = 0
    private var recordedPaginatedResumeCount = 0
    private var recordedPaginatedReadCount = 0
    private var earlierPageRequested = false
    private var earlierPageRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var earlierPageRelease: CheckedContinuation<Void, Never>?
    private var recordedReverts: [(String, String)] = []
    private var recordedStartTurns: [StartTurnRequest] = []
    private var revertRequested = false
    private var revertRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var revertRelease: CheckedContinuation<Void, Never>?
    private var revertWasReleased = false
    private var revertedThreadIDs: Set<String> = []

    init(
        paginated: Bool,
        returnsInitialPage: Bool = true,
        supportsEditing: Bool = false,
        paginationFailureCode: Int? = nil,
        explicitEmptyInitialPage: Bool = false,
        latestTurnUserMessageCount: Int = 1,
        latestTurnStatus: RuntimeConversationTurnStatus = .completed,
        suspendsRevert: Bool = false,
        revertFailsAfterCommit: Bool = false,
        reconciliationReadFails: Bool = false,
        hasSecondaryThread: Bool = false
    ) {
        self.paginated = paginated
        self.returnsInitialPage = returnsInitialPage
        self.supportsEditing = supportsEditing
        self.paginationFailureCode = paginationFailureCode
        self.explicitEmptyInitialPage = explicitEmptyInitialPage
        self.latestTurnUserMessageCount = latestTurnUserMessageCount
        self.latestTurnStatus = latestTurnStatus
        self.suspendsRevert = suspendsRevert
        self.revertFailsAfterCommit = revertFailsAfterCommit
        self.reconciliationReadFails = reconciliationReadFails
        self.hasSecondaryThread = hasSecondaryThread
        events = AsyncStream { continuation in
            continuation.onTermination = { _ in }
        }
    }

    func connect() async throws -> RuntimeSession {
        var capabilities: RuntimeCapabilities = [.streaming]
        if paginated { capabilities.insert(.threadHistoryPagination) }
        if supportsEditing {
            capabilities.insert(.threadHistoryRevert)
            capabilities.insert(.images)
            capabilities.insert(.codeReview)
            capabilities.insert(.threadForking)
            capabilities.insert(.threadCompaction)
            capabilities.insert(.threadArchiving)
            capabilities.insert(.threadDeletion)
        }
        return RuntimeSession(
            runtime: .codex,
            displayName: "History fixture",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: capabilities
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : (hasSecondaryThread ? [Self.thread, Self.secondaryThread] : [Self.thread])
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        recordedReadCount += 1
        return Self.fullConversation(thread: Self.thread(for: id))
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        recordedLegacyResumeCount += 1
        return Self.fullConversation(thread: Self.thread(for: id))
    }

    private static func fullConversation(thread: RuntimeThread) -> RuntimeConversation {
        RuntimeConversation(
            thread: thread,
            items: (0..<400).map { index in
                TimelineItem(
                    id: "full-\(index)",
                    kind: index.isMultiple(of: 20) ? .userMessage : .assistantMessage,
                    title: nil,
                    body: "Full transcript row \(index)",
                    status: .completed,
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    detail: nil
                )
            }
        )
    }

    func readThread(
        id: String,
        initialHistoryPage request: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        recordedPaginatedReadCount += 1
        recordedInitialRequests.append(
            RuntimeInitialThreadHistoryPageRequest(
                limit: request.limit,
                direction: request.direction,
                itemDetail: request.itemDetail
            )
        )
        if let paginationFailureCode {
            throw AgentRuntimeError.requestFailed(
                code: paginationFailureCode,
                message: "simulated pagination incompatibility"
            )
        }
        if revertedThreadIDs.contains(id), reconciliationReadFails {
            throw AgentRuntimeError.protocolFailure("simulated reconciliation read failure")
        }
        return returnsInitialPage
            ? initialPageResult(threadID: id)
            : Self.emptyPageResult(thread: Self.thread(for: id))
    }

    func resumeThread(
        id: String,
        initialHistoryPage request: RuntimeInitialThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        recordedPaginatedResumeCount += 1
        recordedInitialRequests.append(request)
        if let paginationFailureCode {
            throw AgentRuntimeError.requestFailed(
                code: paginationFailureCode,
                message: "simulated pagination incompatibility"
            )
        }
        return returnsInitialPage
            ? initialPageResult(threadID: id)
            : Self.emptyPageResult(thread: Self.thread(for: id))
    }

    private func initialPageResult(threadID: String) -> RuntimeThreadResumeResult {
        let thread = Self.thread(for: threadID)
        let turns: [RuntimeConversationTurn]
        if explicitEmptyInitialPage {
            turns = []
        } else if revertedThreadIDs.contains(threadID) {
            turns = [Self.turn(3)]
        } else {
            turns = [
                Self.turn(
                    4,
                    userMessageCount: latestTurnUserMessageCount,
                    status: latestTurnStatus
                ),
                Self.turn(3),
            ]
        }
        let page = RuntimeThreadHistoryPage(
            turns: turns,
            nextCursor: turns.isEmpty ? nil : "older-page",
            backwardsCursor: nil,
            direction: .descending
        )
        return RuntimeThreadResumeResult(
            conversation: RuntimeConversation(thread: thread, items: page.chronologicalItems),
            initialHistoryPage: page,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil
        )
    }

    private static func emptyPageResult(thread: RuntimeThread) -> RuntimeThreadResumeResult {
        RuntimeThreadResumeResult(
            conversation: RuntimeConversation(thread: thread, items: []),
            initialHistoryPage: nil,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil
        )
    }

    func listThreadHistory(
        id _: String,
        page request: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadHistoryPage {
        guard request.cursor == "older-page" else {
            throw AgentRuntimeError.protocolFailure("unexpected test cursor")
        }
        earlierPageRequested = true
        let waiters = earlierPageRequestWaiters
        earlierPageRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            earlierPageRelease = continuation
        }
        return RuntimeThreadHistoryPage(
            turns: [Self.turn(2), Self.turn(1)],
            nextCursor: nil,
            backwardsCursor: nil,
            direction: .descending
        )
    }

    func revertThread(id: String, beforeTurnID: String) async throws -> RuntimeThreadRevertResult {
        guard supportsEditing else {
            throw AgentRuntimeError.unsupported("thread history editing")
        }
        recordedReverts.append((id, beforeTurnID))
        revertRequested = true
        let waiters = revertRequestWaiters
        revertRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if suspendsRevert, !revertWasReleased {
            await withCheckedContinuation { continuation in
                revertRelease = continuation
            }
        }
        revertedThreadIDs.insert(id)
        if revertFailsAfterCommit {
            throw AgentRuntimeError.protocolFailure("simulated lost revert response")
        }
        return RuntimeThreadRevertResult(
            thread: Self.thread(for: id),
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil
        )
    }

    func waitUntilEarlierPageRequested() async {
        if earlierPageRequested { return }
        await withCheckedContinuation { continuation in
            earlierPageRequestWaiters.append(continuation)
        }
    }

    func releaseEarlierPage() {
        earlierPageRelease?.resume()
        earlierPageRelease = nil
    }

    func waitUntilRevertRequested() async {
        if revertRequested { return }
        await withCheckedContinuation { continuation in
            revertRequestWaiters.append(continuation)
        }
    }

    func releaseRevert() {
        revertWasReleased = true
        revertRelease?.resume()
        revertRelease = nil
    }

    func allowReconciliationReads() {
        reconciliationReadFails = false
    }

    func initialPageRequests() -> [RuntimeInitialThreadHistoryPageRequest] {
        recordedInitialRequests
    }

    func revertedTurnIDs() -> [(String, String)] { recordedReverts }
    func startedTurnTexts() -> [String] { recordedStartTurns.map(\.text) }

    func readCount() -> Int { recordedReadCount }
    func legacyResumeCount() -> Int { recordedLegacyResumeCount }
    func paginatedResumeCount() -> Int { recordedPaginatedResumeCount }
    func paginatedReadCount() -> Int { recordedPaginatedReadCount }
    func fullReadCount() -> Int { recordedReadCount }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread { Self.thread }
    func startTurn(_ request: StartTurnRequest) async throws {
        recordedStartTurns.append(request)
    }
    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}

    private nonisolated static func thread(for id: String) -> RuntimeThread {
        id == secondaryThread.id ? secondaryThread : thread
    }

    private static func turn(
        _ number: Int,
        userMessageCount: Int = 1,
        status: RuntimeConversationTurnStatus = .completed
    ) -> RuntimeConversationTurn {
        let userItems = (0..<max(1, userMessageCount)).map { messageIndex in
            TimelineItem(
                id: messageIndex == 0
                    ? "turn-\(number)-user"
                    : "turn-\(number)-user-\(messageIndex + 1)",
                kind: .userMessage,
                title: nil,
                body: messageIndex == 0
                    ? "User message \(number)"
                    : "Steered user message \(number).\(messageIndex + 1)",
                status: .completed,
                timestamp: Date(timeIntervalSince1970: Double(number * 2)),
                detail: nil,
                attachments: number == 4 && messageIndex == 0
                    ? [TimelineAttachment(
                        id: "turn-4-image",
                        source: .dataURL("data:image/png;base64,YQ=="),
                        accessibilityLabel: "reference.png"
                    )]
                    : []
            )
        }
        return RuntimeConversationTurn(
            id: "turn-\(number)",
            items: userItems + [
                TimelineItem(
                    id: "turn-\(number)-assistant",
                    kind: .assistantMessage,
                    title: nil,
                    body: "Assistant response \(number)",
                    status: .completed,
                    timestamp: Date(timeIntervalSince1970: Double(number * 2 + 1)),
                    detail: nil
                ),
            ],
            status: status,
            itemDetail: .full,
            startedAt: nil,
            completedAt: nil,
            durationMilliseconds: nil
        )
    }
}
