import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Onyx

final class TerminalEscapeFilterTests: XCTestCase {
    func testRemovesColorAndWindowTitleSequencesWithoutDroppingText() {
        let input = Data("\u{001B}[31mred\u{001B}[0m plain\u{001B}]0;secret title\u{0007}\n".utf8)

        XCTAssertEqual(TerminalEscapeFilter.visibleText(from: input), "red plain\n")
    }

    func testNormalizesCarriageReturnsAndBackspacesForReadableHistory() {
        let input = Data([0x61, 0x62, 0x08, 0x63, 0x0D, 0x64, 0x0A])

        XCTAssertEqual(TerminalEscapeFilter.visibleText(from: input), "ac\nd\n")
    }

    func testStreamingFilterHandlesSplitEscapeAndCRLFSequences() {
        var filter = TerminalEscapeFilter()

        XCTAssertEqual(filter.consume(Data("before\u{001B}[3".utf8)), "before")
        XCTAssertEqual(filter.consume(Data("1mred\u{001B}[0m\r".utf8)), "red\n")
        XCTAssertEqual(filter.consume(Data("\nafter".utf8)), "after")
    }

    func testStreamingFilterDoesNotCorruptSplitUnicodeScalars() {
        var filter = TerminalEscapeFilter()
        let bytes = Array("before 🪨 after".utf8)
        let split = bytes.firstIndex(of: 0xA8)!

        XCTAssertEqual(filter.consume(Data(bytes[..<split])), "before ")
        XCTAssertEqual(filter.consume(Data(bytes[split...])), "🪨 after")
    }
}

@MainActor
final class TerminalSessionIntegrationTests: XCTestCase {
    func testPersistentProjectShellAcceptsACommandThroughPTY() async {
        let terminal = TerminalSessionModel()
        let marker = "onyx-pty-\(UUID().uuidString)"

        terminal.start(in: "/tmp")
        await waitUntil("The PTY shell did not start") { terminal.isRunning }
        XCTAssertEqual(terminal.workingDirectory, "/tmp")

        terminal.input = "printf '\(marker)\\n'"
        terminal.sendInputLine()
        await waitUntil("The PTY command did not produce output", timeout: .seconds(3)) {
            terminal.output.components(separatedBy: marker).count - 1 >= 2
        }

        terminal.sendEndOfFile()
        await waitUntil("The PTY shell did not exit", timeout: .seconds(3)) {
            !terminal.isRunning
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
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), failureMessage)
    }
}

@MainActor
final class TerminalVisualSnapshotTests: XCTestCase {
    func testRendersInteractiveTerminalDrawerWhenEnabled() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ONYX_TERMINAL_SNAPSHOT_PATH"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set ONYX_TERMINAL_SNAPSHOT_PATH to render the project terminal")
        }

        let suiteName = "TerminalVisualSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = OnyxAppModel(runtime: nil, defaults: defaults)
        model.draftWorkspacePath = "/tmp/onyx"
        let terminal = TerminalSessionModel()
        let resultMarker = "ONYX_SNAPSHOT_RESULT"
        terminal.start(in: model.draftWorkspacePath)
        terminal.input = "printf 'Onyx project shell\\nbranch: main\\n5 tests passed: \(resultMarker)\\n'"
        terminal.sendInputLine()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while terminal.output.components(separatedBy: resultMarker).count - 1 < 2,
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(
            terminal.output.components(separatedBy: resultMarker).count - 1,
            2
        )

        let size = NSSize(width: 1_000, height: 270)
        let hostingView = NSHostingView(
            rootView: TerminalDrawerView(
                model: model,
                session: terminal,
                height: .constant(size.height)
            )
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(data.count, 5_000)

        terminal.sendEndOfFile()
    }
}
