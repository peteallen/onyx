import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class OnyxAppModelDraftSafetyTests: XCTestCase {
    func testComposerDraftWriterOrdersBackgroundWritesAndRejectsStaleRevisions() throws {
        let suiteName = "OnyxAppModelDraftSafetyTests.writer-order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = OnyxComposerDraftPersistenceWriter(defaults: defaults)
        let key = "drafts"

        writer.persist(["task": "old"], forKey: key, revision: 1, mode: .background)
        writer.persist(["task": "new"], forKey: key, revision: 2, mode: .synchronous)
        XCTAssertEqual(defaults.dictionary(forKey: key)?["task"] as? String, "new")

        writer.persist(["task": "stale"], forKey: key, revision: 1, mode: .synchronous)
        XCTAssertEqual(defaults.dictionary(forKey: key)?["task"] as? String, "new")

        writer.remove(forKey: key, revision: 3, mode: .synchronous)
        writer.persist(["task": "resurrected"], forKey: key, revision: 2, mode: .synchronous)
        XCTAssertNil(defaults.object(forKey: key))
    }

    func testNewTaskPublishesImmediatelyWithoutWaitingForDraftStorage() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.new-task-responsive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = ControllableComposerDraftPersistence()
        let runtime = DraftSafetyRuntime(
            initialThreads: [DraftSafetyFixture.threadA],
            failurePoint: .none,
            capabilities: [.streaming]
        )
        let model = OnyxAppModel(
            runtime: runtime,
            defaults: defaults,
            composerDraftPersistence: persistence
        )
        model.start()
        await waitUntil("Thread A did not load") {
            model.selectedThreadID == DraftSafetyFixture.threadA.id
                && !model.isLoadingThread
        }
        model.composerText = "Keep the task draft"
        let synchronousPersistCountBeforeNavigation = persistence.synchronousPersistCount
        let backgroundPersistCountBeforeNavigation = persistence.backgroundPersistCount
        let taskListRevisionBeforeNavigation = model.threadListRevision

        model.newTask()

        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.welcomeThreadID)
        XCTAssertEqual(model.timeline.map(\.id), ["onyx-welcome"])
        XCTAssertTrue(model.composerText.isEmpty)
        XCTAssertFalse(model.isLoadingThread)
        XCTAssertFalse(model.isLoadingThreadList)
        XCTAssertFalse(model.isTurnRunning)
        XCTAssertNotNil(model.sidebarWelcomeThread)
        XCTAssertEqual(
            model.threadListRevision,
            taskListRevisionBeforeNavigation,
            "The synthetic composer row must not republish the full provider task list."
        )
        XCTAssertEqual(
            persistence.backgroundPersistCount,
            backgroundPersistCountBeforeNavigation + 1
        )
        XCTAssertEqual(
            persistence.synchronousPersistCount,
            synchronousPersistCountBeforeNavigation,
            "New Task must not add a synchronous draft write on the main actor."
        )
        XCTAssertEqual(
            persistence.latestDrafts?[DraftSafetyFixture.threadA.id],
            "Keep the task draft"
        )
    }

    func testFirstNewTaskWithRealisticHistoryStaysWithinInteractionBudget() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.new-task-scale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tasks = (0..<4_824).map { index in
            RuntimeThread(
                id: "scale-task-\(index)",
                title: "Scale task \(index)",
                preview: "A realistic long-lived task history",
                cwd: "/work/project-\(index % 224)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                status: .idle,
                isPinned: false,
                runtime: .codex,
                model: "test-model",
                branch: nil
            )
        }
        let model = OnyxAppModel(
            runtime: DraftSafetyRuntime(
                initialThreads: tasks,
                failurePoint: .none,
                capabilities: [.streaming]
            ),
            defaults: defaults
        )
        model.start()
        await waitUntil("The realistic task history did not load") {
            model.threads.count == tasks.count && !model.isLoadingThread
        }
        let taskListRevision = model.threadListRevision

        let clock = ContinuousClock()
        let start = clock.now
        model.newTask()
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.welcomeThreadID)
        XCTAssertEqual(
            model.selectedThread?.id,
            DraftSafetyFixture.welcomeThreadID,
            "The synthetic New Task selection must resolve without searching the durable task catalog"
        )
        XCTAssertEqual(model.threadListRevision, taskListRevision)
        XCTAssertLessThan(
            elapsed,
            .milliseconds(50),
            "The first New Task click missed the interaction budget: \(elapsed)"
        )
    }

    func testHostedNewTaskButtonShowsWelcomeComposerPromptlyWithRealisticHistory() async throws {
        let suiteName = "OnyxAppModelDraftSafetyTests.hosted-new-task-scale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tasks = (0..<4_824).map { index in
            RuntimeThread(
                id: "hosted-scale-task-\(index)",
                title: "Hosted scale task \(index)",
                preview: "A realistic long-lived task history",
                cwd: "/work/project-\(index % 224)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                status: .idle,
                isPinned: false,
                runtime: .codex,
                model: "test-model",
                branch: nil
            )
        }
        let initiallySelectedTask = try XCTUnwrap(tasks.last)
        defaults.set(true, forKey: "Onyx.sidebarVisible")
        defaults.set(false, forKey: "Onyx.inspectorVisible")
        defaults.set(false, forKey: "Onyx.bottomPanelVisible")
        defaults.set(initiallySelectedTask.id, forKey: "Onyx.selectedThreadID")

        let model = OnyxAppModel(
            runtime: DraftSafetyRuntime(
                initialThreads: tasks,
                failurePoint: .none,
                capabilities: [.streaming]
            ),
            defaults: defaults
        )
        model.start()
        await waitUntil("The hosted realistic task history did not load") {
            model.threads.count == tasks.count
                && model.selectedThreadID == initiallySelectedTask.id
                && !model.isLoadingThread
        }

        let size = NSSize(width: 1_200, height: 800)
        let hostingView = NSHostingView(
            rootView: OnyxWorkspaceView(model: model, defaults: defaults)
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
        try await Task.sleep(for: .milliseconds(20))
        hostingView.layoutSubtreeIfNeeded()

        // Hit the live SwiftUI control through AppKit's normal mouse-event
        // path. SwiftUI does not materialize its Button as an NSButton, and
        // querying the process-global accessibility server would turn this
        // into a permissions-sensitive UI test. The point is derived from the
        // sidebar/header metrics rather than from the machine's screen.
        let newTaskButtonPoint = NSPoint(
            x: WorkspacePaneLayout.sidebarDefaultWidth - 26.5,
            y: size.height - 24
        )
        let taskListRevision = model.threadListRevision
        let clock = ContinuousClock()
        let start = clock.now

        try click(at: newTaskButtonPoint, in: window)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        hostingView.layoutSubtreeIfNeeded()
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.welcomeThreadID)
        XCTAssertEqual(model.threadListRevision, taskListRevision)
        XCTAssertNotNil(
            hostingView.firstDescendantTextField(
                withString: "What are we building? I can work in this project, inspect its history, run tools, and keep the result grounded in the current checkout."
            ),
            "The hosted transcript did not publish the welcome surface after pressing New task"
        )
        let composer = try XCTUnwrap(hostingView.firstDescendant(ofType: NSTextView.self))
        XCTAssertFalse(composer.isHidden)
        XCTAssertNotNil(composer.window)
        XCTAssertLessThan(
            elapsed,
            .milliseconds(100),
            "The hosted New task interaction missed the paint budget: \(elapsed)"
        )
    }

    func testRepeatedNewTaskClicksAreIdempotent() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.new-task-repeat.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = ControllableComposerDraftPersistence()
        let runtime = DraftSafetyRuntime(
            initialThreads: [DraftSafetyFixture.threadA],
            failurePoint: .none,
            capabilities: [.streaming]
        )
        let model = OnyxAppModel(
            runtime: runtime,
            defaults: defaults,
            composerDraftPersistence: persistence
        )
        model.start()
        await waitUntil("Thread A did not load") {
            model.selectedThreadID == DraftSafetyFixture.threadA.id
                && !model.isLoadingThread
        }

        model.newTask()
        let transcriptRevision = model.transcriptSnapshot.revision
        let taskListRevision = model.threadListRevision
        let persistCount = persistence.backgroundPersistCount

        for _ in 0..<50 { model.newTask() }

        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.welcomeThreadID)
        XCTAssertEqual(model.transcriptSnapshot.revision, transcriptRevision)
        XCTAssertEqual(model.threadListRevision, taskListRevision)
        XCTAssertEqual(persistence.backgroundPersistCount, persistCount)
    }

    func testNewTaskFromArchivedReturnsToActiveAndRefreshesWithoutKeepingArchivedRows() async {
        let fixture = makeFixture(initialThreads: [DraftSafetyFixture.threadA])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The active task did not load") {
            model.selectedThreadID == DraftSafetyFixture.threadA.id
                && !model.isLoadingThreadList
        }

        model.setThreadListScope(.archived)
        await waitUntil("The archived list did not load") {
            model.isShowingArchivedThreads && !model.isLoadingThreadList
        }
        XCTAssertTrue(model.threads.isEmpty)

        model.newTask()

        XCTAssertEqual(model.threadListScope, .active)
        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.welcomeThreadID)
        XCTAssertEqual(model.threads.map(\.id), [DraftSafetyFixture.welcomeThreadID])
        await waitUntil("New Task did not refresh active tasks after leaving Archived") {
            !model.isLoadingThreadList
                && model.threads.contains(where: { $0.id == DraftSafetyFixture.threadA.id })
        }
        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.welcomeThreadID)
    }

    func testNewTaskWhileAThreadIsStartingInvalidatesThePendingSelection() async {
        let fixture = makeFixture(initialThreads: [], failurePoint: .startThread)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The new-task composer did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.welcomeThreadID
        }

        model.composerText = "Start this task"
        model.sendComposer()
        await waitUntilAsync("The start-thread request did not begin") {
            await fixture.runtime.startThreadRequestCount() == 1
        }
        XCTAssertTrue(model.isTurnRunning)

        model.newTask()
        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.welcomeThreadID)
        XCTAssertFalse(model.isTurnRunning)

        await fixture.runtime.releaseFailure()
        await waitUntil("The failed pending send did not settle") {
            model.notice?.title == "Could not send"
        }
        XCTAssertEqual(
            model.selectedThreadID,
            DraftSafetyFixture.welcomeThreadID,
            "A late start-thread failure must not undo the user's New Task navigation."
        )
    }

    func testFailedPendingStartPreservesANewerWelcomeDraftAfterNewTask() async {
        let fixture = makeFixture(initialThreads: [], failurePoint: .startThread)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The new-task composer did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.welcomeThreadID
        }

        model.composerText = "First request"
        model.sendComposer()
        await waitUntilAsync("The start-thread request did not begin") {
            await fixture.runtime.startThreadRequestCount() == 1
        }

        model.newTask()
        model.composerText = "New welcome draft"
        await fixture.runtime.releaseFailure()
        await waitUntil("The failed pending send did not settle") {
            model.notice?.title == "Could not send"
        }

        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.welcomeThreadID)
        XCTAssertEqual(model.composerText, "First request\n\nNew welcome draft")
        await waitForPersistedDraft(
            fixture,
            key: DraftSafetyFixture.welcomeThreadID,
            value: "First request\n\nNew welcome draft"
        )
    }

    func testProviderWithoutCatalogUsesNeutralModelPlaceholder() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.neutral-model-placeholder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = DraftSafetyRuntime(
            initialThreads: [],
            failurePoint: .none,
            capabilities: [.streaming],
            kind: .local
        )
        let model = OnyxAppModel(runtime: runtime, defaults: defaults, startsWithNewTask: true)

        model.start()
        await waitUntil("The local provider did not connect") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.welcomeThreadID
        }

        XCTAssertEqual(model.selectedModelName, "Choose model")
    }

    func testModelUsageIsRecordedAfterAcceptedSendNotWhenModelIsPicked() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(DraftSafetyFixture.workspacePath, forKey: "Onyx.lastWorkspacePath")

        let runtime = DraftSafetyRuntime(
            initialThreads: [],
            failurePoint: .none,
            capabilities: [.streaming]
        )
        var usedModels: [String] = []
        let model = OnyxAppModel(
            runtime: runtime,
            defaults: defaults,
            modelUsageRecorder: { usedModels.append($0) }
        )

        model.start()
        await waitUntil("The new-task composer did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.welcomeThreadID
        }

        model.selectModel("explicit-model")
        XCTAssertTrue(usedModels.isEmpty, "Picking a model must not count as using it.")

        model.composerText = "Send this with the selected model"
        model.sendComposer()
        await waitUntilAsync("The turn did not reach the runtime") {
            await runtime.recordedStartTurns().count == 1
        }
        await waitUntil("The accepted send did not record model usage") {
            usedModels == ["explicit-model"]
        }
    }

    func testFailedSendDoesNotRecordModelUsage() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.failed-usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = DraftSafetyRuntime(
            initialThreads: [DraftSafetyFixture.threadA],
            failurePoint: .startTurn,
            capabilities: [.streaming]
        )
        var usedModels: [String] = []
        let model = OnyxAppModel(
            runtime: runtime,
            defaults: defaults,
            modelUsageRecorder: { usedModels.append($0) }
        )

        model.start()
        await waitUntil("Thread A did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }
        model.selectModel("explicit-model")
        model.composerText = "This request fails"
        model.sendComposer()
        await waitUntilAsync("The failing turn did not reach the runtime") {
            await runtime.recordedStartTurns().count == 1
        }
        await runtime.releaseFailure()
        await waitUntil("The failed send did not surface an error") {
            model.notice?.title == "Could not send"
        }
        XCTAssertTrue(usedModels.isEmpty)
    }

    func testExistingTaskDisplaysAndDispatchesItsPinnedModel() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.pinned-model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("window-picker-model", forKey: "Onyx.selectedModelID")

        let pinnedThread = RuntimeThread(
            id: "pinned-model-thread",
            title: "Pinned model task",
            preview: "Pinned model task",
            cwd: DraftSafetyFixture.workspacePath,
            updatedAt: .now,
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "task-pinned-model",
            branch: nil
        )
        let runtime = DraftSafetyRuntime(
            initialThreads: [pinnedThread],
            failurePoint: .none,
            capabilities: [.streaming]
        )
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)

        model.start()
        await waitUntil("The pinned-model task did not load") {
            model.canRunAgent && model.selectedThreadID == pinnedThread.id
        }

        model.selectModel("window-picker-model")
        XCTAssertEqual(model.selectedModelID, "window-picker-model")
        XCTAssertEqual(model.selectedTaskModelID, "task-pinned-model")
        XCTAssertEqual(model.selectedModelName, "task-pinned-model")

        model.composerText = "Continue this task"
        model.sendComposer()
        await waitUntilAsync("The pinned-model turn did not reach the runtime") {
            await runtime.recordedStartTurns().count == 1
        }
        let turn = await runtime.recordedStartTurns()[0]
        XCTAssertEqual(turn.model, "task-pinned-model")
    }

    func testExistingTaskCanChooseModelForNextTurnAndResetToTaskDefault() async throws {
        let suiteName = "OnyxAppModelDraftSafetyTests.task-model-override.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = DraftSafetyRuntime(
            initialThreads: [DraftSafetyFixture.threadA],
            failurePoint: .none,
            capabilities: [.streaming],
            availableModels: [
                RuntimeModel(
                    id: "test-model",
                    displayName: "Task default",
                    description: nil,
                    isDefault: true,
                    defaultReasoningEffort: nil,
                    reasoningEfforts: []
                ),
                RuntimeModel(
                    id: "alternate-model",
                    displayName: "Alternate model",
                    description: nil,
                    isDefault: false,
                    defaultReasoningEffort: nil,
                    reasoningEfforts: []
                ),
            ]
        )
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        model.start()
        await waitUntil("The task did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }

        XCTAssertEqual(model.selectedTaskDefaultModelID, "test-model")
        XCTAssertEqual(model.selectedTaskModelID, "test-model")

        model.selectTaskModel("alternate-model")
        XCTAssertEqual(model.selectedTaskModelID, "alternate-model")
        XCTAssertEqual(
            (defaults.dictionary(forKey: "Onyx.taskModelOverrides") as? [String: String])?[DraftSafetyFixture.threadA.id],
            "alternate-model"
        )
        XCTAssertEqual(
            (defaults.dictionary(forKey: "Onyx.taskModelDefaults") as? [String: String])?[DraftSafetyFixture.threadA.id],
            "test-model"
        )

        model.composerText = "Continue with the alternate model"
        model.sendComposer()
        await waitUntilAsync("The overridden model turn did not reach the runtime") {
            await runtime.recordedStartTurns().count == 1
        }
        let recordedTurns = await runtime.recordedStartTurns()
        let turn = try XCTUnwrap(recordedTurns.first)
        XCTAssertEqual(turn.model, "alternate-model")

        // Both Codex app-server and OpenAI-compatible providers can publish
        // the model used by the latest turn back onto the task. That update
        // must not redefine the reset target as the override itself.
        await runtime.publishThreadModel(
            threadID: DraftSafetyFixture.threadA.id,
            modelID: "alternate-model"
        )
        await waitUntil("The task model update did not reach the app model") {
            model.selectedThread?.model == "alternate-model"
        }
        XCTAssertEqual(model.selectedTaskDefaultModelID, "test-model")
        XCTAssertEqual(model.selectedTaskModelID, "alternate-model")

        model.resetSelectedTaskModel()
        XCTAssertEqual(model.selectedTaskModelID, "test-model")
        XCTAssertNil(defaults.dictionary(forKey: "Onyx.taskModelOverrides"))
        XCTAssertEqual(
            (defaults.dictionary(forKey: "Onyx.taskModelDefaults") as? [String: String])?[DraftSafetyFixture.threadA.id],
            "test-model"
        )

        model.composerText = "Return to the task default"
        model.sendComposer()
        await waitUntilAsync("The reset model turn did not reach the runtime") {
            await runtime.recordedStartTurns().count == 2
        }
        let resetTurns = await runtime.recordedStartTurns()
        let resetTurn = try XCTUnwrap(resetTurns.last)
        XCTAssertEqual(resetTurn.model, "test-model")
    }

    func testExistingTaskWithoutRecordedModelSnapshotsProviderDefaultBeforeSwitching() async throws {
        let suiteName = "OnyxAppModelDraftSafetyTests.task-model-provider-default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var legacyThread = DraftSafetyFixture.threadA
        legacyThread.model = nil
        let runtime = DraftSafetyRuntime(
            initialThreads: [legacyThread],
            failurePoint: .none,
            capabilities: [.streaming],
            availableModels: [
                RuntimeModel(
                    id: "provider-default",
                    displayName: "Provider default",
                    description: nil,
                    isDefault: true,
                    defaultReasoningEffort: nil,
                    reasoningEfforts: []
                ),
                RuntimeModel(
                    id: "alternate-model",
                    displayName: "Alternate model",
                    description: nil,
                    isDefault: false,
                    defaultReasoningEffort: nil,
                    reasoningEfforts: []
                ),
            ]
        )
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        model.start()
        await waitUntil("The legacy task did not load") {
            model.canRunAgent && model.selectedThreadID == legacyThread.id
        }

        XCTAssertEqual(model.selectedTaskDefaultModelID, "provider-default")
        model.selectTaskModel("alternate-model")
        XCTAssertEqual(
            (defaults.dictionary(forKey: "Onyx.taskModelDefaults") as? [String: String])?[legacyThread.id],
            "provider-default"
        )
        XCTAssertEqual(model.selectedTaskDefaultModelID, "provider-default")
        model.resetSelectedTaskModel()
        XCTAssertEqual(model.selectedTaskModelID, "provider-default")
    }

    func testProviderDeletedTaskClearsPersistedModelSelectionState() async throws {
        let suiteName = "OnyxAppModelDraftSafetyTests.task-model-delete.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let runtime = DraftSafetyRuntime(
            initialThreads: [DraftSafetyFixture.threadA],
            failurePoint: .none,
            capabilities: [.streaming]
        )
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        model.start()
        await waitUntil("The task did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }
        model.selectTaskModel("alternate-model")
        XCTAssertFalse(model.taskModelOverrides.isEmpty)
        XCTAssertFalse(model.taskModelDefaults.isEmpty)

        await runtime.publishThreadDeleted(DraftSafetyFixture.threadA.id)
        await waitUntil("The provider deletion did not remove the task") {
            !model.threads.contains(where: { $0.id == DraftSafetyFixture.threadA.id })
        }

        XCTAssertTrue(model.taskModelOverrides.isEmpty)
        XCTAssertTrue(model.taskModelDefaults.isEmpty)
        XCTAssertNil(defaults.object(forKey: "Onyx.taskModelOverrides"))
        XCTAssertNil(defaults.object(forKey: "Onyx.taskModelDefaults"))
    }

    func testSwitchingPinnedTasksRevalidatesReasoningEffortBeforeSend() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.pinned-reasoning.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let taskA = RuntimeThread(
            id: "reasoning-task-a",
            title: "Reasoning task A",
            preview: "Reasoning task A",
            cwd: DraftSafetyFixture.workspacePath,
            updatedAt: Date(timeIntervalSince1970: 2),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "reasoning-model-a",
            branch: nil
        )
        let taskB = RuntimeThread(
            id: "reasoning-task-b",
            title: "Reasoning task B",
            preview: "Reasoning task B",
            cwd: DraftSafetyFixture.workspacePath,
            updatedAt: Date(timeIntervalSince1970: 1),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "reasoning-model-b",
            branch: nil
        )
        let runtime = DraftSafetyRuntime(
            initialThreads: [taskA, taskB],
            failurePoint: .none,
            capabilities: [.streaming],
            availableModels: [
                RuntimeModel(
                    id: "reasoning-model-a",
                    displayName: "Reasoning model A",
                    description: nil,
                    isDefault: true,
                    defaultReasoningEffort: "high",
                    reasoningEfforts: ["high"],
                    supportedRequestParameters: [.reasoningEffort]
                ),
                RuntimeModel(
                    id: "reasoning-model-b",
                    displayName: "Reasoning model B",
                    description: nil,
                    isDefault: false,
                    defaultReasoningEffort: "low",
                    reasoningEfforts: ["low"],
                    supportedRequestParameters: [.reasoningEffort]
                )
            ]
        )
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)

        model.start()
        await waitUntil("Reasoning task A did not load") {
            model.canRunAgent && model.selectedThreadID == taskA.id && !model.isLoadingThread
        }
        model.selectReasoningEffort("high")
        XCTAssertEqual(model.selectedReasoningEffort, "high")

        model.selectThread(taskB.id)
        await waitUntil("Reasoning task B did not load") {
            model.selectedThreadID == taskB.id && !model.isLoadingThread
        }
        XCTAssertEqual(
            model.selectedReasoningEffort,
            "low",
            "Task B must not retain task A's unsupported reasoning effort."
        )

        model.composerText = "Continue with task B's supported effort"
        model.sendComposer()
        await waitUntilAsync("The task B turn did not reach the runtime") {
            await runtime.recordedStartTurns().count == 1
        }
        let turn = await runtime.recordedStartTurns()[0]
        XCTAssertEqual(turn.model, "reasoning-model-b")
        XCTAssertEqual(turn.reasoningEffort, "low")
    }

    func testNewTaskContextTransfersBetweenProviderModelsWithoutCountingUsage() async throws {
        let sourceSuiteName = "OnyxAppModelDraftSafetyTests.transfer.source.\(UUID().uuidString)"
        let targetSuiteName = "OnyxAppModelDraftSafetyTests.transfer.target.\(UUID().uuidString)"
        let sourceDefaults = UserDefaults(suiteName: sourceSuiteName)!
        let targetDefaults = UserDefaults(suiteName: targetSuiteName)!
        sourceDefaults.removePersistentDomain(forName: sourceSuiteName)
        targetDefaults.removePersistentDomain(forName: targetSuiteName)
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuiteName)
            targetDefaults.removePersistentDomain(forName: targetSuiteName)
        }

        var recordedUsage: [String] = []
        let source = OnyxAppModel(
            runtime: nil,
            defaults: sourceDefaults,
            modelUsageRecorder: { recordedUsage.append($0) }
        )
        let target = OnyxAppModel(
            runtime: nil,
            defaults: targetDefaults,
            startsWithNewTask: true,
            modelUsageRecorder: { recordedUsage.append($0) }
        )
        source.composerText = "Keep this exact draft"
        source.selectWorkspace("/tmp/provider-switch-project")
        source.permissionLabel = "Read only"
        source.selectedReasoningEffort = "high"
        // Use a representative in-memory image draft without touching disk.
        let image = ComposerImageDraft(
            input: .imageURL("data:image/png;base64,YQ=="),
            displayName: "transfer.png",
            byteCount: 1
        )
        let context = try XCTUnwrap(source.captureNewTaskContext())
        let completeContext = OnyxAppModel.NewTaskContext(
            composerText: context.composerText,
            composerImages: [image],
            workspacePath: context.workspacePath,
            reasoningEffort: context.reasoningEffort,
            permissionLabel: context.permissionLabel
        )

        target.selectModel("target-provider-model")
        source.restoreNewTaskContext(completeContext)
        OnyxApplicationHost.transferNewTaskContext(from: source, to: target)

        XCTAssertEqual(target.selectedModelID, "target-provider-model")
        XCTAssertEqual(target.composerText, "Keep this exact draft")
        XCTAssertEqual(target.composerImages, [image])
        XCTAssertEqual(target.draftWorkspacePath, "/tmp/provider-switch-project")
        XCTAssertEqual(target.permissionLabel, "Read only")
        XCTAssertEqual(target.selectedReasoningEffort, "high")
        XCTAssertTrue(recordedUsage.isEmpty, "Switching providers or models must not count as use.")
    }

    func testProviderSwitchStagesDraftWithoutSynchronousMainActorPersistence() throws {
        let sourceDefaults = UserDefaults(
            suiteName: "OnyxAppModelDraftSafetyTests.provider-switch-source.\(UUID().uuidString)"
        )!
        let targetDefaults = UserDefaults(
            suiteName: "OnyxAppModelDraftSafetyTests.provider-switch-target.\(UUID().uuidString)"
        )!
        let persistence = ControllableComposerDraftPersistence()
        let source = OnyxAppModel(
            runtime: nil,
            defaults: sourceDefaults,
            composerDraftPersistence: persistence
        )
        let target = OnyxAppModel(runtime: nil, defaults: targetDefaults)
        source.composerText = "Keep this provider-switch draft"

        OnyxApplicationHost.transferNewTaskContext(from: source, to: target)

        XCTAssertEqual(target.composerText, "Keep this provider-switch draft")
        XCTAssertEqual(persistence.backgroundPersistCount, 1)
        XCTAssertEqual(
            persistence.synchronousPersistCount,
            0,
            "Switching providers must paint before draft serialization finishes"
        )
    }

    func testWorkspaceValidationPersistsDraftAndChoosingWorkspaceKeepsItUntilSuccessfulSend() async throws {
        let fixture = makeFixture(initialThreads: [], workspacePath: nil)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The empty runtime did not show the new-task composer") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.welcomeThreadID
        }

        let exactDraft = "  Build the project carefully.  "
        model.composerText = exactDraft
        model.sendComposer()

        XCTAssertEqual(model.notice?.title, "Choose a project")
        XCTAssertEqual(model.composerText, exactDraft)
        await waitForPersistedDraft(
            fixture,
            key: DraftSafetyFixture.welcomeThreadID,
            value: exactDraft
        )
        let rejectedStartThreadCount = await fixture.runtime.startThreadRequestCount()
        XCTAssertEqual(rejectedStartThreadCount, 0)

        model.selectWorkspace(DraftSafetyFixture.workspacePath)

        XCTAssertEqual(model.draftWorkspacePath, DraftSafetyFixture.workspacePath)
        XCTAssertEqual(model.composerText, exactDraft)
        await waitForPersistedDraft(
            fixture,
            key: DraftSafetyFixture.welcomeThreadID,
            value: exactDraft
        )

        model.dismissNotice()
        model.sendComposer()

        XCTAssertEqual(model.composerText, "", "A valid send should still clear the composer immediately.")
        XCTAssertTrue(
            model.isTurnRunning,
            "The chat must show its inline waiting state immediately, before provider setup finishes."
        )
        await waitUntilAsync("The valid draft never reached the runtime") {
            await fixture.runtime.recordedStartTurns().count == 1
        }

        let recordedTurns = await fixture.runtime.recordedStartTurns()
        let turn = try XCTUnwrap(recordedTurns.first)
        XCTAssertEqual(turn.threadID, DraftSafetyFixture.createdThread.id)
        XCTAssertEqual(turn.text, "Build the project carefully.")
        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.createdThread.id)
        await waitForPersistedDraftRemoval(
            fixture,
            keys: [DraftSafetyFixture.welcomeThreadID, DraftSafetyFixture.createdThread.id]
        )
    }

    func testUnavailableRuntimeKeepsDraftVisibleAndDurable() async {
        let suiteName = "OnyxAppModelDraftSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = OnyxAppModel(
            runtime: nil,
            startupError: AgentRuntimeError.executableNotFound,
            defaults: defaults
        )
        let exactDraft = "  Keep this even when Codex cannot start.\n"

        model.composerText = exactDraft
        model.sendComposer()

        XCTAssertEqual(model.notice?.title, "Agent runtime is unavailable")
        XCTAssertEqual(model.composerText, exactDraft)
        await waitUntil("The unavailable-runtime draft was not persisted") {
            let persisted = defaults.dictionary(forKey: "Onyx.composerDrafts") as? [String: String]
            return persisted?[DraftSafetyFixture.welcomeThreadID] == exactDraft
        }

        let relaunchedModel = OnyxAppModel(runtime: nil, defaults: defaults)
        XCTAssertEqual(relaunchedModel.composerText, exactDraft)
    }

    func testStartThreadFailureRestoresExactDraftWithoutOverwritingFollowUp() async {
        let fixture = makeFixture(initialThreads: [], failurePoint: .startThread)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The empty runtime did not show the new-task composer") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.welcomeThreadID
        }

        let exactDraft = "  First request with intentional spaces  "
        let followUp = "Follow-up typed while Codex starts"
        model.composerText = exactDraft
        model.sendComposer()
        await waitUntilAsync("The start-thread call did not reach the runtime") {
            await fixture.runtime.startThreadRequestCount() == 1
        }

        XCTAssertEqual(model.composerText, "")
        model.composerText = followUp
        await fixture.runtime.releaseFailure()

        await waitUntil("The start-thread failure was not shown") {
            model.notice?.title == "Could not send"
        }

        let restored = exactDraft + "\n\n" + followUp
        XCTAssertEqual(model.composerText, restored)
        await waitForPersistedDraft(
            fixture,
            key: DraftSafetyFixture.welcomeThreadID,
            value: restored
        )
        let startedTurnCount = await fixture.runtime.recordedStartTurns().count
        XCTAssertEqual(startedTurnCount, 0)
    }

    func testStartTurnFailureRestoresSendingTaskWithoutTouchingNewerSelection() async {
        let fixture = makeFixture(
            initialThreads: [DraftSafetyFixture.threadA, DraftSafetyFixture.threadB],
            failurePoint: .startTurn
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Thread A did not finish its initial load") {
            model.canRunAgent
                && model.selectedThreadID == DraftSafetyFixture.threadA.id
                && model.timeline == [DraftSafetyFixture.itemA]
        }

        let exactDraft = "  Message intended for A  "
        let followUpForA = "A follow-up typed while its turn starts"
        let draftForB = "Do not replace B's draft"
        model.composerText = exactDraft
        model.sendComposer()
        await waitUntilAsync("The start-turn call did not reach the runtime") {
            await fixture.runtime.recordedStartTurns().count == 1
        }

        model.composerText = followUpForA
        model.selectThread(DraftSafetyFixture.threadB.id)
        await waitUntil("Thread B did not finish loading") {
            model.selectedThreadID == DraftSafetyFixture.threadB.id
                && model.timeline == [DraftSafetyFixture.itemB]
        }
        model.composerText = draftForB

        await fixture.runtime.releaseFailure()
        await waitUntil("The start-turn failure was not shown") {
            model.notice?.title == "Could not send"
        }

        let restoredForA = exactDraft + "\n\n" + followUpForA
        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.threadB.id)
        XCTAssertEqual(model.composerText, draftForB)
        await waitForPersistedDraft(
            fixture,
            key: DraftSafetyFixture.threadA.id,
            value: restoredForA
        )
        XCTAssertEqual(
            model.threads.first(where: { $0.id == DraftSafetyFixture.threadA.id })?.status,
            .idle
        )

        model.selectThread(DraftSafetyFixture.threadA.id)
        XCTAssertEqual(model.composerText, restoredForA)
        await waitForPersistedDraft(
            fixture,
            key: DraftSafetyFixture.threadB.id,
            value: draftForB
        )
    }

    func testImageOnlySendReachesRuntimeAndAppearsOptimisticallyInTimeline() async throws {
        let fixture = makeFixture(
            initialThreads: [DraftSafetyFixture.threadA],
            capabilities: [.streaming, .images]
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Thread A did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }

        model.addPastedComposerImages([makeImage(color: .systemPurple)])
        await waitUntil("The pasted image did not finish preparing") {
            model.composerImages.count == 1
        }
        let draft = try XCTUnwrap(model.composerImages.first)
        model.sendComposer()

        await waitUntilAsync("The image-only turn never reached the runtime") {
            await fixture.runtime.recordedStartTurns().count == 1
        }
        let recordedTurns = await fixture.runtime.recordedStartTurns()
        let request = try XCTUnwrap(recordedTurns.first)
        XCTAssertEqual(request.inputs, [draft.input])
        XCTAssertTrue(model.composerText.isEmpty)
        XCTAssertTrue(model.composerImages.isEmpty)
        let optimistic = try XCTUnwrap(model.timeline.last(where: { $0.id.hasPrefix("optimistic:") }))
        XCTAssertEqual(optimistic.body, "")
        XCTAssertEqual(optimistic.attachments.map(\.source), [draft.timelineAttachment.source])
    }

    func testFailedImageSendRestoresOnlyItsOriginatingDraftAcrossNavigation() async throws {
        let fixture = makeFixture(
            initialThreads: [DraftSafetyFixture.threadA, DraftSafetyFixture.threadB],
            failurePoint: .startTurn,
            capabilities: [.streaming, .images]
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Thread A did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }

        model.addPastedComposerImages([makeImage(color: .systemRed)])
        await waitUntil("The first pasted image did not finish preparing") {
            model.composerImages.count == 1
        }
        let sentID = try XCTUnwrap(model.composerImages.first?.id)
        model.sendComposer()
        await waitUntilAsync("The image turn did not begin") {
            await fixture.runtime.recordedStartTurns().count == 1
        }

        model.addPastedComposerImages([makeImage(color: .systemOrange)])
        await waitUntil("The follow-up image did not finish preparing") {
            model.composerImages.count == 1
        }
        let laterAID = try XCTUnwrap(model.composerImages.first?.id)
        model.selectThread(DraftSafetyFixture.threadB.id)
        await waitUntil("Thread B did not load") { model.selectedThreadID == DraftSafetyFixture.threadB.id }
        model.addPastedComposerImages([makeImage(color: .systemBlue)])
        await waitUntil("Thread B's image did not finish preparing") {
            model.composerImages.count == 1
        }
        let draftBIDs = model.composerImages.map(\.id)

        await fixture.runtime.releaseFailure()
        await waitUntil("The failure was not surfaced") { model.notice?.title == "Could not send" }

        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.threadB.id)
        XCTAssertEqual(model.composerImages.map(\.id), draftBIDs)
        model.selectThread(DraftSafetyFixture.threadA.id)
        XCTAssertEqual(model.composerImages.map(\.id), [sentID, laterAID])
    }

    func testRuntimeWithoutImageCapabilityRejectsPasteWithoutChangingDraft() async {
        let fixture = makeFixture(initialThreads: [DraftSafetyFixture.threadA])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Thread A did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }

        model.addPastedComposerImages([makeImage(color: .systemPurple)])
        await Task.yield()

        XCTAssertFalse(model.canAttachImages)
        XCTAssertTrue(model.composerImages.isEmpty)
        XCTAssertEqual(model.notice?.title, "Images are not available")
    }

    private func makeImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        return image
    }

    private func makeFixture(
        initialThreads: [RuntimeThread],
        failurePoint: DraftSafetyRuntime.FailurePoint = .none,
        workspacePath: String? = DraftSafetyFixture.workspacePath,
        capabilities: RuntimeCapabilities = [.streaming]
    ) -> DraftSafetyFixture {
        let suiteName = "OnyxAppModelDraftSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let workspacePath {
            defaults.set(workspacePath, forKey: "Onyx.lastWorkspacePath")
        }
        let runtime = DraftSafetyRuntime(
            initialThreads: initialThreads,
            failurePoint: failurePoint,
            capabilities: capabilities
        )
        return DraftSafetyFixture(
            model: OnyxAppModel(runtime: runtime, defaults: defaults),
            runtime: runtime,
            defaults: defaults,
            defaultsSuiteName: suiteName
        )
    }

    private func persistedDrafts(_ fixture: DraftSafetyFixture) -> [String: String] {
        fixture.defaults.dictionary(forKey: "Onyx.composerDrafts") as? [String: String] ?? [:]
    }

    private func waitForPersistedDraft(
        _ fixture: DraftSafetyFixture,
        key: String,
        value: String,
        timeout: Duration = .seconds(1)
    ) async {
        await waitUntil("Draft (key) was not persisted", timeout: timeout) {
            persistedDrafts(fixture)[key] == value
        }
    }

    private func waitForPersistedDraftRemoval(
        _ fixture: DraftSafetyFixture,
        keys: [String],
        timeout: Duration = .seconds(1)
    ) async {
        await waitUntil("Draft removal was not persisted", timeout: timeout) {
            let drafts = persistedDrafts(fixture)
            return keys.allSatisfy { drafts[$0] == nil }
        }
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), failureMessage)
    }

    private func waitUntilAsync(
        _ failureMessage: String,
        timeout: Duration = .seconds(1),
        condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            await Task.yield()
        }
        let didMeetCondition = await condition()
        XCTAssertTrue(didMeetCondition, failureMessage)
    }

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

