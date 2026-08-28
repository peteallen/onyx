import AppKit
import SwiftUI
import XCTest
@testable import Onyx

@MainActor
final class OnyxThemeContrastTests: XCTestCase {
    func testRoutineReadingTextIsReadableWithoutMaximumWhiteOnBlackGlare() throws {
        let appearances: [(name: String, value: NSAppearance)] = try [
            ("light", XCTUnwrap(NSAppearance(named: .aqua))),
            ("dark", XCTUnwrap(NSAppearance(named: .darkAqua))),
        ]
        let readingSurfaces: [(name: String, color: Color)] = [
            ("canvas", OnyxTheme.canvas),
            ("composer", OnyxTheme.composerSurface),
            ("surface", OnyxTheme.surface),
        ]

        for appearance in appearances {
            let foreground = try resolvedRGB(
                OnyxTheme.readingText,
                appearance: appearance.value
            )
            for surface in readingSurfaces {
                let background = try resolvedRGB(surface.color, appearance: appearance.value)
                let ratio = contrastRatio(foreground, background)
                let formattedRatio = String(format: "%.2f", ratio)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    4.5,
                    "Reading text has only \(formattedRatio):1 contrast on \(surface.name) in \(appearance.name) mode"
                )
                if appearance.name == "dark" {
                    XCTAssertLessThan(
                        ratio,
                        15,
                        "Routine reading text should not return to maximum white-on-black glare"
                    )
                }
            }
        }
    }

    func testSwiftUIAndAppKitSemanticColorsResolveIdentically() throws {
        let appearances = try [
            XCTUnwrap(NSAppearance(named: .aqua)),
            XCTUnwrap(NSAppearance(named: .darkAqua)),
        ]
        let colors: [(Color, (NSAppearance?) -> NSColor)] = [
            (OnyxTheme.readingText, OnyxTheme.readingNSColor),
            (OnyxTheme.iris, OnyxTheme.irisNSColor),
            (OnyxTheme.electric, OnyxTheme.electricNSColor),
            (OnyxTheme.success, OnyxTheme.successNSColor),
            (OnyxTheme.warning, OnyxTheme.warningNSColor),
            (OnyxTheme.destructive, OnyxTheme.destructiveNSColor),
        ]

        for appearance in appearances {
            for color in colors {
                let swiftUI = try resolvedRGB(color.0, appearance: appearance)
                let appKitColor = try XCTUnwrap(color.1(appearance).usingColorSpace(.sRGB))
                XCTAssertEqual(swiftUI.red, appKitColor.redComponent, accuracy: 0.001)
                XCTAssertEqual(swiftUI.green, appKitColor.greenComponent, accuracy: 0.001)
                XCTAssertEqual(swiftUI.blue, appKitColor.blueComponent, accuracy: 0.001)
            }
        }
    }

    func testTerminalTextRolesRemainReadableOnTheBlackRail() throws {
        let appearances: [(name: String, value: NSAppearance)] = try [
            ("light", XCTUnwrap(NSAppearance(named: .aqua))),
            ("dark", XCTUnwrap(NSAppearance(named: .darkAqua))),
        ]
        let roles: [(name: String, color: Color)] = [
            ("terminal text", OnyxTheme.terminalText),
            ("terminal muted text", OnyxTheme.terminalMutedText),
        ]

        for appearance in appearances {
            let background = try resolvedRGB(OnyxTheme.rail, appearance: appearance.value)
            for role in roles {
                let foreground = try resolvedRGB(role.color, appearance: appearance.value)
                let ratio = contrastRatio(foreground, background)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    4.5,
                    "\(role.name) has only \(String(format: "%.2f", ratio)):1 contrast in \(appearance.name) mode"
                )
            }
        }
    }

    func testSemanticStatusColorsMeetSmallTextContrastInBothAppearances() throws {
        let statusColors: [(name: String, color: Color)] = [
            ("iris", OnyxTheme.iris),
            ("electric", OnyxTheme.electric),
            ("success", OnyxTheme.success),
            ("warning", OnyxTheme.warning),
            ("destructive", OnyxTheme.destructive),
        ]
        let backgrounds: [(name: String, color: Color)] = [
            ("sidebar", OnyxTheme.sidebar),
            ("inspector", OnyxTheme.inspector),
            ("surface", OnyxTheme.surface),
            ("raised surface", OnyxTheme.raisedSurface),
        ]
        let appearances: [(name: String, value: NSAppearance, selectionOverlay: RGB)] = try [
            ("light", XCTUnwrap(NSAppearance(named: .aqua)), .black),
            ("dark", XCTUnwrap(NSAppearance(named: .darkAqua)), .white),
        ]

        for appearance in appearances {
            var resolvedBackgrounds = try backgrounds.map { background in
                (
                    name: background.name,
                    color: try resolvedRGB(background.color, appearance: appearance.value)
                )
            }
            let sidebar = try XCTUnwrap(resolvedBackgrounds.first { $0.name == "sidebar" }?.color)
            resolvedBackgrounds.append(
                (
                    name: "selected sidebar row",
                    color: sidebar.blended(with: appearance.selectionOverlay, opacity: 0.055)
                )
            )

            for statusColor in statusColors {
                let foreground = try resolvedRGB(statusColor.color, appearance: appearance.value)
                for background in resolvedBackgrounds {
                    let ratio = contrastRatio(foreground, background.color)
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        4.5,
                        "\(statusColor.name) has only \(String(format: "%.2f", ratio)):1 contrast on \(background.name) in \(appearance.name) mode"
                    )
                }
            }
        }
    }

    func testInactiveControlTextMeetsSmallTextContrastInBothAppearances() throws {
        let appearances: [(name: String, value: NSAppearance)] = try [
            ("light", XCTUnwrap(NSAppearance(named: .aqua))),
            ("dark", XCTUnwrap(NSAppearance(named: .darkAqua))),
        ]

        for appearance in appearances {
            let foreground = try resolvedRGB(
                OnyxTheme.inactiveControlText,
                appearance: appearance.value
            )
            let background = try resolvedRGB(
                OnyxTheme.inspector,
                appearance: appearance.value
            )
            let ratio = contrastRatio(foreground, background)
            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "Inactive control text has only \(String(format: "%.2f", ratio)):1 contrast in \(appearance.name) mode"
            )
        }
    }

    private func resolvedRGB(_ color: Color, appearance: NSAppearance) throws -> RGB {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let srgb = try XCTUnwrap(resolved)
        return RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    private func contrastRatio(_ lhs: RGB, _ rhs: RGB) -> Double {
        let brighter = max(lhs.relativeLuminance, rhs.relativeLuminance)
        let darker = min(lhs.relativeLuminance, rhs.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }
}

private struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    static let black = RGB(red: 0, green: 0, blue: 0)
    static let white = RGB(red: 1, green: 1, blue: 1)

    var relativeLuminance: Double {
        (0.2126 * linearized(red)) +
            (0.7152 * linearized(green)) +
            (0.0722 * linearized(blue))
    }

    func blended(with overlay: RGB, opacity: Double) -> RGB {
        RGB(
            red: (red * (1 - opacity)) + (overlay.red * opacity),
            green: (green * (1 - opacity)) + (overlay.green * opacity),
            blue: (blue * (1 - opacity)) + (overlay.blue * opacity)
        )
    }

    private func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
