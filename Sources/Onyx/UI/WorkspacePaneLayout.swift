import AppKit
import SwiftUI

/// The sizing rules for the three primary workspace panes.
///
/// Widths are kept as window-local preferences by `OnyxWorkspaceView`.  This
/// type intentionally contains no view or persistence state so the rules can
/// be exercised without constructing an AppKit window.
enum WorkspacePaneLayout {
    static let commandRailWidth: CGFloat = 52
    static let dividerWidth: CGFloat = 7
    /// Protect enough room for the transcript and composer to remain the
    /// primary workspace, even when both supporting panes are open.
    static let minimumConversationWidth: CGFloat = 640

    static let sidebarDefaultWidth: CGFloat = 264
    static let sidebarMinimumWidth: CGFloat = 220
    static let sidebarMaximumWidth: CGFloat = 420

    static let inspectorDefaultWidth: CGFloat = 326
    static let inspectorMinimumWidth: CGFloat = 280
    static let inspectorMaximumWidth: CGFloat = 480

    /// The narrowest width where both panes can occupy space without pushing
    /// the conversation below its protected width. Below this point a
    /// requested inspector temporarily takes the side-pane slot; the sidebar
    /// preference remains intact for wider windows.
    static let compactBreakpoint: CGFloat = commandRailWidth
        + dividerWidth * 2
        + sidebarMinimumWidth
        + inspectorMinimumWidth
        + minimumConversationWidth
    static let accessibilityStep: CGFloat = 24

    static let sidebarWidthPreferenceSuffix = "Onyx.sidebarWidth"
    static let inspectorWidthPreferenceSuffix = "Onyx.inspectorWidth"

    static func isCompact(totalWidth: CGFloat) -> Bool {
        guard totalWidth.isFinite else { return false }
        return totalWidth < compactBreakpoint
    }

    /// Whether the task sidebar is actually occupying workspace width. At
    /// compact sizes the inspector temporarily takes precedence without
    /// discarding the user's sidebar preference for a wider window.
    static func isSidebarDisplayed(
        sidebarRequested: Bool,
        inspectorVisible: Bool,
        isCompact: Bool
    ) -> Bool {
        sidebarRequested && (!isCompact || !inspectorVisible)
    }

    /// Resolves the state change requested by the task-rail button. The
    /// button follows what is on screen, so revealing the sidebar at a compact
    /// width also dismisses the inspector that was keeping it hidden.
    static func sidebarToggleTarget(
        sidebarDisplayed: Bool,
        inspectorVisible: Bool,
        isCompact: Bool
    ) -> (sidebarRequested: Bool, inspectorVisible: Bool) {
        if sidebarDisplayed {
            return (false, inspectorVisible)
        }
        return (true, isCompact ? false : inspectorVisible)
    }