private extension NSView {
    func firstDescendant<View: NSView>(ofType type: View.Type) -> View? {
        if let match = self as? View { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }

    func firstDescendantTextField(withString string: String) -> NSTextField? {
        if let textField = self as? NSTextField, textField.stringValue == string {
            return textField
        }
        for subview in subviews {
            if let match = subview.firstDescendantTextField(withString: string) { return match }
        }
        return nil
    }
}

private final class ControllableComposerDraftPersistence: OnyxComposerDraftPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var backgroundCount = 0
    private var synchronousCount = 0
    private var recordedDrafts: [String: String]?

    var backgroundPersistCount: Int {
        lock.withLock { backgroundCount }
    }

    var synchronousPersistCount: Int {
        lock.withLock { synchronousCount }
    }

    var latestDrafts: [String: String]? {
        lock.withLock { recordedDrafts }
    }

    func persist(
        _ drafts: [String: String],
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    ) {
        lock.withLock {
            recordedDrafts = drafts
            switch mode {
            case .background: backgroundCount += 1
            case .synchronous: synchronousCount += 1
            }
        }
    }

    func remove(
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    ) {
        lock.withLock {
            recordedDrafts = nil
            switch mode {
            case .background: backgroundCount += 1
            case .synchronous: synchronousCount += 1
            }
        }
    }
}

