import SwiftUI

/// Low-frequency workspace controls live with the task list instead of
/// reserving a permanent strip of window chrome. This keeps the conversation
/// visually primary while leaving runtime state, Terminal, and Settings one
/// click away whenever the sidebar is open.
struct SidebarUtilityFooter: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        HStack(spacing: 4) {
            ConnectionStatus(
                state: model.connectionState,
                runtimeName: model.runtimeDisplayName
            )

            Spacer(minLength: 8)

            UtilityButton(
                icon: "terminal",
                label: "Terminal",
                isSelected: model.isBottomPanelVisible,
                hint: model.isBottomPanelVisible ? "Hides the terminal" : "Shows the terminal"
            ) {
                model.isBottomPanelVisible.toggle()
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
            .onyxHelp("Settings")
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens Onyx settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OnyxTheme.border)
                .frame(height: OnyxTheme.hairline)
        }
    }
}

private struct UtilityButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? OnyxTheme.iris.opacity(0.09) : Color.clear)
                    .frame(width: 27, height: 27)
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? OnyxTheme.iris : Color.secondary)
        .onyxHelp(hint ?? label)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConnectionStatus: View {
    let state: RuntimeConnectionState
    let runtimeName: String

    var color: Color {
        switch state {
        case .connected: OnyxTheme.success
        case .connecting: OnyxTheme.electric
        case .failed: OnyxTheme.destructive
        case .disconnected: Color.secondary.opacity(0.45)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.16))
                    .frame(width: 16, height: 16)
                Image(systemName: state.onyxAccessibilitySymbol)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(runtimeName)
                .font(.system(size: OnyxTypography.metadata, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
