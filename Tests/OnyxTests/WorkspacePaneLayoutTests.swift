import CoreGraphics
import Foundation
import XCTest
@testable import Onyx

@MainActor
final class WorkspacePaneLayoutTests: XCTestCase {
    func testChatOnlyProviderScopeIsVisibleAndNeverImpliedBeforeConnection() {
        XCTAssertFalse(ProviderExecutionScopePresentation.isChatOnly(session: nil))

        let baseSession = RuntimeSession(
            runtime: .local,
            displayName: "Fixture vLLM",
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
            capabilities: [.streaming, .reasoning]
        )
        XCTAssertTrue(ProviderExecutionScopePresentation.isChatOnly(session: baseSession))

        let codingSession = RuntimeSession(
            runtime: .codex,
            displayName: "Codex app-server",
            accountLabel: nil,
            planLabel: nil,
            auth: baseSession.auth,
            availableLoginMethods: [],
            availableModels: [],
            capabilities: [.streaming, .tools]
        )
        XCTAssertFalse(ProviderExecutionScopePresentation.isChatOnly(session: codingSession))
    }

    func testAdaptiveAgentModelIsNotLabelledChatOnlyWhenSessionOmitsTools() {
        let session = RuntimeSession(
            runtime: .local,
            displayName: "Fixture vLLM",
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
            // Adaptive providers keep tools model/task-scoped rather than
            // claiming them on the provider-wide session.
            capabilities: [.streaming]
        )
        let agentModel = RuntimeModel(
            id: "any-capable-model",
            displayName: "Any capable model",
            description: nil,
            isDefault: true,
            defaultReasoningEffort: nil,
            reasoningEfforts: [],
            executionMode: .agent,
            taskCapabilities: [.streaming, .tools, .terminal]
        )

        XCTAssertFalse(
            ProviderExecutionScopePresentation.isChatOnly(
                session: session,
                selectedModel: agentModel
            )
        )
    }

    func testDurableChatTaskStillShowsChatOnlyWhenCatalogModelIsAgentProjected() {
        let agentModel = RuntimeModel(
            id: "same-model",
            displayName: "Same model",
            description: nil,
            isDefault: true,
            defaultReasoningEffort: nil,
            reasoningEfforts: [],
            executionMode: .agent,
            taskCapabilities: [.streaming, .tools, .terminal]
        )

        XCTAssertTrue(
            ProviderExecutionScopePresentation.isChatOnly(
                session: nil,
                selectedModel: agentModel,
                taskCapabilities: [.streaming]
            )
        )
    }

    func testConversationControlsStayReadableWithoutCrampingCompactWindows() {
        XCTAssertEqual(ConversationContentLayout.maximumComposerWidth, .infinity)
        XCTAssertEqual(OnyxWorkspaceMetrics.maximumConversationTextWidth, 880)
        XCTAssertEqual(OnyxTypography.reading, 13.5)
        XCTAssertGreaterThan(
            OnyxTypography.reading,
            OnyxTypography.navigation,
            "Conversation text should be only slightly larger than the prior tool-use baseline"
        )
        XCTAssertEqual(
            ConversationContentLayout.horizontalInset(availableWidth: 320),
            ConversationContentLayout.minimumHorizontalInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConversationContentLayout.horizontalInset(availableWidth: 600),
            18,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConversationContentLayout.horizontalInset(availableWidth: 1_200),
            ConversationContentLayout.maximumHorizontalInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConversationContentLayout.horizontalInset(availableWidth: .infinity),
            ConversationContentLayout.maximumHorizontalInset,
            accuracy: 0.001
        )
    }

    func testFreshWorkspaceKeepsInspectorOnDemandAndRestoresExplicitChoice() throws {
        let suiteName = "WorkspacePaneLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencePrefix = "Onyx.window.conversation-first"

        let freshModel = OnyxAppModel(
            runtime: nil,
            defaults: defaults,
            preferenceKeyPrefix: preferencePrefix
        )
        XCTAssertTrue(freshModel.isSidebarVisible)
        XCTAssertFalse(freshModel.isInspectorVisible)

        freshModel.isInspectorVisible = true
        let restoredModel = OnyxAppModel(
            runtime: nil,
            defaults: defaults,
            preferenceKeyPrefix: preferencePrefix
        )
        XCTAssertTrue(restoredModel.isInspectorVisible)
    }

    func testCompactBoundaryProtectsConversationFromTwoSidePanes() {
        let expectedBoundary = WorkspacePaneLayout.dividerWidth * 2
            + WorkspacePaneLayout.sidebarMinimumWidth
            + WorkspacePaneLayout.inspectorMinimumWidth
            + WorkspacePaneLayout.minimumConversationWidth

        XCTAssertEqual(WorkspacePaneLayout.compactBreakpoint, expectedBoundary)
        XCTAssertTrue(WorkspacePaneLayout.isCompact(totalWidth: expectedBoundary - 1))
        XCTAssertFalse(WorkspacePaneLayout.isCompact(totalWidth: expectedBoundary))
        XCTAssertFalse(WorkspacePaneLayout.isCompact(totalWidth: .infinity))

        XCTAssertFalse(WorkspacePaneLayout.isSidebarDisplayed(
            sidebarRequested: true,
            inspectorVisible: true,
            isCompact: WorkspacePaneLayout.isCompact(totalWidth: expectedBoundary - 1)
        ))
    }

