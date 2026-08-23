import AppKit
import SwiftUI

enum OnyxTheme {
    // A calm, native-feeling dark hierarchy: the canvas is nearly black, each
    // adjacent surface is only just lighter, and color is saved for a focused
    // action or a small state indicator.  Keep the public names stable; most
    // of the app composes its visual language from these tokens.
    static let rail = adaptiveColor(
        dark: NSColor(srgbRed: 0.035, green: 0.036, blue: 0.039, alpha: 1),
        light: NSColor(srgbRed: 0.930, green: 0.931, blue: 0.934, alpha: 1)
    )
    static let railRaised = adaptiveColor(
        dark: NSColor(srgbRed: 0.105, green: 0.108, blue: 0.115, alpha: 1),
        light: NSColor(srgbRed: 0.855, green: 0.858, blue: 0.865, alpha: 1)
    )
    // Color is an interaction signal, not a structural color.  These tokens
    // also carry small status labels, so each appearance has its own restrained
    // palette with at least 4.5:1 contrast on the sidebar and inspector.
    static let iris = adaptiveColor(
        dark: NSColor(srgbRed: 0.34, green: 0.57, blue: 0.90, alpha: 1),
        light: NSColor(srgbRed: 0.20, green: 0.36, blue: 0.62, alpha: 1)
    )
    static let electric = adaptiveColor(
        dark: NSColor(srgbRed: 0.41, green: 0.64, blue: 0.94, alpha: 1),
        light: NSColor(srgbRed: 0.14, green: 0.39, blue: 0.54, alpha: 1)
    )
    static let success = adaptiveColor(
        dark: NSColor(srgbRed: 0.37, green: 0.66, blue: 0.56, alpha: 1),
        light: NSColor(srgbRed: 0.17, green: 0.40, blue: 0.31, alpha: 1)
    )
    static let warning = adaptiveColor(
        dark: NSColor(srgbRed: 0.82, green: 0.61, blue: 0.31, alpha: 1),
        light: NSColor(srgbRed: 0.44, green: 0.32, blue: 0.08, alpha: 1)
    )
    static let destructive = adaptiveColor(
        dark: NSColor(srgbRed: 0.84, green: 0.39, blue: 0.41, alpha: 1),
        light: NSColor(srgbRed: 0.62, green: 0.20, blue: 0.24, alpha: 1)
    )

    static let canvas = adaptiveColor(
        dark: NSColor(srgbRed: 0.043, green: 0.044, blue: 0.047, alpha: 1),
        light: NSColor(srgbRed: 0.966, green: 0.967, blue: 0.970, alpha: 1)
    )

    static let sidebar = adaptiveColor(
        dark: NSColor(srgbRed: 0.052, green: 0.053, blue: 0.057, alpha: 1),
        light: NSColor(srgbRed: 0.940, green: 0.941, blue: 0.944, alpha: 1)
    )

    static let surface = adaptiveColor(
        dark: NSColor(srgbRed: 0.071, green: 0.073, blue: 0.079, alpha: 1),
        light: NSColor(srgbRed: 0.984, green: 0.985, blue: 0.988, alpha: 1)
    )

    static let raisedSurface = adaptiveColor(
        dark: NSColor(srgbRed: 0.095, green: 0.097, blue: 0.104, alpha: 1),
        light: NSColor.white
    )

    /// The composer is the primary action surface. It needs a little more
    /// separation than transcript activity without turning into a bright card.
    static let composerSurface = adaptiveColor(
        dark: NSColor(srgbRed: 0.075, green: 0.076, blue: 0.081, alpha: 1),
        light: NSColor.white
    )

    static let chrome = adaptiveColor(
        dark: NSColor(srgbRed: 0.043, green: 0.044, blue: 0.047, alpha: 1),
        light: NSColor(srgbRed: 0.971, green: 0.972, blue: 0.975, alpha: 1)
    )
    static let inspector = adaptiveColor(
        dark: NSColor(srgbRed: 0.076, green: 0.077, blue: 0.082, alpha: 1),
        light: NSColor(srgbRed: 0.984, green: 0.985, blue: 0.988, alpha: 1)
    )
    static let border = Color.primary.opacity(0.065)
    static let divider = Color.primary.opacity(0.055)
    static let quietText = Color.secondary.opacity(0.90)
    static let inactiveControlText = adaptiveColor(
        dark: NSColor(srgbRed: 0.640, green: 0.640, blue: 0.660, alpha: 1),
        light: NSColor(srgbRed: 0.380, green: 0.380, blue: 0.400, alpha: 1)
    )
    static let hairline = 1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0)
    static let accentGradient = LinearGradient(
        colors: [iris, electric],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func adaptiveColor(dark: NSColor, light: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        )
    }
}

struct OnyxMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(OnyxTheme.accentGradient)
                .rotationEffect(.degrees(45))
                .frame(width: size * 0.73, height: size * 0.73)
                .shadow(color: OnyxTheme.iris.opacity(0.32), radius: size * 0.22, y: size * 0.08)

            RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                .stroke(Color.white.opacity(0.86), lineWidth: max(1, size * 0.055))
                .rotationEffect(.degrees(45))
                .frame(width: size * 0.32, height: size * 0.32)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Onyx")
    }
}

struct OnyxPanelModifier: ViewModifier {
    var radius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(OnyxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
            }
    }
}

extension View {
    func onyxPanel(radius: CGFloat = 14) -> some View {
        modifier(OnyxPanelModifier(radius: radius))
    }
}
