import AppKit
import Foundation
import SwiftUI

struct OnyxWindowPresentationContext: @unchecked Sendable {
    let windowProvider: @MainActor () -> NSWindow?

    @MainActor
    var window: NSWindow? { windowProvider() }

    static let unavailable = Self(windowProvider: { nil })
}

private struct OnyxWindowPresentationContextKey: EnvironmentKey {
    static let defaultValue = OnyxWindowPresentationContext.unavailable
}

extension EnvironmentValues {
    var onyxWindowPresentationContext: OnyxWindowPresentationContext {
        get { self[OnyxWindowPresentationContextKey.self] }
        set { self[OnyxWindowPresentationContextKey.self] = newValue }
    }
}

/// Durable scene identity used by SwiftUI to restore each workspace window
/// independently. The UUID never crosses the provider boundary; it only scopes
/// app-owned window state and macOS frame restoration.
struct WorkspaceWindowID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init() {
        self.init(rawValue: UUID())
    }

    var id: UUID { rawValue }

    var preferenceKeyPrefix: String {
        "Onyx.window.\(rawValue.uuidString.lowercased())"
    }

    var frameAutosaveName: String {
        "Onyx.Window.\(rawValue.uuidString.lowercased())"
    }
}

/// Maps the existing single-window preference keys into a stable window
/// namespace. A nil prefix intentionally preserves the legacy keys so focused
/// model tests and callers outside production composition remain compatible.
struct OnyxPreferenceNamespace: Hashable, Sendable {
    let prefix: String?

    init(prefix: String?) {
        self.prefix = prefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func key(_ legacyKey: String) -> String {
        guard let prefix else { return legacyKey }
        let suffix = legacyKey.hasPrefix("Onyx.")
            ? String(legacyKey.dropFirst("Onyx.".count))
            : legacyKey
        return "\(prefix).\(suffix)"
    }
}

/// App-lifetime composition owner. It resolves and wraps the provider runtime
/// exactly once, then lends the same broadcast-capable coordinator to every
/// independently owned window model.
@MainActor
final class OnyxApplicationHost: ObservableObject {
    let runtimeCoordinator: SharedRuntimeCoordinator?
    let startupError: (any Error)?
    let defaults: UserDefaults
    let pinnedThreadStore: OnyxPinnedThreadStore
    let workspacePersistenceStore: OnyxWorkspacePersistenceStore
    let settingsModel: OnyxAppModel
    let providerSettingsModel: ProviderSettingsModel

    init(
        registry: RuntimeRegistry = .codexOnly,
        connectionID: ProviderConnectionID = .codexDefault,
        defaults: UserDefaults = .standard,
        providerConnectionStore: ProviderConnectionStore = ProviderConnectionStore(),
        providerCredentialStore: any CredentialStore = KeychainCredentialStore(),
        providerModelDiscovery: any ProviderModelDiscovery = URLSessionProviderModelDiscovery()
    ) {
        let coordinator: SharedRuntimeCoordinator?
        let resolutionError: (any Error)?
        do {
            coordinator = SharedRuntimeCoordinator(runtime: try registry.resolve(connectionID))
            resolutionError = nil
        } catch {
            coordinator = nil
            resolutionError = error
        }

        runtimeCoordinator = coordinator
        startupError = resolutionError
        self.defaults = defaults
        let pinnedThreadStore = OnyxPinnedThreadStore(defaults: defaults)
        let workspacePersistenceStore = OnyxWorkspacePersistenceStore(defaults: defaults)
        self.pinnedThreadStore = pinnedThreadStore
        self.workspacePersistenceStore = workspacePersistenceStore
        settingsModel = OnyxAppModel(
            runtime: coordinator,
            startupError: resolutionError,
            defaults: defaults,
            preferenceKeyPrefix: "Onyx.settings",
            pinnedThreadStore: pinnedThreadStore,
            workspacePersistenceStore: workspacePersistenceStore
        )
        providerSettingsModel = ProviderSettingsModel(
            connectionStore: providerConnectionStore,
            credentialStore: providerCredentialStore,
            discovery: providerModelDiscovery
        )
    }


    func makeWindowModel(for windowID: WorkspaceWindowID) -> OnyxAppModel {
        workspacePersistenceStore.prepareNamespace(windowID.preferenceKeyPrefix)
        return OnyxAppModel(
            runtime: runtimeCoordinator,
            startupError: startupError,
            defaults: defaults,
            preferenceKeyPrefix: windowID.preferenceKeyPrefix,
            pinnedThreadStore: pinnedThreadStore,
            workspacePersistenceStore: workspacePersistenceStore
        )
    }
}

@MainActor
private final class OnyxWindowReference: ObservableObject {
    weak var window: NSWindow?
}

/// Owns one `OnyxAppModel` and one terminal/view tree for exactly one restored
/// window. Closing the scene releases those objects without affecting siblings.
struct OnyxWindowRootView: View {
    let windowID: WorkspaceWindowID

    @StateObject private var model: OnyxAppModel
    @StateObject private var windowReference: OnyxWindowReference
    private let defaults: UserDefaults

    @MainActor
    init(windowID: WorkspaceWindowID, host: OnyxApplicationHost) {
        self.windowID = windowID
        _model = StateObject(wrappedValue: host.makeWindowModel(for: windowID))
        _windowReference = StateObject(wrappedValue: OnyxWindowReference())
        defaults = host.defaults
    }

    var body: some View {
        OnyxWorkspaceView(
            model: model,
            preferenceKeyPrefix: windowID.preferenceKeyPrefix,
            defaults: defaults,
            windowProvider: { windowReference.window }
        )
        .frame(minWidth: 860, minHeight: 620)
        .background(
            OnyxWindowConfigurator(
                windowID: windowID,
                windowReference: windowReference
            )
        )
        .task { model.start() }
        .onDisappear { model.flushWindowState() }
    }
}

private struct OnyxWindowConfigurator: NSViewRepresentable {
    let windowID: WorkspaceWindowID
    let windowReference: OnyxWindowReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    @MainActor
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        windowReference.window = window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 860, height: 620)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName(windowID.frameAutosaveName)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
