import AppKit
import SwiftUI

@main
struct OnyxApp: App {
    @StateObject private var host: OnyxApplicationHost

    init() {
        // Onyx's product baseline is the restrained near-black workspace.
        // Set the AppKit appearance as well as SwiftUI's color scheme because
        // the transcript and composer are native AppKit surfaces whose
        // dynamic colors resolve from the window appearance.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        _host = StateObject(wrappedValue: OnyxApplicationHost())
    }

    var body: some Scene {
        WindowGroup("Onyx", for: WorkspaceWindowID.self) { $windowID in
            OnyxWindowRootView(
                windowID: windowID,
                host: host
            )
            .preferredColorScheme(.dark)
        }
        defaultValue: { WorkspaceWindowID() }
        .defaultSize(width: 1_380, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            OnyxCommands()
        }

        Settings {
            OnyxSettingsView(
                model: host.settingsModel,
                providerModel: host.providerSettingsModel
            )
                .frame(width: 900, height: 680)
                .preferredColorScheme(.dark)
                .task { host.settingsModel.start() }
        }
    }
}

struct OnyxWindowCommandContext {
    let newTask: () -> Void
    let openProject: () -> Void
    let openQuickOpen: () -> Void
    let focusTaskSearch: () -> Void
    let toggleSidebar: () -> Void
    let toggleInspector: () -> Void
    let toggleTerminal: () -> Void

    @MainActor
    static func workspace(
        model: OnyxAppModel,
        windowProvider: @escaping @MainActor () -> NSWindow?,
        openProject: (() -> Void)? = nil,
        openQuickOpen: @escaping () -> Void = {},
        focusTaskSearch: @escaping () -> Void,
        toggleSidebar: (() -> Void)? = nil
    ) -> Self {
        Self(
            newTask: model.newTask,
            openProject: openProject ?? { model.chooseWorkspace(window: windowProvider()) },
            openQuickOpen: openQuickOpen,
            focusTaskSearch: focusTaskSearch,
            toggleSidebar: toggleSidebar ?? { model.isSidebarVisible.toggle() },
            toggleInspector: { model.isInspectorVisible.toggle() },
            toggleTerminal: { model.isBottomPanelVisible.toggle() }
        )
    }
}

struct OnyxTaskCommandContext {
    let isArchived: Bool
    let isPinned: Bool
    let isBusy: Bool
    let canFork: Bool
    let canCompact: Bool
    let canDelete: Bool
    let rename: () -> Void
    let togglePin: () -> Void
    let fork: () -> Void
    let compact: () -> Void
    let archive: () -> Void
    let restore: () -> Void
    let delete: () -> Void
}

private struct OnyxTaskCommandContextKey: FocusedValueKey {
    typealias Value = OnyxTaskCommandContext
}

private struct OnyxWindowCommandContextKey: FocusedValueKey {
    typealias Value = OnyxWindowCommandContext
}

extension FocusedValues {
    var onyxWindowCommands: OnyxWindowCommandContext? {
        get { self[OnyxWindowCommandContextKey.self] }
        set { self[OnyxWindowCommandContextKey.self] = newValue }
    }

    var onyxTaskCommands: OnyxTaskCommandContext? {
        get { self[OnyxTaskCommandContextKey.self] }
        set { self[OnyxTaskCommandContextKey.self] = newValue }
    }
}

