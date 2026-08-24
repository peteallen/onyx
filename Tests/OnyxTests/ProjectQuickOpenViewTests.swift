import AppKit
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class ProjectQuickOpenViewTests: XCTestCase {
    func testHostedPalettePaintsBeforeFourThousandFileIndexAndSupportsKeyboardNavigation() async throws {
        let files = (0..<4_000).map { index in
            ProjectSourceFile(
                path: "/fixture/Sources/File\(String(format: "%04d", index)).swift",
                relativePath: "Sources/File\(String(format: "%04d", index)).swift",
                byteCount: 1
            )
        }
        let indexGate = AsyncStream.makeStream(of: Void.self)
        defer { indexGate.continuation.finish() }
        let reader = GatedQuickOpenReader(
            release: indexGate.stream,
            snapshot: ProjectSourceIndexSnapshot(
                rootPath: "/fixture",
                files: files,
                wasTruncated: false
            )
        )
        let navigator = ProjectSourceNavigatorModel(reader: reader, searchResultLimit: 100)
        var openedFile: ProjectSourceFile?
        let size = NSSize(width: 820, height: 600)
        let hostingView = NSHostingView(
            rootView: ProjectQuickOpenView(
                navigator: navigator,
                projectPath: "/fixture",
                focusRequest: 1,
                chooseProject: {},
                dismiss: {},
                open: { openedFile = $0 }
            )
            .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = makeWindow(hosting: hostingView)
        defer { close(window: window) }

        hostingView.layoutSubtreeIfNeeded()
        await waitUntil("Quick Open did not mount before indexing completed") {
            hostingView.layoutSubtreeIfNeeded()
            return hostingView.firstDescendantTextField(withPlaceholder: "Quick Open") != nil
        }
        let searchField = try XCTUnwrap(
            hostingView.firstDescendantTextField(withPlaceholder: "Quick Open")
        )
        await waitUntil("The suspended project index did not start") {
            navigator.indexState == .loading
        }
        XCTAssertEqual(
            navigator.indexState,
            .loading,
            "Quick Open must be usable while the project index is still running."
        )
        // XCTest's process cannot make this borderless host key. Deliberately
        // install the field editor so the remainder exercises the same native
        // arrow/Return responder path as the running workspace window.
        XCTAssertTrue(window.makeFirstResponder(searchField))
        XCTAssertTrue(window.firstResponder is NSTextView)

        indexGate.continuation.yield()
        indexGate.continuation.finish()
        await waitUntil("The large project index did not load") {
            if case let .loaded(snapshot) = navigator.indexState {
                return snapshot.files.count == 4_000
            }
            return false
        }

        let clock = ContinuousClock()
        let typingStartedAt = clock.now
        navigator.query = "file"
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertLessThan(
            typingStartedAt.duration(to: clock.now),
            .milliseconds(20),
            "Typing must only schedule search work, not rank 4,000 paths on the main actor."
        )
        await waitUntil("The bounded search results did not publish") {
            !navigator.isSearching && navigator.searchResults.count == 40
        }

        try sendKey(code: 125, characters: "\u{F701}", to: window)
        try sendKey(code: 36, characters: "\r", to: window)
        await waitUntil("Arrow navigation and Return did not open the second result") {
            openedFile?.relativePath == "Sources/File0001.swift"
        }
    }

    func testHostedEscapeDismissesNoProjectPaletteWithoutOpeningAFile() async throws {
        let navigator = ProjectSourceNavigatorModel(reader: EmptyQuickOpenReader())
        navigator.query = "existing inspector search"
        var dismissCount = 0
        var openedFile: ProjectSourceFile?
        let size = NSSize(width: 720, height: 520)
        let hostingView = NSHostingView(
            rootView: ProjectQuickOpenView(
                navigator: navigator,
                projectPath: nil,
                focusRequest: 1,
                chooseProject: {},
                dismiss: { dismissCount += 1 },
                open: { openedFile = $0 }
            )
            .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = makeWindow(hosting: hostingView)
        defer { close(window: window) }

        hostingView.layoutSubtreeIfNeeded()
        pumpMainRunLoop(for: 0.02)
        let searchField = try XCTUnwrap(
            hostingView.firstDescendantTextField(withPlaceholder: "Quick Open")
        )
        // See the large-index test: focus is installed explicitly because the
        // xctest host cannot own macOS key-window status.
        XCTAssertTrue(window.makeFirstResponder(searchField))
        XCTAssertTrue(window.firstResponder is NSTextView)
        XCTAssertEqual(navigator.indexState, .noProject)

        try sendKey(code: 53, characters: "\u{1B}", to: window)
        await waitUntil("Escape did not dismiss Quick Open") { dismissCount == 1 }
        XCTAssertNil(openedFile)
        XCTAssertEqual(navigator.previewState, .none)
        XCTAssertEqual(
            navigator.query,
            "existing inspector search",
            "Cancelling the palette must preserve the Files inspector search."
        )
    }

    func testOpeningSelectionRevealsFilesInspectorAndPublishesSharedPreview() async throws {
        let file = ProjectSourceFile(
            path: "/fixture/Sources/App.swift",
            relativePath: "Sources/App.swift",
            byteCount: 12
        )
        let preview = ProjectSourcePreview(
            file: file,
            lines: [ProjectSourcePreviewLine(number: 1, text: "struct App {}")],
            wasTruncated: false
        )
        let navigator = ProjectSourceNavigatorModel(
            reader: QuickOpenPreviewReader(file: file, preview: preview)
        )
        await navigator.loadRoot(path: "/fixture")
        let suiteName = "ProjectQuickOpenViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = OnyxAppModel(runtime: nil, defaults: defaults)
        model.isInspectorVisible = false
        model.inspectorTab = .review

        let previewTask = ProjectQuickOpenWorkspaceRouting.open(
            file,
            model: model,
            navigator: navigator
        )
        await previewTask.value

        XCTAssertTrue(model.isInspectorVisible)
        XCTAssertEqual(model.inspectorTab, .files)
        XCTAssertEqual(navigator.previewState, .loaded(preview))
    }

    private func makeWindow<Content: View>(hosting: NSHostingView<Content>) -> NSWindow {
        // AppKit does not allow a plain borderless NSWindow to become key, so
        // SwiftUI cannot install its field editor and key events never reach
        // the focused TextField. The production palette lives in a normal key
        // workspace window; mirror that responder behavior in this lean host.
        let window = QuickOpenTestWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        return window
    }

    private func close(window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func pumpMainRunLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func sendKey(code: UInt16, characters: String, to window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
        window.sendEvent(event)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), failureMessage)
    }
}

private final class QuickOpenTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension NSView {
    func firstDescendantTextField(withPlaceholder placeholder: String) -> NSTextField? {
        if let textField = self as? NSTextField,
           (textField.placeholderString == placeholder || textField.stringValue == placeholder) {
            return textField
        }
        for subview in subviews {
            if let match = subview.firstDescendantTextField(withPlaceholder: placeholder) {
                return match
            }
        }
        return nil
    }
}

private actor GatedQuickOpenReader: ProjectSourceReading {
    let release: AsyncStream<Void>
    let snapshot: ProjectSourceIndexSnapshot

    init(release: AsyncStream<Void>, snapshot: ProjectSourceIndexSnapshot) {
        self.release = release
        self.snapshot = snapshot
    }

    func indexFiles(atRoot _: String) async throws -> ProjectSourceIndexSnapshot {
        for await _ in release { break }
        try Task.checkCancellation()
        return snapshot
    }

    func previewFile(at _: String, insideRoot _: String) async throws -> ProjectSourcePreview {
        throw ProjectSourceError.unavailable("Preview is not used by the palette fixture.")
    }
}

private struct EmptyQuickOpenReader: ProjectSourceReading {
    func indexFiles(atRoot rootPath: String) async throws -> ProjectSourceIndexSnapshot {
        ProjectSourceIndexSnapshot(rootPath: rootPath, files: [], wasTruncated: false)
    }

    func previewFile(at _: String, insideRoot _: String) async throws -> ProjectSourcePreview {
        throw ProjectSourceError.unavailable("No project is selected.")
    }
}

private struct QuickOpenPreviewReader: ProjectSourceReading {
    let file: ProjectSourceFile
    let preview: ProjectSourcePreview

    func indexFiles(atRoot rootPath: String) async throws -> ProjectSourceIndexSnapshot {
        ProjectSourceIndexSnapshot(rootPath: rootPath, files: [file], wasTruncated: false)
    }

    func previewFile(at _: String, insideRoot _: String) async throws -> ProjectSourcePreview {
        preview
    }
}
