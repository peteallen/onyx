import SwiftUI

struct CommandRailView: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        VStack(spacing: 9) {
            OnyxMark(size: 28)
                .padding(.top, 13)
                .padding(.bottom, 6)
                .accessibilityHidden(true)

            RailButton(
                icon: "bubble.left.and.bubble.right",
                label: "Tasks",
                isSelected: true,
                hint: model.isSidebarVisible ? "Task workspace selected" : "Shows the task sidebar"
            ) {
                model.isSidebarVisible = true
            }
            RailButton(
                icon: "sparkles",
                label: "Work",
                isSelected: false,
                isEnabled: false,
                hint: "This workspace is not available yet"
            ) {}

            Divider()
                .overlay(Color.white.opacity(0.10))
                .padding(.horizontal, 11)
                .padding(.vertical, 3)

            RailButton(
                icon: "sidebar.leading",
                label: "Sidebar",
                isSelected: model.isSidebarVisible,
                hint: model.isSidebarVisible ? "Hides the task sidebar" : "Shows the task sidebar"
            ) {
                model.isSidebarVisible.toggle()
            }

            RailButton(
                icon: "terminal",
                label: "Terminal",
                isSelected: model.isBottomPanelVisible,
                hint: model.isBottomPanelVisible ? "Hides the terminal" : "Shows the terminal"
            ) {
                model.isBottomPanelVisible.toggle()
            }

            Spacer()

            ConnectionGlyph(state: model.connectionState)
                .padding(.bottom, 3)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.68))
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens Onyx settings")
            .padding(.bottom, 12)
        }
        .frame(width: 52)
        .frame(maxHeight: .infinity)
        .background(OnyxTheme.rail)
    }
}

private struct RailButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    var isEnabled = true
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 34, height: 34)
                .background(isSelected ? OnyxTheme.railRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .leading) {
                    if isSelected {
                        Capsule()
                            .fill(OnyxTheme.accentGradient)
                            .frame(width: 2.5, height: 16)
                            .offset(x: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.57))
        .help(hint ?? label)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ConnectionGlyph: View {
    let state: RuntimeConnectionState

    var color: Color {
        switch state {
        case .connected: OnyxTheme.success
        case .connecting: OnyxTheme.warning
        case .failed: OnyxTheme.destructive
        case .disconnected: Color.white.opacity(0.32)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.28), lineWidth: 4).frame(width: 20, height: 20)
            Image(systemName: state.onyxAccessibilitySymbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(color)
        }
        .help(state.onyxAccessibilityValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Runtime connection")
        .accessibilityValue(state.onyxAccessibilityValue)
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

    var onyxAccessibilityValue: String {
        switch self {
        case let .connected(label): "Connected: \(label)"
        case .connecting: "Connecting to Codex"
        case let .failed(message): "Connection failed: \(message)"
        case .disconnected: "Disconnected"
        }
    }
}
