import Foundation

/// Tracks durable workspace namespaces so account-owned state can be cleared
/// even when its window is currently closed. It also performs the one-time
/// migration from Onyx's original single-window keys into the first restored
/// multiwindow scene.
@MainActor
final class OnyxWorkspacePersistenceStore {
    private enum Key {
        static let knownPrefixes = "Onyx.workspaceWindowPreferencePrefixes"
        static let didMigrateLegacy = "Onyx.didMigrateLegacyWindowPreferences"
    }

    private static let windowPreferenceSuffixes = [
        "sidebarVisible",
        "inspectorVisible",
        "bottomPanelVisible",
        "inspectorTab",
        "selectedModelID",
        "reasoningEffort",
        "permissionLabel",
        "threadListScope",
        "selectedThreadID",
        "composerDrafts",
        "taskModelOverrides",
        "taskModelDefaults",
        "lastWorkspacePath",
        "terminalHeight",
    ]

    private static let accountOwnedSuffixes = [
        "selectedThreadID",
        "composerDrafts",
        "taskModelOverrides",
        "taskModelDefaults",
        "lastWorkspacePath",
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func prepareNamespace(_ prefix: String) {
        var knownPrefixes = Set(defaults.stringArray(forKey: Key.knownPrefixes) ?? [])
        if !defaults.bool(forKey: Key.didMigrateLegacy) {
            migrateLegacyPreferences(to: prefix)
            defaults.set(true, forKey: Key.didMigrateLegacy)
        }
        if knownPrefixes.insert(prefix).inserted {
            defaults.set(Array(knownPrefixes).sorted(), forKey: Key.knownPrefixes)
        }
    }

    func clearAccountOwnedState() {
        let prefixes = defaults.stringArray(forKey: Key.knownPrefixes) ?? []
        for suffix in Self.accountOwnedSuffixes {
            defaults.removeObject(forKey: "Onyx.\(suffix)")
            for prefix in prefixes {
                defaults.removeObject(forKey: "\(prefix).\(suffix)")
            }
        }
    }

    private func migrateLegacyPreferences(to prefix: String) {
        for suffix in Self.windowPreferenceSuffixes {
            let legacyKey = "Onyx.\(suffix)"
            guard let value = defaults.object(forKey: legacyKey) else { continue }
            defaults.set(value, forKey: "\(prefix).\(suffix)")
            defaults.removeObject(forKey: legacyKey)
        }
    }
}
