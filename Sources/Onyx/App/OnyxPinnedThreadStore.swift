import Foundation

/// App-lifetime ownership for shared pin metadata. Window models never cache
/// and overwrite independent copies of the set; every mutation is serialized
/// on the main actor and immediately published to sibling windows.
@MainActor
final class OnyxPinnedThreadStore: ObservableObject {
    @Published private(set) var ids: Set<String>

    private let defaults: UserDefaults
    private let preferenceKey: String
    private static let legacyCodexPreferenceKey = "Onyx.pinnedThreadIDs"

    /// Thread IDs are opaque only inside one provider connection. Codex keeps
    /// the original key as a one-time, zero-copy migration; every additional
    /// provider receives a separate namespace so colliding IDs cannot share
    /// pin state or clear each other during account lifecycle operations.
    init(
        defaults: UserDefaults = .standard,
        connectionID: ProviderConnectionID = .codexDefault
    ) {
        self.defaults = defaults
        preferenceKey = Self.preferenceKey(for: connectionID)
        ids = Set(defaults.stringArray(forKey: preferenceKey) ?? [])
    }

    func toggle(_ id: String) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        persist()
    }

    func remove(_ id: String) {
        guard ids.remove(id) != nil else { return }
        persist()
    }

    func removeAll() {
        guard !ids.isEmpty || defaults.object(forKey: preferenceKey) != nil else { return }
        ids.removeAll()
        defaults.removeObject(forKey: preferenceKey)
    }

    private func persist() {
        defaults.set(Array(ids).sorted(), forKey: preferenceKey)
    }

    private static func preferenceKey(for connectionID: ProviderConnectionID) -> String {
        guard connectionID != .codexDefault else { return legacyCodexPreferenceKey }
        let encoded = Data(connectionID.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "Onyx.provider.\(encoded).pinnedThreadIDs"
    }
}
