import Foundation
import Security

/// Opaque credential-store locator. `description` intentionally reveals no
/// account names and secret bytes are never interpolated into errors.
struct ProviderCredentialKey: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    static let defaultService = "dev.peteallen.onyx.provider-bearer"

    let service: String
    let account: String

    init(
        connectionID: ProviderConnectionID,
        service: String = defaultService
    ) {
        self.service = service
        self.account = connectionID.rawValue
    }

    /// Internal initializer used by the versioned-slot transaction. The
    /// account remains an opaque Keychain locator; callers never receive a
    /// printable credential value through this type.
    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// Returns the legacy, stable-ID account used by records written before
    /// credential slots were introduced.
    static func legacy(
        connectionID: ProviderConnectionID,
        service: String = defaultService
    ) -> Self {
        Self(connectionID: connectionID, service: service)
    }

    /// A slot account is namespaced under the connection ID and carries only
    /// a random generation token. It is safe to persist in JSON because it is
    /// never a credential value.
    static func slot(
        connectionID: ProviderConnectionID,
        slotID: String,
        service: String = defaultService
    ) -> Self {
        Self(
            service: service,
            account: "\(connectionID.rawValue).slot.\(slotID)"
        )
    }

    var description: String { "provider credential" }
}

/// Secret container that avoids printable/String conformance. It cannot erase
/// copies made by Foundation or Security, but it keeps accidental logging and
/// JSON encoding out of the connection-management API.
struct ProviderBearerCredential: Equatable, Sendable {
    fileprivate let data: Data

    init(_ value: String) throws {
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            throw ProviderCredentialStoreError.emptyCredential
        }
        self.data = data
    }

    fileprivate init(validatedData data: Data) throws {
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
            throw ProviderCredentialStoreError.invalidCredentialData
        }
        self.data = data
    }

    /// Keeps raw secret access at the transport boundary rather than making
    /// the value broadly printable throughout the app.
    func withValue<T>(_ body: (String) throws -> T) throws -> T {
        guard let value = String(data: data, encoding: .utf8) else {
            throw ProviderCredentialStoreError.invalidCredentialData
        }
        return try body(value)
    }
}

protocol CredentialStore: Sendable {
    func credential(for key: ProviderCredentialKey) async throws -> ProviderBearerCredential?
    func setCredential(_ credential: ProviderBearerCredential, for key: ProviderCredentialKey) async throws
    func removeCredential(for key: ProviderCredentialKey) async throws
}

/// Optional capability implemented by durable stores that can enumerate only
/// Onyx's exact provider-credential service. Keeping this as a refinement of
/// `CredentialStore` preserves the small injected test seam used by existing
/// callers while allowing startup to remove abandoned versioned slots.
protocol CredentialStoreKeyListing: Sendable {
    func credentialKeys(forService service: String) async throws -> [ProviderCredentialKey]
}

extension CredentialStoreKeyListing {
    func keys(forService service: String) async throws -> [ProviderCredentialKey] {
        try await credentialKeys(forService: service)
    }
}

enum ProviderCredentialStoreError: LocalizedError, Equatable, Sendable {
    case emptyCredential
    case invalidCredentialData
    case invalidKeychainResult
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyCredential:
            "Provider credential cannot be empty."
        case .invalidCredentialData:
            "Provider credential data is invalid."
        case .invalidKeychainResult:
            "The provider credential index returned an invalid result."
        case let .keychainFailure(status):
            "The provider credential could not be accessed in Keychain (status \(status))."
        }
    }
}

/// macOS Keychain-backed bearer storage. Save uses an add-or-update operation;
/// reads return `nil` only for an absent item and surface every other Keychain
/// failure without including the secret in the error.
struct KeychainCredentialStore: CredentialStore, CredentialStoreKeyListing, Sendable {
    init() {}

    func credential(for key: ProviderCredentialKey) async throws -> ProviderBearerCredential? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProviderCredentialStoreError.keychainFailure(status)
        }
        return try ProviderBearerCredential(validatedData: data)
    }

    func setCredential(
        _ credential: ProviderBearerCredential,
        for key: ProviderCredentialKey
    ) async throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: credential.data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychainFailure(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProviderCredentialStoreError.keychainFailure(addStatus)
        }
    }

    func removeCredential(for key: ProviderCredentialKey) async throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.keychainFailure(status)
        }
    }

    /// Enumerates attributes only; secret bytes are never requested during a
    /// startup sweep. The service is mandatory so a malformed caller cannot
    /// accidentally scan or mutate the user's entire Keychain.
    func credentialKeys(forService service: String) async throws -> [ProviderCredentialKey] {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCredentialStoreError.invalidKeychainResult
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: kCFBooleanTrue,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let attributes = result as? [[String: Any]]
        else {
            throw ProviderCredentialStoreError.keychainFailure(status)
        }

        var keys: Set<ProviderCredentialKey> = []
        for item in attributes {
            guard let returnedService = item[kSecAttrService as String] as? String,
                  returnedService == service,
                  let account = item[kSecAttrAccount as String] as? String,
                  !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ProviderCredentialStoreError.invalidKeychainResult
            }
            keys.insert(ProviderCredentialKey(service: service, account: account))
        }
        return keys.sorted {
            if $0.service == $1.service { return $0.account < $1.account }
            return $0.service < $1.service
        }
    }

    private func baseQuery(for key: ProviderCredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ]
    }
}

/// Deterministic test/development implementation. It is an actor so it also
/// exercises the same async isolation expected by production callers.
actor InMemoryCredentialStore: CredentialStore, CredentialStoreKeyListing {
    private var values: [ProviderCredentialKey: ProviderBearerCredential] = [:]

    func credential(for key: ProviderCredentialKey) -> ProviderBearerCredential? {
        values[key]
    }

    func setCredential(
        _ credential: ProviderBearerCredential,
        for key: ProviderCredentialKey
    ) {
        values[key] = credential
    }

    func removeCredential(for key: ProviderCredentialKey) {
        values.removeValue(forKey: key)
    }

    func credentialKeys(forService service: String) -> [ProviderCredentialKey] {
        values.keys
            .filter { $0.service == service }
            .sorted {
                if $0.service == $1.service { return $0.account < $1.account }
                return $0.service < $1.service
            }
    }
}
