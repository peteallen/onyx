import SwiftUI

struct CommandRailView: View {
    @ObservedObject var model: OnyxAppModel
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            OnyxMark(size: 21)
                .padding(.top, 14)
                .padding(.bottom, 7)
                .accessibilityHidden(true)

            RailButton(
                icon: "bubble.left.and.bubble.right",
                label: "Tasks",
                isSelected: isSidebarVisible,
                hint: isSidebarVisible ? "Hides the task sidebar" : "Shows the task sidebar",
                action: onToggleSidebar
            )

            Divider()
                .overlay(Color.primary.opacity(0.08))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            RailButton(
                icon: "terminal",
                label: "Terminal",
                isSelected: model.isBottomPanelVisible,
                hint: model.isBottomPanelVisible ? "Hides the terminal" : "Shows the terminal"
            ) {
                model.isBottomPanelVisible.toggle()
            }

            Spacer()

            ConnectionGlyph(
                state: model.connectionState,
                runtimeName: model.runtimeDisplayName
            )
                .padding(.bottom, 3)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
            .onyxHelp("Settings")
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens Onyx settings")
            .padding(.bottom, 12)
        }
        .frame(width: WorkspacePaneLayout.commandRailWidth)
        .frame(maxHeight: .infinity)
        .background(OnyxTheme.rail)
    }
}

private struct RailButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 32)
                .background(isSelected ? OnyxTheme.railRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .leading) {
                    if isSelected {
                        Capsule()
                            .fill(OnyxTheme.iris)
                            .frame(width: 2, height: 14)
                            .offset(x: -5)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .onyxHelp(hint ?? label)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConnectionGlyph: View {
    let state: RuntimeConnectionState
    let runtimeName: String

    var color: Color {
        switch state {
        case .connected: OnyxTheme.success
        case .connecting: OnyxTheme.warning
        case .failed: OnyxTheme.destructive
        case .disconnected: Color.secondary.opacity(0.45)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.28), lineWidth: 4).frame(width: 20, height: 20)
            Image(systemName: state.onyxAccessibilitySymbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(color)
        }
        .onyxHelp(state.onyxAccessibilityValue(runtimeName: runtimeName))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Runtime connection")
        .accessibilityValue(state.onyxAccessibilityValue(runtimeName: runtimeName))
    }
}

extension RuntimeConnectionState {
    var onyxAccessibilitySymbol: String {
        switch self {
        case .connected: "checkmark"
        case .connecting: "ellipsis"
        case .failed: "exclamationmark"
        case .disconnected: "minus"
        }
    }

    func onyxAccessibilityValue(runtimeName: String) -> String {
        switch self {
        case .connected: "Connected: \(runtimeName)"
        case .connecting: "Connecting to \(runtimeName)"
        case let .failed(message): "Connection failed: \(message)"
        case .disconnected: "Disconnected"
        }
    }
}
