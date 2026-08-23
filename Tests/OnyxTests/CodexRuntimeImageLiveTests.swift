import AppKit
import XCTest
@testable import Onyx

final class CodexRuntimeImageLiveTests: XCTestCase {
    func testGeneratedLocalImageReachesStreamedAssistantResponseWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ONYX_LIVE_CODEX_IMAGE_TEST"] == "1" else {
            throw XCTSkip(
                "Set ONYX_LIVE_CODEX_IMAGE_TEST=1 to send a generated image through the installed Codex runtime"
            )
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxLiveImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let expectedCode = "K7M2"
        let imageURL = fixtureDirectory.appendingPathComponent("vision-code.png")
        try makeCodeImage(expectedCode, at: imageURL)
        let validatedImage = try ComposerImageValidator.localFile(at: imageURL)

        let runtime = try CodexRuntime.makeDevelopmentInstalled()
        do {
            _ = try await runtime.connect()
            let thread = try await runtime.startThread(
                StartThreadRequest(
                    cwd: fixtureDirectory.path,
                    model: nil,
                    ephemeral: true,
                    sandboxMode: .readOnly,
                    approvalPolicy: .never
                )
            )

            let result = try await withThrowingTaskGroup(of: LiveImageResponse.self) { group in
                group.addTask {
                    var streamed = ""
                    var notices: [String] = []
                    for await event in runtime.events {
                        switch event {
                        case let .itemDelta(threadID, _, delta) where threadID == thread.id:
                            streamed += delta
                        case let .itemCompleted(threadID, item)
                            where threadID == thread.id && item.kind == .assistantMessage:
                            if !item.body.isEmpty { streamed = item.body }
                        case let .runtimeNotice(title, detail):
                            notices.append("\(title): \(detail)")
                        case let .turnCompleted(threadID, status) where threadID == thread.id:
                            return LiveImageResponse(text: streamed, status: status, notices: notices)
                        default:
                            continue
                        }
                    }
                    return LiveImageResponse(text: streamed, status: .failed, notices: notices)
                }

                try await runtime.startTurn(
                    StartTurnRequest(
                        threadID: thread.id,
                        inputs: [
                            .text(
                                "Read the large four-character code in the attached image. "
                                    + "Reply with exactly that code and nothing else. Do not use tools."
                            ),
                            validatedImage.input,
                        ],
                        model: nil,
                        cwd: fixtureDirectory.path,
                        sandboxMode: .readOnly,
                        approvalPolicy: .never
                    )
                )

                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw AgentRuntimeError.protocolFailure("Live image streaming test timed out")
                }
                guard let first = try await group.next() else {
                    throw AgentRuntimeError.protocolFailure("Live image stream ended without a result")
                }
                group.cancelAll()
                return first
            }

            await runtime.disconnect()

            let detail = result.notices.isEmpty ? "No runtime notices." : result.notices.joined(separator: " | ")
            XCTAssertEqual(result.status, .idle, detail)
            XCTAssertEqual(
                result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                expectedCode,
                "The streamed answer did not match the code drawn in the local PNG. \(detail)"
            )
        } catch {
            await runtime.disconnect()
            throw error
        }
    }

    private func makeCodeImage(_ code: String, at url: URL) throws {
        let image = NSImage(size: NSSize(width: 640, height: 240))
        image.lockFocus()

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 240).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 144, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let size = code.size(withAttributes: attributes)
        code.draw(
            at: NSPoint(x: (640 - size.width) / 2, y: (240 - size.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureError.couldNotEncodePNG
        }
        try png.write(to: url, options: .atomic)
    }
}

private struct LiveImageResponse: Sendable {
    let text: String
    let status: RuntimeThreadStatus
    let notices: [String]
}

private enum FixtureError: Error {
    case couldNotEncodePNG
}
