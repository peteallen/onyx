import AppKit
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class OnyxVisualSnapshotTests: XCTestCase {
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

        let size = NSSize(width: 1_380, height: 860)
        let hostingView = NSHostingView(
            rootView: OnyxWorkspaceView(model: model)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
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
}
