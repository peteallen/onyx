import Foundation
import SwiftUI

/// Native SwiftUI help tags currently crash inside `TooltipBridge` while
/// AppKit routes mouse enter/exit events on macOS 26 and later. Keep tooltip
/// presentation behind one policy so controls retain their VoiceOver guidance
/// without installing the affected native tracking bridge.
enum OnyxHelpPresentationPolicy {
    static let firstAffectedMacOSMajorVersion = 26

    static func usesNativeTooltip(macOSMajorVersion: Int) -> Bool {
        macOSMajorVersion < firstAffectedMacOSMajorVersion
    }

    static var usesNativeTooltipOnCurrentSystem: Bool {
        usesNativeTooltip(
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }
}

private struct OnyxHelpCompatibilityModifier: ViewModifier {
    let text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        let accessibilityHint = Text(verbatim: text)
        if OnyxHelpPresentationPolicy.usesNativeTooltipOnCurrentSystem {
            content
                .help(accessibilityHint)
                .accessibilityHint(accessibilityHint)
        } else {
            content.accessibilityHint(accessibilityHint)
        }
    }
}

extension View {
    /// Adds ordinary native help on unaffected macOS releases and an
    /// accessibility-only hint on releases with the SwiftUI tooltip crash.
    func onyxHelp(_ text: String) -> some View {
        modifier(OnyxHelpCompatibilityModifier(text: text))
    }
}
