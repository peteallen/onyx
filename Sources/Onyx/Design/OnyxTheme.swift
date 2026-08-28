import AppKit
import SwiftUI

enum OnyxTheme {
    // Keep the canvas unapologetically black, then take the glare out of the
    // things people stare at. Color describes a vibe/state rather than a pane:
    // violet = intent, cyan = motion, mint = reassurance, amber = attention,
    // coral = failure. Keep the public names stable; most of the app composes
    // its visual language from these tokens.
    static let rail = adaptiveColor(
        dark: NSColor(srgbRed: 0.035, green: 0.036, blue: 0.039, alpha: 1),
        light: NSColor(srgbRed: 0.930, green: 0.931, blue: 0.934, alpha: 1)
    )
    static let railRaised = adaptiveColor(
        dark: NSColor(srgbRed: 0.105, green: 0.108, blue: 0.115, alpha: 1),
        light: NSColor(srgbRed: 0.855, green: 0.858, blue: 0.865, alpha: 1)
    )
    // These tokens also carry small status labels, so each appearance has its
    // own vivid-but-readable palette with at least 4.5:1 contrast on the
    // sidebar and inspector.
    static let iris = adaptiveColor(
        dark: NSColor(srgbRed: 0.72, green: 0.58, blue: 1.00, alpha: 1),
        light: NSColor(srgbRed: 0.34, green: 0.20, blue: 0.62, alpha: 1)
    )
    static let electric = adaptiveColor(
        dark: NSColor(srgbRed: 0.31, green: 0.82, blue: 0.96, alpha: 1),
        light: NSColor(srgbRed: 0.02, green: 0.39, blue: 0.52, alpha: 1)
    )
    static let success = adaptiveColor(
        dark: NSColor(srgbRed: 0.43, green: 0.86, blue: 0.67, alpha: 1),
        light: NSColor(srgbRed: 0.09, green: 0.43, blue: 0.29, alpha: 1)
    )
    static let warning = adaptiveColor(
        dark: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.34, alpha: 1),
        light: NSColor(srgbRed: 0.48, green: 0.31, blue: 0.03, alpha: 1)
    )
    static let destructive = adaptiveColor(
        dark: NSColor(srgbRed: 1.00, green: 0.48, blue: 0.50, alpha: 1),
        light: NSColor(srgbRed: 0.65, green: 0.16, blue: 0.20, alpha: 1)
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
    /// Softer than AppKit/SwiftUI's pure label white, but still comfortably
    /// above AA contrast on the reading canvas. This is the color for prose,
    /// composer input, and other content someone reads for more than a glance.
    static let readingText = adaptiveColor(
        dark: NSColor(srgbRed: 0.84, green: 0.82, blue: 0.78, alpha: 1),
        light: NSColor(srgbRed: 0.16, green: 0.15, blue: 0.18, alpha: 1)
    )
    static let strongText = adaptiveColor(
        dark: NSColor(srgbRed: 0.93, green: 0.92, blue: 0.95, alpha: 1),
        light: NSColor(srgbRed: 0.10, green: 0.09, blue: 0.12, alpha: 1)
    )
    static let quietText = Color.secondary.opacity(0.90)
    static let terminalText = adaptiveColor(
        dark: NSColor(srgbRed: 0.72, green: 0.76, blue: 0.80, alpha: 1),
        light: NSColor(srgbRed: 0.18, green: 0.22, blue: 0.26, alpha: 1)
    )
    static let terminalMutedText = adaptiveColor(
        dark: NSColor(srgbRed: 0.48, green: 0.52, blue: 0.57, alpha: 1),
        light: NSColor(srgbRed: 0.37, green: 0.41, blue: 0.45, alpha: 1)
    )
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

    /// AppKit counterparts for native transcript/composer surfaces. Keeping
    /// these sourced from the same values prevents SwiftUI and recycled native
    /// rows from drifting into different visual languages.
    static func readingNSColor(for appearance: NSAppearance?) -> NSColor {
        adaptiveNSColor(
            dark: NSColor(srgbRed: 0.84, green: 0.82, blue: 0.78, alpha: 1),
            light: NSColor(srgbRed: 0.16, green: 0.15, blue: 0.18, alpha: 1),
            appearance: appearance
        )
    }

    static func strongNSColor(for appearance: NSAppearance?) -> NSColor {
        adaptiveNSColor(
            dark: NSColor(srgbRed: 0.93, green: 0.92, blue: 0.95, alpha: 1),
            light: NSColor(srgbRed: 0.10, green: 0.09, blue: 0.12, alpha: 1),
            appearance: appearance
        )
    }

    static func irisNSColor(for appearance: NSAppearance?) -> NSColor {
        adaptiveNSColor(
            dark: NSColor(srgbRed: 0.72, green: 0.58, blue: 1.00, alpha: 1),
            light: NSColor(srgbRed: 0.34, green: 0.20, blue: 0.62, alpha: 1),
            appearance: appearance
        )
    }

    static func electricNSColor(for appearance: NSAppearance?) -> NSColor {
        adaptiveNSColor(
            dark: NSColor(srgbRed: 0.31, green: 0.82, blue: 0.96, alpha: 1),
            light: NSColor(srgbRed: 0.02, green: 0.39, blue: 0.52, alpha: 1),
            appearance: appearance
        )
    }

    static func successNSColor(for appearance: NSAppearance?) -> NSColor {
        adaptiveNSColor(
            dark: NSColor(srgbRed: 0.43, green: 0.86, blue: 0.67, alpha: 1),
            light: NSColor(srgbRed: 0.09, green: 0.43, blue: 0.29, alpha: 1),
            appearance: appearance
        )
    }

    static func warningNSColor(for appearance: NSAppearance?) -> NSColor {
        adaptiveNSColor(
            dark: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.34, alpha: 1),
            light: NSColor(srgbRed: 0.48, green: 0.31, blue: 0.03, alpha: 1),
            appearance: appearance
        )
    }

    static func destructiveNSColor(for appearance: NSAppearance?) -> NSColor {
        adaptiveNSColor(
            dark: NSColor(srgbRed: 1.00, green: 0.48, blue: 0.50, alpha: 1),
            light: NSColor(srgbRed: 0.65, green: 0.16, blue: 0.20, alpha: 1),
            appearance: appearance
        )
    }

    private static func adaptiveNSColor(
        dark: NSColor,
        light: NSColor,
        appearance: NSAppearance?
    ) -> NSColor {
        // Swift imports AppKit's `currentDrawingAppearance` property under
        // the API-renamed `currentDrawing()` spelling in this SDK.
        let resolvedAppearance: NSAppearance = appearance ?? NSAppearance.currentDrawing()
        return resolvedAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? dark
            : light
    }
}

