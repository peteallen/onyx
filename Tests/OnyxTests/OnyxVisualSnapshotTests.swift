import AppKit
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class OnyxVisualSnapshotTests: XCTestCase {
    func testRendersConversationAndInlineWaitingStateWhenEnabled() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ONYX_TRANSCRIPT_SNAPSHOT_PATH"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set ONYX_TRANSCRIPT_SNAPSHOT_PATH to render the conversation transcript")
        }

        let items = [
            TimelineItem(
                id: "visual-user-one",
                kind: .userMessage,
                title: nil,
                body: "hi",
                status: .completed,
                timestamp: .now,
                detail: nil
            ),
            TimelineItem(
                id: "visual-assistant",
                kind: .assistantMessage,
                title: nil,
                body: "Hi Pete! What are we working on?",
                status: .completed,
                timestamp: .now,
                detail: "final_answer"
            ),
            TimelineItem(
                id: "visual-user-two",
                kind: .userMessage,
                title: nil,
                body: "Can you review the current changes?",
                status: .completed,
                timestamp: .now,
                detail: nil
            ),
            TimelineItem(
                id: "visual-tool",
                kind: .tool,
                title: "Inspect changes",
                body: "Read the working tree and compared the modified files.",
                status: .running,
                timestamp: .now,
                detail: "4 files"
            ),
        ]

        let environment = ProcessInfo.processInfo.environment
        let size = NSSize(
            width: snapshotDimension(environment["ONYX_TRANSCRIPT_SNAPSHOT_WIDTH"], fallback: 840),
            height: snapshotDimension(environment["ONYX_TRANSCRIPT_SNAPSHOT_HEIGHT"], fallback: 620)
        )
        let appearance = snapshotAppearance(from: environment)
        let hostingView = NSHostingView(
            rootView: NativeTranscriptView(
                items: items,
                isAwaitingResponse: true,
                workingLabel: "Working on a response…"
            )
            .frame(width: size.width, height: size.height)
            .background(OnyxTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
        )
        hostingView.appearance = NSAppearance(named: appearance.nsAppearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not allocate the transcript snapshot bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode the transcript snapshot as PNG")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(data.count, 10_000)
    }

    func testRendersSignedOutWorkspaceWhenEnabled() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ONYX_SNAPSHOT_PATH"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set ONYX_SNAPSHOT_PATH to render the signed-out workspace")
        }

        let model = OnyxAppModel(runtime: nil)
        let browserLogin = RuntimeLoginMethod(
            id: "codex.chatgpt.browser",
            displayName: "Continue with ChatGPT",
            detail: "Sign in securely in your browser",
            ceremony: .browser
        )
        let deviceLogin = RuntimeLoginMethod(
            id: "codex.chatgpt.device-code",
            displayName: "Use a device code",
            detail: "Enter a one-time code at OpenAI",
            ceremony: .deviceCode
        )
        model.session = RuntimeSession(
            runtime: .codex,
            displayName: "Codex app-server",
            accountLabel: nil,
            planLabel: nil,
            auth: .signedOut,
            availableLoginMethods: [browserLogin, deviceLogin],
            availableModels: [
                RuntimeModel(
                    id: "gpt-5.6-sol",
                    displayName: "GPT-5.6-Sol",
                    description: "Latest frontier agentic coding model.",
                    isDefault: true,
                    defaultReasoningEffort: "low",
                    reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]
                ),
            ],
            capabilities: [.streaming, .reasoning, .approvals, .tools]
        )
        model.authState = .signedOut
        model.connectionState = .connected("Codex")
        model.selectedModelID = "gpt-5.6-sol"
        model.selectedReasoningEffort = "low"
        model.isInspectorVisible = true
        model.isBottomPanelVisible = false

        let environment = ProcessInfo.processInfo.environment
        let size = NSSize(
            width: snapshotDimension(environment["ONYX_SNAPSHOT_WIDTH"], fallback: 1_380),
            height: snapshotDimension(environment["ONYX_SNAPSHOT_HEIGHT"], fallback: 860)
        )
        let appearance = snapshotAppearance(from: environment)
        let hostingView = NSHostingView(
            rootView: OnyxWorkspaceView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, appearance.colorScheme)
        )
        hostingView.appearance = NSAppearance(named: appearance.nsAppearance)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not allocate the visual snapshot bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode the visual snapshot as PNG")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(data.count, 10_000)
    }

    private func snapshotDimension(_ rawValue: String?, fallback: CGFloat) -> CGFloat {
        guard let rawValue,
              let value = Double(rawValue),
              value.isFinite,
              value > 0 else { return fallback }
        return CGFloat(value)
    }

    private func snapshotAppearance(
        from environment: [String: String]
    ) -> (colorScheme: ColorScheme, nsAppearance: NSAppearance.Name) {
        switch environment["ONYX_SNAPSHOT_APPEARANCE"]?.lowercased() {
        case "light": (.light, .aqua)
        default: (.dark, .darkAqua)
        }
    }
}