private struct DraftSafetyFixture {
    static let welcomeThreadID = "onyx:welcome"
    static let workspacePath = "/tmp"
    static let threadA = makeThread(id: "draft-safety-A", title: "Thread A", updatedAt: 3)
    static let threadB = makeThread(id: "draft-safety-B", title: "Thread B", updatedAt: 2)
    static let createdThread = makeThread(id: "draft-safety-created", title: "Created task", updatedAt: 4)
    static let itemA = makeItem(id: "item-A", body: "A history")
    static let itemB = makeItem(id: "item-B", body: "B history")

    let model: OnyxAppModel
    let runtime: DraftSafetyRuntime
    let defaults: UserDefaults
    let defaultsSuiteName: String

    @MainActor
    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private static func makeThread(
        id: String,
        title: String,
        updatedAt: TimeInterval
    ) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: title,
            preview: title,
            cwd: workspacePath,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "test-model",
            branch: nil
        )
    }

    private static func makeItem(id: String, body: String) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: .assistantMessage,
            title: nil,
            body: body,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1),
            detail: nil
        )
    }
}

private actor DraftSafetyRuntime: AgentRuntime {
    enum FailurePoint: Sendable {
        case none
        case startThread
        case startTurn
    }

    nonisolated let kind: AgentRuntimeKind
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let continuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let initialThreads: [RuntimeThread]
    private let failurePoint: FailurePoint
    private let capabilities: RuntimeCapabilities
    private let availableModels: [RuntimeModel]
    private var createdThreads: [String: RuntimeThread] = [:]
    private var startThreadRequests: [StartThreadRequest] = []
    private var startTurns: [StartTurnRequest] = []
    private var failureContinuation: CheckedContinuation<Void, Never>?

    init(
        initialThreads: [RuntimeThread],
        failurePoint: FailurePoint,
        capabilities: RuntimeCapabilities,
        availableModels: [RuntimeModel] = [],
        kind: AgentRuntimeKind = .codex
    ) {
        self.kind = kind
        self.initialThreads = initialThreads
        self.failurePoint = failurePoint
        self.capabilities = capabilities
        self.availableModels = availableModels
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        continuation.yield(.connectionChanged(.connected("Draft safety runtime")))
        return RuntimeSession(
            runtime: .codex,
            displayName: "Draft safety runtime",
            accountLabel: "draft-safety@example.com",
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: .chatgpt,
                email: "draft-safety@example.com",
                planLabel: nil,
                requiresAuthentication: true
            ),
            availableLoginMethods: [],
            availableModels: availableModels,
            capabilities: capabilities
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        guard !archived else { return [] }
        return (initialThreads + createdThreads.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        switch id {
        case DraftSafetyFixture.threadA.id:
            RuntimeConversation(
                thread: initialThreads.first(where: { $0.id == id }) ?? DraftSafetyFixture.threadA,
                items: [DraftSafetyFixture.itemA]
            )
        case DraftSafetyFixture.threadB.id:
            RuntimeConversation(
                thread: initialThreads.first(where: { $0.id == id }) ?? DraftSafetyFixture.threadB,
                items: [DraftSafetyFixture.itemB]
            )
        default:
            if let thread = initialThreads.first(where: { $0.id == id }) ?? createdThreads[id] {
                RuntimeConversation(thread: thread, items: [])
            } else {
                throw AgentRuntimeError.missingField("test thread \(id)")
            }
        }
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await readThread(id: id)
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        startThreadRequests.append(request)
        if failurePoint == .startThread {
            await suspendFailure()
            throw AgentRuntimeError.protocolFailure("simulated start-thread failure")
        }
        let thread = DraftSafetyFixture.createdThread
        createdThreads[thread.id] = thread
        return thread
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        startTurns.append(request)
        if failurePoint == .startTurn {
            await suspendFailure()
            throw AgentRuntimeError.protocolFailure("simulated start-turn failure")
        }
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

    func startThreadRequestCount() -> Int {
        startThreadRequests.count
    }

    func recordedStartTurns() -> [StartTurnRequest] {
        startTurns
    }

    func publishThreadModel(threadID: String, modelID: String) {
        guard var thread = (initialThreads + Array(createdThreads.values)).first(where: {
            $0.id == threadID
        }) else { return }
        thread.model = modelID
        continuation.yield(.threadUpdated(thread))
    }

    func publishThreadDeleted(_ threadID: String) {
        continuation.yield(.threadDeleted(threadID: threadID))
    }

    func releaseFailure() {
        failureContinuation?.resume()
        failureContinuation = nil
    }

    private func suspendFailure() async {
        await withCheckedContinuation { continuation in
            failureContinuation = continuation
        }
    }
}