    func testProductionWindowMinimumFitsTheInspectorAndConversation() {
        XCTAssertEqual(
            WorkspacePaneLayout.minimumWindowWidth,
            WorkspacePaneLayout.minimumConversationWidth
                + WorkspacePaneLayout.dividerWidth
                + WorkspacePaneLayout.inspectorMinimumWidth
        )
        XCTAssertGreaterThanOrEqual(WorkspacePaneLayout.minimumWindowWidth, 930)
    }

    func testPaneSplittersAreWideEnoughToAcquireWithoutPixelHunting() {
        XCTAssertGreaterThanOrEqual(WorkspacePaneLayout.dividerWidth, 10)
        XCTAssertEqual(WorkspacePaneLayout.dividerWidth, OnyxHitTarget.splitter)
    }

    func testCompactSidebarToggleUsesDisplayedVisibilityAndDismissesInspector() {
        let sidebarDisplayed = WorkspacePaneLayout.isSidebarDisplayed(
            sidebarRequested: true,
            inspectorVisible: true,
            isCompact: true
        )
        XCTAssertFalse(sidebarDisplayed)

        let revealTarget = WorkspacePaneLayout.sidebarToggleTarget(
            sidebarDisplayed: sidebarDisplayed,
            inspectorVisible: true,
            isCompact: true
        )
        XCTAssertTrue(revealTarget.sidebarRequested)
        XCTAssertFalse(revealTarget.inspectorVisible)
        XCTAssertTrue(WorkspacePaneLayout.isSidebarDisplayed(
            sidebarRequested: revealTarget.sidebarRequested,
            inspectorVisible: revealTarget.inspectorVisible,
            isCompact: true
        ))

        let hideTarget = WorkspacePaneLayout.sidebarToggleTarget(
            sidebarDisplayed: true,
            inspectorVisible: false,
            isCompact: true
        )
        XCTAssertFalse(hideTarget.sidebarRequested)
        XCTAssertFalse(hideTarget.inspectorVisible)
    }

    func testWideSidebarTogglePreservesVisibleInspector() {
        let target = WorkspacePaneLayout.sidebarToggleTarget(
            sidebarDisplayed: false,
            inspectorVisible: true,
            isCompact: false
        )

        XCTAssertTrue(target.sidebarRequested)
        XCTAssertTrue(target.inspectorVisible)
    }

    func testStoredWidthsClampInvalidAndExtremeValues() {
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredSidebarWidth(.infinity),
            WorkspacePaneLayout.sidebarDefaultWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredSidebarWidth(-1_000),
            WorkspacePaneLayout.sidebarMinimumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredSidebarWidth(1_000),
            WorkspacePaneLayout.sidebarMaximumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredInspectorWidth(.nan),
            WorkspacePaneLayout.inspectorDefaultWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredInspectorWidth(-1_000),
            WorkspacePaneLayout.inspectorMinimumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredInspectorWidth(1_000),
            WorkspacePaneLayout.inspectorMaximumWidth
        )
    }

    func testDisplayedWidthsLeaveConversationRoomAndRespectTheOtherPane() {
        let sidebar = WorkspacePaneLayout.displayedSidebarWidth(
            storedWidth: WorkspacePaneLayout.sidebarMaximumWidth,
            totalWidth: WorkspacePaneLayout.compactBreakpoint,
            inspectorVisible: true,
            inspectorWidth: WorkspacePaneLayout.inspectorDefaultWidth
        )

        let inspector = WorkspacePaneLayout.displayedInspectorWidth(
            storedWidth: WorkspacePaneLayout.inspectorMaximumWidth,
            totalWidth: WorkspacePaneLayout.compactBreakpoint,
            sidebarVisible: true,
            sidebarWidth: sidebar
        )

        let center = WorkspacePaneLayout.compactBreakpoint
            - WorkspacePaneLayout.dividerWidth * 2
            - sidebar
            - inspector
        XCTAssertGreaterThanOrEqual(center, WorkspacePaneLayout.minimumConversationWidth)
    }

    func testInspectorCanUseTheWidthWhenSidebarIsCollapsed() {
        let inspector = WorkspacePaneLayout.displayedInspectorWidth(
            storedWidth: WorkspacePaneLayout.inspectorMaximumWidth,
            totalWidth: 1_200,
            sidebarVisible: false
        )

        XCTAssertEqual(inspector, WorkspacePaneLayout.inspectorMaximumWidth, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            1_200
                - WorkspacePaneLayout.dividerWidth
                - inspector,
            WorkspacePaneLayout.minimumConversationWidth
        )
    }

    func testAccessibilityAdjustmentsStayWithinIntrinsicBounds() {
        XCTAssertEqual(
            WorkspacePaneLayout.adjustedSidebarWidth(
                WorkspacePaneLayout.sidebarMinimumWidth,
                increasing: false
            ),
            WorkspacePaneLayout.sidebarMinimumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.adjustedInspectorWidth(
                WorkspacePaneLayout.inspectorMaximumWidth,
                increasing: true
            ),
            WorkspacePaneLayout.inspectorMaximumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.accessibilityValue(for: 264.4),
            "264 points wide"
        )
    }

    func testPaneWidthPreferenceKeysRemainWindowScoped() {
        let namespace = OnyxPreferenceNamespace(prefix: "Onyx.window.test")
        XCTAssertEqual(
            namespace.key(WorkspacePaneLayout.sidebarWidthPreferenceSuffix),
            "Onyx.window.test.sidebarWidth"
        )
        XCTAssertEqual(
            namespace.key(WorkspacePaneLayout.inspectorWidthPreferenceSuffix),
            "Onyx.window.test.inspectorWidth"
        )
    }
}
