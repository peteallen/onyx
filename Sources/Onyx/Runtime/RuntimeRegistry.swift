import Foundation

/// Stable identity for an adapter implementation. This is deliberately
/// separate from a configured provider connection: one adapter may eventually
/// serve several accounts or endpoints.
struct RuntimeAdapterID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    var description: String { rawValue }

    static let codexAppServer = Self("openai.codex.app-server")
}

/// App-owned identity for one configured provider connection. The value is
/// opaque to presentation code and never contains credentials.
struct ProviderConnectionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    var description: String { rawValue }

    static let codexDefault = Self("openai.codex.default")
}

/// A model name scoped to the connection that advertised it. Provider model
/// names are not globally unique, so storing only the provider's string would
/// make future account/provider switching ambiguous.
struct ModelRef: Codable, Hashable, Sendable {
    let connectionID: ProviderConnectionID
    let modelID: String

    init(connectionID: ProviderConnectionID, modelID: String) {
        self.connectionID = connectionID
        self.modelID = modelID
    }
}

/// Static metadata and construction boundary for one runtime adapter.
struct RuntimeProviderDescriptor: Identifiable, Sendable {
    typealias Factory = @Sendable (ProviderConnectionID) throws -> any AgentRuntime

    let id: RuntimeAdapterID
    let displayName: String
    private let factory: Factory

    init(
        id: RuntimeAdapterID,
        displayName: String,
        factory: @escaping Factory
    ) {
        self.id = id
        self.displayName = displayName
        self.factory = factory
    }

    func makeRuntime(for connectionID: ProviderConnectionID) throws -> any AgentRuntime {
        try factory(connectionID)
    }

    static let codexAppServer = Self(
        id: .codexAppServer,
        displayName: "Codex"
    ) { _ in
        try CodexRuntime.makeDefault()
    }
}

/// The app-owned binding from a durable connection identity to the adapter
/// that knows how to open it.
struct RuntimeConnectionRegistration: Identifiable, Hashable, Sendable {
    let id: ProviderConnectionID
    let adapterID: RuntimeAdapterID
}

enum RuntimeRegistryError: LocalizedError, Equatable, Sendable {
    case duplicateAdapterID(RuntimeAdapterID)
    case duplicateConnectionID(ProviderConnectionID)
    case connectionReferencesMissingAdapter(
        connectionID: ProviderConnectionID,
        adapterID: RuntimeAdapterID
    )
    case connectionNotRegistered(ProviderConnectionID)
    case adapterNotRegistered(RuntimeAdapterID)

    var errorDescription: String? {
        switch self {
        case let .duplicateAdapterID(id):
            "Runtime adapter \(id) is registered more than once."
        case let .duplicateConnectionID(id):
            "Runtime connection \(id) is registered more than once."
        case let .connectionReferencesMissingAdapter(connectionID, adapterID):
            "Runtime connection \(connectionID) references unregistered adapter \(adapterID)."
        case let .connectionNotRegistered(id):
            "No runtime connection is registered for \(id)."
        case let .adapterNotRegistered(id):
            "No runtime adapter is registered for \(id)."
        }
    }
}

/// Small composition registry. It contains no credentials or mutable provider
/// state; those remain inside the adapter selected by a connection binding.
struct RuntimeRegistry: Sendable {
    let providers: [RuntimeProviderDescriptor]
    let connections: [RuntimeConnectionRegistration]

    private let providersByID: [RuntimeAdapterID: RuntimeProviderDescriptor]
    private let connectionsByID: [ProviderConnectionID: RuntimeConnectionRegistration]

    init(
        providers: [RuntimeProviderDescriptor],
        connections: [RuntimeConnectionRegistration]
    ) throws {
        var providersByID: [RuntimeAdapterID: RuntimeProviderDescriptor] = [:]
        providersByID.reserveCapacity(providers.count)
        for provider in providers {
            guard providersByID.updateValue(provider, forKey: provider.id) == nil else {
                throw RuntimeRegistryError.duplicateAdapterID(provider.id)
            }
        }

        var connectionsByID: [ProviderConnectionID: RuntimeConnectionRegistration] = [:]
        connectionsByID.reserveCapacity(connections.count)
        for connection in connections {
            guard connectionsByID.updateValue(connection, forKey: connection.id) == nil else {
                throw RuntimeRegistryError.duplicateConnectionID(connection.id)
            }
            guard providersByID[connection.adapterID] != nil else {
                throw RuntimeRegistryError.connectionReferencesMissingAdapter(
                    connectionID: connection.id,
                    adapterID: connection.adapterID
                )
            }
        }

        self.providers = providers
        self.connections = connections
        self.providersByID = providersByID
        self.connectionsByID = connectionsByID
    }

    private init(
        providers: [RuntimeProviderDescriptor],
        connections: [RuntimeConnectionRegistration],
        providersByID: [RuntimeAdapterID: RuntimeProviderDescriptor],
        connectionsByID: [ProviderConnectionID: RuntimeConnectionRegistration]
    ) {
        self.providers = providers
        self.connections = connections
        self.providersByID = providersByID
        self.connectionsByID = connectionsByID
    }

    func resolve(_ connectionID: ProviderConnectionID) throws -> any AgentRuntime {
        guard let registration = connectionsByID[connectionID] else {
            throw RuntimeRegistryError.connectionNotRegistered(connectionID)
        }
        guard let provider = providersByID[registration.adapterID] else {
            throw RuntimeRegistryError.adapterNotRegistered(registration.adapterID)
        }
        return try provider.makeRuntime(for: connectionID)
    }

    /// The production registry intentionally exposes only Codex today. Adding
    /// another descriptor is not enough: it also needs a real adapter and an
    /// explicit connection binding.
    static let codexOnly: Self = {
        let provider = RuntimeProviderDescriptor.codexAppServer
        let connection = RuntimeConnectionRegistration(
            id: .codexDefault,
            adapterID: .codexAppServer
        )
        return Self(
            providers: [provider],
            connections: [connection],
            providersByID: [provider.id: provider],
            connectionsByID: [connection.id: connection]
        )
    }()
}