private struct OnyxCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.onyxWindowCommands) private var windowCommands
    @FocusedValue(\.onyxTaskCommands) private var taskCommands

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") {
                windowCommands?.newTask()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(windowCommands == nil)

            Button("New Window") {
                openWindow(value: WorkspaceWindowID())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Open Project…") {
                windowCommands?.openProject()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(windowCommands == nil)
        }

        // Command-P is Onyx's project quick open. Replacing the standard Print
        // command avoids two menu items competing for the same key equivalent.
        CommandGroup(replacing: .printItem) {
            Button("Quick Open…") {
                windowCommands?.openQuickOpen()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(windowCommands == nil)
        }

        CommandMenu("Task") {
            Button("Search Tasks") {
                windowCommands?.focusTaskSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(windowCommands == nil)

            Divider()

            if taskCommands?.isArchived == true {
                Button("Restore Task") { taskCommands?.restore() }

                if taskCommands?.canDelete == true {
                    Divider()
                    Button("Delete Permanently…", role: .destructive) { taskCommands?.delete() }
                }
            } else {
                Button("Rename…") { taskCommands?.rename() }
                    .disabled(taskCommands == nil)
                Button(taskCommands?.isPinned == true ? "Unpin" : "Pin") {
                    taskCommands?.togglePin()
                }
                .disabled(taskCommands == nil)

                if taskCommands?.canFork == true {
                    Button("Fork Task") { taskCommands?.fork() }
                        .disabled(taskCommands?.isBusy != false)
                }

                if taskCommands?.canCompact == true {
                    Divider()
                    Button("Compact Context") { taskCommands?.compact() }
                        .disabled(taskCommands?.isBusy != false)
                }

                Button("Archive") { taskCommands?.archive() }
                    .disabled(taskCommands?.isBusy != false)

                if taskCommands?.canDelete == true {
                    Divider()
                    Button("Delete Permanently…", role: .destructive) { taskCommands?.delete() }
                }
            }
        }

        CommandMenu("View") {
            Button("Toggle Sidebar") {
                windowCommands?.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(windowCommands == nil)

            Button("Toggle Context Panel") {
                windowCommands?.toggleInspector()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            .disabled(windowCommands == nil)

            Button("Toggle Terminal") {
                windowCommands?.toggleTerminal()
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(windowCommands == nil)
        }
    }
}

private struct OnyxSettingsView: View {
    @ObservedObject var model: OnyxAppModel
    @ObservedObject var providerModel: ProviderSettingsModel

    var body: some View {
        TabView {
            codexSettings
                .tabItem {
                    Label("Codex", systemImage: "sparkles")
                }

            ProviderSettingsView(model: providerModel)
                .tabItem {
                    Label("Providers", systemImage: "point.3.connected.trianglepath.dotted")
                }
        }
    }

    private var codexSettings: some View {
        Form {
            Section("Runtime") {
                LabeledContent("Provider", value: model.session?.displayName ?? "Codex")
                LabeledContent("Status", value: connectionLabel)
            }
            Section("Account") {
                LabeledContent("Account", value: model.authState.displayLabel)
                LabeledContent("Plan", value: model.authState.planDisplayLabel ?? "—")

                if let attempt = model.loginAttempt {
                    if let code = attempt.userCode {
                        LabeledContent("One-time code") {
                            HStack(spacing: 8) {
                                Text(code)
                                    .font(.system(.body, design: .monospaced, weight: .semibold))
                                    .textSelection(.enabled)
                                Button("Copy", action: model.copyDeviceCode)
                            }
                        }
                    }
                    HStack {
                        Button("Open Sign In", action: model.reopenLoginPage)
                            .buttonStyle(.borderedProminent)
                            .tint(OnyxTheme.iris)
                        Button("Cancel", action: model.cancelLogin)
                            .disabled(model.isAuthenticating)
                    }
                } else if model.authState.isSignedIn {
                    Button("Sign Out", role: .destructive, action: model.signOut)
                        .disabled(model.isSigningOut)
                    if model.isSigningOut { ProgressView().controlSize(.small) }
                } else if model.isAuthenticating {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Starting secure sign in…").foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        if let method = model.primaryLoginMethod {
                            Button(method.displayName) { model.startLogin(method) }
                                .buttonStyle(.borderedProminent)
                                .tint(OnyxTheme.iris)
                        }
                        if let method = model.deviceCodeLoginMethod {
                            Button(method.displayName) { model.startLogin(method) }
                        }
                    }
                }

                Text("Onyx delegates authentication and token refresh to the Codex runtime. It never receives or stores your ChatGPT tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Text("Onyx uses a restrained near-black appearance and reserves its mineral accent for focus, selection, and live activity.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var connectionLabel: String {
        switch model.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        case .failed: "Unavailable"
        }
    }
}
