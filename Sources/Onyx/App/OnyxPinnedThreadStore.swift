import Foundation

/// App-lifetime ownership for shared pin metadata. Window models never cache
/// and overwrite independent copies of the set; every mutation is serialized
/// on the main actor and immediately published to sibling windows.
@MainActor
final class OnyxPinnedThreadStore: ObservableObject {
    @Published private(set) var ids: Set<String>

    private let defaults: UserDefaults
    private static let preferenceKey = "Onyx.pinnedThreadIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.preferenceKey) ?? [])
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
        guard !ids.isEmpty || defaults.object(forKey: Self.preferenceKey) != nil else { return }
        ids.removeAll()
        defaults.removeObject(forKey: Self.preferenceKey)
    }

    private func persist() {
        defaults.set(Array(ids).sorted(), forKey: Self.preferenceKey)
    }
}