/// Shared interaction geometry for Onyx's dense desktop chrome.
///
/// Glyphs and labels can remain visually compact, but controls should not make
/// people aim at the glyph itself. Use `compact` for icon buttons and `row` for
/// clickable labels/list rows. Splitters are the one deliberately narrower
/// exception because they sit between two live panes.
enum OnyxHitTarget {
    static let compact: CGFloat = 32
    static let row: CGFloat = 34
    static let splitter: CGFloat = 11
}

/// A deliberately small type scale for the primary workspace.
///
/// Keeping these roles shared prevents half-point drift between SwiftUI chrome
/// and the AppKit transcript/composer. Weight still belongs to the semantic
/// use (for example, a selected task may become medium), while size comes from
/// one of these five roles.
enum OnyxTypography {
    /// Conversation prose, routine activity, and composer input intentionally
    /// share one compact size. Hierarchy comes from weight and color instead
    /// of making assistant text look like a different application.
    static let reading: CGFloat = 13.5
    static let paneTitle: CGFloat = 14
    static let navigation: CGFloat = 12.5
    static let secondary: CGFloat = 12
    static let metadata: CGFloat = 10.5
}

/// Shared workspace geometry. The app can remain visually compact while its
/// major panes, reading column, and controls land on the same rhythm.
enum OnyxWorkspaceMetrics {
    static let paneHeaderHeight: CGFloat = 48
    static let paneEdgeInset: CGFloat = 12
    static let fieldHeight: CGFloat = 32
    static let regularGap: CGFloat = 8
    static let minimumConversationSideInset: CGFloat = 14
    static let preferredConversationSideInset: CGFloat = 20
    static let conversationTextInset: CGFloat = 18
    /// The transcript row and composer shell can span a wide pane, but prose
    /// should not turn into an edge-to-edge line that is difficult to scan.
    /// This cap is deliberately generous so ordinary workspace sizes still
    /// use all available room; only very wide panes retain quiet trailing
    /// space for assistant prose and entered text.
    static let maximumConversationTextWidth: CGFloat = 880
    static let composerInnerInset: CGFloat = 12

    static func conversationSideInset(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else {
            return preferredConversationSideInset
        }
        return min(
            preferredConversationSideInset,
            max(minimumConversationSideInset, availableWidth * 0.03)
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