    static func clampedStoredSidebarWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return sidebarDefaultWidth }
        return min(max(width, sidebarMinimumWidth), sidebarMaximumWidth)
    }

    static func clampedStoredInspectorWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return inspectorDefaultWidth }
        return min(max(width, inspectorMinimumWidth), inspectorMaximumWidth)
    }

    /// Returns the range that can be displayed while leaving a readable
    /// conversation area and reserving the currently displayed inspector.
    ///
    /// If a very small window cannot satisfy every minimum simultaneously, the
    /// intrinsic minimum wins. The window itself has a larger minimum in the
    /// production scene, but this fallback keeps layout deterministic for
    /// embedded/snapshot callers too.
    static func sidebarRange(
        totalWidth: CGFloat,
        inspectorVisible: Bool,
        inspectorWidth: CGFloat = inspectorDefaultWidth
    ) -> ClosedRange<CGFloat> {
        let reservedInspector = inspectorVisible
            ? dividerWidth + clampedStoredInspectorWidth(inspectorWidth)
            : 0
        let availableMaximum = totalWidth
            - commandRailWidth
            - dividerWidth
            - minimumConversationWidth
            - reservedInspector
        return range(
            minimum: sidebarMinimumWidth,
            maximum: sidebarMaximumWidth,
            availableMaximum: availableMaximum
        )
    }

    static func inspectorRange(
        totalWidth: CGFloat,
        sidebarVisible: Bool,
        sidebarWidth: CGFloat = sidebarDefaultWidth
    ) -> ClosedRange<CGFloat> {
        let reservedSidebar = sidebarVisible
            ? dividerWidth + clampedStoredSidebarWidth(sidebarWidth)
            : 0
        let availableMaximum = totalWidth
            - commandRailWidth
            - dividerWidth
            - minimumConversationWidth
            - reservedSidebar
        return range(
            minimum: inspectorMinimumWidth,
            maximum: inspectorMaximumWidth,
            availableMaximum: availableMaximum
        )
    }

    static func displayedSidebarWidth(
        storedWidth: CGFloat,
        totalWidth: CGFloat,
        inspectorVisible: Bool,
        inspectorWidth: CGFloat = inspectorDefaultWidth
    ) -> CGFloat {
        clamp(storedWidth, to: sidebarRange(
            totalWidth: totalWidth,
            inspectorVisible: inspectorVisible,
            inspectorWidth: inspectorWidth
        ))
    }

    static func displayedInspectorWidth(
        storedWidth: CGFloat,
        totalWidth: CGFloat,
        sidebarVisible: Bool,
        sidebarWidth: CGFloat = sidebarDefaultWidth
    ) -> CGFloat {
        clamp(storedWidth, to: inspectorRange(
            totalWidth: totalWidth,
            sidebarVisible: sidebarVisible,
            sidebarWidth: sidebarWidth
        ))
    }

    static func adjustedSidebarWidth(_ width: CGFloat, increasing: Bool) -> CGFloat {
        clampedStoredSidebarWidth(width + (increasing ? accessibilityStep : -accessibilityStep))
    }

    static func adjustedInspectorWidth(_ width: CGFloat, increasing: Bool) -> CGFloat {
        clampedStoredInspectorWidth(width + (increasing ? accessibilityStep : -accessibilityStep))
    }

    static func accessibilityValue(for width: CGFloat) -> String {
        "\(Int(width.rounded())) points wide"
    }

    private static func range(
        minimum: CGFloat,
        maximum: CGFloat,
        availableMaximum: CGFloat
    ) -> ClosedRange<CGFloat> {
        let finiteAvailableMaximum = availableMaximum.isFinite ? availableMaximum : maximum
        let upperBound = min(maximum, max(minimum, finiteAvailableMaximum))
        return minimum ... upperBound
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

enum WorkspacePaneResizeAxis {
    case horizontal
    case vertical
}

/// Which side of a splitter owns the width being changed. A trailing pane's
/// width grows when the divider is dragged toward the leading edge.
enum WorkspacePaneResizeDirection {
    case leadingPane
    case trailingPane
}

/// A deliberately small native splitter used by the workspace and kept
/// independent from any one pane's content. It supports mouse dragging,
/// cursor feedback, and VoiceOver's adjustable action.
struct WorkspacePaneResizeHandle: View {
    @Binding var value: CGFloat
    let axis: WorkspacePaneResizeAxis
    let direction: WorkspacePaneResizeDirection
    let label: String
    let accessibilityStep: CGFloat
    let accessibilityValueFormatter: (CGFloat) -> String
    let onEditingEnded: () -> Void

    @State private var dragStartValue: CGFloat?
    @State private var isHovering = false

    init(
        value: Binding<CGFloat>,
        axis: WorkspacePaneResizeAxis = .horizontal,
        direction: WorkspacePaneResizeDirection = .leadingPane,
        label: String,
        accessibilityStep: CGFloat = WorkspacePaneLayout.accessibilityStep,
        accessibilityValueFormatter: @escaping (CGFloat) -> String = WorkspacePaneLayout.accessibilityValue,
        onEditingEnded: @escaping () -> Void = {}
    ) {
        _value = value
        self.axis = axis
        self.direction = direction
        self.label = label
        self.accessibilityStep = accessibilityStep
        self.accessibilityValueFormatter = accessibilityValueFormatter
        self.onEditingEnded = onEditingEnded
    }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(
                width: axis == .horizontal ? WorkspacePaneLayout.dividerWidth : nil,
                height: axis == .vertical ? WorkspacePaneLayout.dividerWidth : nil
            )
            .overlay {
                Capsule()
                    // Keep the hit target present for mouse and VoiceOver, but
                    // let the separator disappear into the chrome until it is
                    // actually being discovered or dragged.
                    .fill(Color.secondary.opacity(isHovering ? 0.62 : 0))
                    .frame(
                        width: axis == .horizontal ? 2 : 34,
                        height: axis == .vertical ? 2 : 34
                    )
                    .padding(axis == .horizontal ? .vertical : .horizontal, 12)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                setCursor(hovering)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        if dragStartValue == nil {
                            dragStartValue = value
                        }
                        let start = dragStartValue ?? value
                        value = start + signedTranslation(for: gesture.translation)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        onEditingEnded()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(accessibilityValueFormatter(value))
            .accessibilityHint("Drag to resize, or adjust with VoiceOver")
            .accessibilityAdjustableAction { adjustment in
                switch adjustment {
                case .increment:
                    value += accessibilityStep
                case .decrement:
                    value -= accessibilityStep
                @unknown default:
                    break
                }
                onEditingEnded()
            }
    }

    private func signedTranslation(for translation: CGSize) -> CGFloat {
        let raw = switch axis {
        case .horizontal:
            translation.width
        case .vertical:
            -translation.height
        }
        switch direction {
        case .leadingPane:
            return raw
        case .trailingPane:
            return -raw
        }
    }

    private func setCursor(_ hovering: Bool) {
        switch axis {
        case .horizontal:
            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        case .vertical:
            (hovering ? NSCursor.resizeUpDown : NSCursor.arrow).set()
        }
    }
}
