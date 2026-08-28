import AppKit
import XCTest
@testable import Onyx

@MainActor
final class ThinkingIndicatorTests: XCTestCase {
    func testDarkThinkingIndicatorUsesReadableTextAndVisibleAccent() throws {
        let view = TranscriptPendingResponseView(frame: NSRect(x: 0, y: 0, width: 640, height: 34))
        view.appearance = NSAppearance(named: .darkAqua)
        view.configure(label: "Thinking…")
        view.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSTextField }.first
        )
        let colors = TranscriptPendingResponsePresentation.colors(for: NSAppearance(named: .darkAqua))

        XCTAssertEqual(label.textColor, colors.text)
        XCTAssertEqual(colors.tint, OnyxTheme.electricNSColor(for: NSAppearance(named: .darkAqua)))
        XCTAssertLessThan(colors.text.redComponent, 0.90)
        XCTAssertLessThan(colors.text.greenComponent, 0.90)
        XCTAssertLessThan(colors.text.blueComponent, 0.90)
        XCTAssertEqual(
            view.layer?.backgroundColor,
            colors.tint.withAlphaComponent(0.14).cgColor,
            "Thinking feedback needs a visible boundary on the near-black canvas"
        )
        XCTAssertEqual(view.layer?.borderWidth, 1)
        XCTAssertEqual(view.layer?.borderColor, colors.tint.withAlphaComponent(0.34).cgColor)
    }

    func testLightThinkingIndicatorKeepsAHighContrastTreatment() throws {
        let view = TranscriptPendingResponseView(frame: NSRect(x: 0, y: 0, width: 640, height: 34))
        view.appearance = NSAppearance(named: .aqua)
        view.configure(label: "Thinking…")
        view.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSTextField }.first
        )
        let colors = TranscriptPendingResponsePresentation.colors(for: NSAppearance(named: .aqua))

        XCTAssertEqual(label.textColor, colors.text)
        XCTAssertEqual(colors.tint, OnyxTheme.electricNSColor(for: NSAppearance(named: .aqua)))
        XCTAssertLessThan(colors.text.redComponent, 0.25)
        XCTAssertLessThan(colors.text.greenComponent, 0.25)
        XCTAssertLessThan(colors.text.blueComponent, 0.25)
        XCTAssertEqual(
            view.layer?.backgroundColor,
            colors.tint.withAlphaComponent(0.09).cgColor
        )
        XCTAssertEqual(view.layer?.borderColor, colors.tint.withAlphaComponent(0.25).cgColor)
    }
}
