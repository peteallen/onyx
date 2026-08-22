import AppKit
import SwiftUI

enum OnyxTheme {
    static let rail = Color(red: 0.045, green: 0.047, blue: 0.058)
    static let railRaised = Color(red: 0.09, green: 0.095, blue: 0.115)
    static let iris = Color(red: 0.42, green: 0.36, blue: 0.98)
    static let electric = Color(red: 0.25, green: 0.76, blue: 0.94)
    static let success = Color(red: 0.24, green: 0.72, blue: 0.50)
    static let warning = Color(red: 0.96, green: 0.64, blue: 0.25)
    static let destructive = Color(red: 0.94, green: 0.35, blue: 0.40)

    static let canvas = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.070, green: 0.073, blue: 0.088, alpha: 1)
                : NSColor(srgbRed: 0.965, green: 0.961, blue: 0.948, alpha: 1)
        }
    )

    static let sidebar = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.085, green: 0.088, blue: 0.105, alpha: 1)
                : NSColor(srgbRed: 0.925, green: 0.919, blue: 0.900, alpha: 1)
        }
    )

    static let surface = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.105, green: 0.109, blue: 0.129, alpha: 1)
                : NSColor(srgbRed: 0.995, green: 0.993, blue: 0.986, alpha: 1)
        }
    )

    static let raisedSurface = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.135, green: 0.140, blue: 0.163, alpha: 1)
                : NSColor.white
        }
    )

    static let border = Color.primary.opacity(0.105)
    static let quietText = Color.secondary.opacity(0.78)
    static let hairline = 1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0)
    static let accentGradient = LinearGradient(
        colors: [iris, electric],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
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
