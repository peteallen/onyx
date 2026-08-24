import Darwin
import Foundation

struct CodexRuntimeModelProviderBinding: Sendable, Equatable {
    let id: String
    let baseURL: URL
    let apiKey: String
    /// Opaque, non-secret ownership key for this provider configuration's
    /// durable app-server state. Composition derives it from the connection
    /// and conversation scope; endpoint, model, and display names must never
    /// select a state directory.
    let stateIdentifier: String
}

struct CodexRuntimeLaunchConfiguration: Sendable, Equatable {
    static var bundledRuntimePlatformDirectory: String {
        #if arch(arm64)
        "aarch64-apple-darwin"
        #elseif arch(x86_64)
        "x86_64-apple-darwin"
        #else
        #error("Onyx does not have a packaged Codex runtime for this architecture")
        #endif
    }

    static var bundledHelperRelativePath: String {
        "Contents/Helpers/CodexRuntime/\(bundledRuntimePlatformDirectory)/bin/codex-app-server"
    }
    static let defaultArguments = [
        "--listen",
        "stdio://",
        "-c",
        "forced_login_method=\"chatgpt\"",
        "-c",
        "cli_auth_credentials_store=\"file\"",
        "-c",
        "mcp_oauth_credentials_store=\"file\"",
    ]
    static let customProviderAPIKeyEnvironmentKey = "ONYX_CODEX_CUSTOM_PROVIDER_API_KEY"
    /// Production inherits ordinary process settings so tools retain PATH,
    /// SSH-agent access, developer toolchains, locale, proxies, and custom
    /// runtime configuration. It removes every Codex/OpenAI/ChatGPT control by
    /// prefix because the bundled runtime can add new overrides between
    /// releases, plus credential names that do not use those prefixes.
    private static let productionSensitiveEnvironmentKeys: Set<String> = [
        "GH_TOKEN",
        "GH_ENTERPRISE_TOKEN",
        "GITHUB_TOKEN",
        "GITHUB_ENTERPRISE_TOKEN",
        "GITHUB_PERSONAL_ACCESS_TOKEN",
    ]

    let executableURL: URL
    let processArguments: [String]
    let processEnvironment: [String: String]
    let codexHomeURL: URL
    let modelProviderID: String?
    private let stateRootURL: URL

    static func production(
        bundleURL: URL = Bundle.main.bundleURL,
        userApplicationSupportURL: URL? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        modelProvider: CodexRuntimeModelProviderBinding? = nil,
        fileManager: FileManager = .default
    ) throws -> Self {
        let executableURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CodexRuntime", isDirectory: true)
            .appendingPathComponent(bundledRuntimePlatformDirectory, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex-app-server", isDirectory: false)
        do {
            try validateExecutable(executableURL, fileManager: fileManager)
        } catch {
            throw AgentRuntimeError.bundledRuntimeUnavailable
        }

        let applicationSupportURL: URL
        if let userApplicationSupportURL {
            applicationSupportURL = userApplicationSupportURL
        } else {
            guard let resolved = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw AgentRuntimeError.runtimeStateUnavailable(
                    "Onyx could not locate your Application Support folder."
                )
            }
            applicationSupportURL = resolved
        }

        let stateRootURL = applicationSupportURL.resolvingSymlinksInPath().standardizedFileURL
        return try make(
            executableURL: executableURL,
            baseCodexHomeURL: stateRootURL
                .appendingPathComponent("Onyx", isDirectory: true)
                .appendingPathComponent("Codex", isDirectory: true),
            stateRootURL: stateRootURL,
            inheritedEnvironment: inheritedEnvironment,
            fileManager: fileManager,
            usesStandaloneServerBinary: true,
            scrubProductionCredentials: true,
            modelProvider: modelProvider
        )
    }

    /// Explicitly opts tests and developer tools into an installed Codex
    /// runtime. Production composition never calls this resolver and never
    /// honors `ONYX_CODEX_PATH`.
    static func developmentInstalled(
        explicitExecutableURL: URL? = nil,
        codexHomeURL: URL? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        modelProvider: CodexRuntimeModelProviderBinding? = nil
    ) throws -> Self {
        let executableURL: URL
        if let explicitExecutableURL {
            executableURL = try validateDevelopmentExecutable(
                explicitExecutableURL,
                fileManager: fileManager
            )
        } else if let override = inheritedEnvironment["ONYX_CODEX_PATH"], !override.isEmpty {
            executableURL = try validateDevelopmentExecutable(
                URL(fileURLWithPath: override),
                fileManager: fileManager
            )
            // A requested override is authoritative. If it is damaged, fail
            // instead of silently connecting to another installed runtime.
        } else {
            let installedCandidates = [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ].map(URL.init(fileURLWithPath:))
            guard let installed = installedCandidates.compactMap({ candidate in
                try? validateDevelopmentExecutable(candidate, fileManager: fileManager)
            }).first else {
                throw AgentRuntimeError.developmentExecutableNotFound
            }
            executableURL = installed
        }

        let homeURL: URL
        let stateRootURL: URL
        if let codexHomeURL {
            stateRootURL = codexHomeURL.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
            homeURL = stateRootURL.appendingPathComponent(
                codexHomeURL.lastPathComponent,
                isDirectory: true
            )
        } else {
            guard let applicationSupportURL = applicationSupportURL ?? fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw AgentRuntimeError.runtimeStateUnavailable(
                    "Onyx could not locate your Application Support folder."
                )
            }
            stateRootURL = applicationSupportURL.resolvingSymlinksInPath().standardizedFileURL
            homeURL = stateRootURL
                .appendingPathComponent("Onyx", isDirectory: true)
                .appendingPathComponent("Codex-Development", isDirectory: true)
        }
        return try make(
            executableURL: executableURL,
            baseCodexHomeURL: homeURL,
            stateRootURL: stateRootURL,
            inheritedEnvironment: inheritedEnvironment,
            fileManager: fileManager,
            usesStandaloneServerBinary: executableURL.lastPathComponent == "codex-app-server",
            scrubProductionCredentials: false,
            modelProvider: modelProvider
        )
    }

    func prepareStateDirectory(fileManager: FileManager = .default) throws {
        let relativePath = String(codexHomeURL.path.dropFirst(stateRootURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var cursor = stateRootURL
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            try createPrivateDirectoryIfNeeded(cursor, fileManager: fileManager)
        }
    }

    private static func make(
        executableURL: URL,
        baseCodexHomeURL: URL,
        stateRootURL: URL,
        inheritedEnvironment: [String: String],
        fileManager: FileManager,
        usesStandaloneServerBinary: Bool,
        scrubProductionCredentials: Bool,
        modelProvider: CodexRuntimeModelProviderBinding?
    ) throws -> Self {
        let codexHomeURL: URL
        if let modelProvider {
            try validateProviderID(modelProvider.id)
            try validateProviderStateIdentifier(modelProvider.stateIdentifier)
            codexHomeURL = baseCodexHomeURL
                .appendingPathComponent("Providers", isDirectory: true)
                .appendingPathComponent(modelProvider.stateIdentifier, isDirectory: true)
        } else {
            codexHomeURL = baseCodexHomeURL
        }
        try validateStatePath(codexHomeURL, below: stateRootURL)
        let standardizedHome = codexHomeURL.standardizedFileURL
        var environment = inheritedEnvironment
        if scrubProductionCredentials {
            environment = environment.filter { key, _ in
                !key.hasPrefix("CODEX_") &&
                    !key.hasPrefix("OPENAI_") &&
                    !key.hasPrefix("CHATGPT_") &&
                    !Self.productionSensitiveEnvironmentKeys.contains(key)
            }
            environment["HOME"] = NSHomeDirectory()
        }
        environment.removeValue(forKey: "CODEX_SQLITE_HOME")
        environment.removeValue(forKey: "CODEX_ROLLOUT_TRACE_ROOT")
        environment.removeValue(forKey: "ONYX_CODEX_PATH")
        environment.removeValue(forKey: customProviderAPIKeyEnvironmentKey)
        environment["CODEX_HOME"] = standardizedHome.path
        var arguments = usesStandaloneServerBinary
            ? defaultArguments
            : ["app-server"] + defaultArguments
        if let modelProvider {
            environment[customProviderAPIKeyEnvironmentKey] = modelProvider.apiKey
            arguments += customProviderArguments(modelProvider)
        }
        return Self(
            executableURL: executableURL.standardizedFileURL,
            processArguments: arguments,
            processEnvironment: environment,
            codexHomeURL: standardizedHome,
            modelProviderID: modelProvider?.id,
            stateRootURL: stateRootURL.standardizedFileURL
        )
    }

    private static func customProviderArguments(
        _ provider: CodexRuntimeModelProviderBinding
    ) -> [String] {
        // codex-app-server 0.149.0's command-line override parser accepts
        // bare dotted-path components here, but treats a TOML-quoted segment
        // as a different key. `validateProviderID` keeps this interpolation
        // within TOML's bare-key grammar.
        let prefix = "model_providers.\(provider.id)"
        return [
            "-c", "\(prefix).name=\(tomlQuoted("Onyx Custom Provider"))",
            "-c", "\(prefix).base_url=\(tomlQuoted(provider.baseURL.absoluteString))",
            "-c", "\(prefix).env_key=\(tomlQuoted(customProviderAPIKeyEnvironmentKey))",
            "-c", "\(prefix).wire_api=\(tomlQuoted("responses"))",
            "-c", "\(prefix).requires_openai_auth=false",
            // A retry after app-server has emitted visible partial output
            // creates another durable assistant item. Fail once and let Onyx
            // offer an explicit retry instead of silently duplicating a turn.
            "-c", "\(prefix).stream_max_retries=0",
        ]
    }

    private static func validateProviderID(_ identifier: String) throws {
        guard isBoundedBareKey(identifier) else {
            throw AgentRuntimeError.runtimeStateUnavailable(
                "Onyx rejected an invalid custom-provider identifier."
            )
        }
    }

    private static func validateProviderStateIdentifier(_ identifier: String) throws {
        guard isBoundedBareKey(identifier) else {
            throw AgentRuntimeError.runtimeStateUnavailable(
                "Onyx rejected an invalid custom-provider state identifier."
            )
        }
    }

    private static func isBoundedBareKey(_ identifier: String) -> Bool {
        let isSafeByte: (UInt8) -> Bool = { byte in
            switch byte {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, 0x2D, 0x5F:
                true
            default:
                false
            }
        }
        return !identifier.isEmpty
            && identifier.utf8.count <= 128
            && identifier.utf8.allSatisfy(isSafeByte)
    }

    private static func tomlQuoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F, 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    private static func validateExecutable(
        _ executableURL: URL,
        fileManager: FileManager
    ) throws {
        let path = executableURL.path
        let values: URLResourceValues
        do {
            values = try executableURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw AgentRuntimeError.invalidCodexExecutable(path)
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: path) else {
            throw AgentRuntimeError.invalidCodexExecutable(path)
        }
    }

    private static func validateDevelopmentExecutable(
        _ executableURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let path = executableURL.path
        guard fileManager.fileExists(atPath: path) else {
            throw AgentRuntimeError.invalidCodexExecutable(path)
        }
        let resolved = executableURL.resolvingSymlinksInPath().standardizedFileURL
        try validateExecutable(resolved, fileManager: fileManager)
        return resolved
    }

    private static func validateStatePath(
        _ url: URL,
        below stateRootURL: URL
    ) throws {
        // Both URLs were normalized together when the configuration was
        // created. Do not re-standardize them after partially creating the
        // path: macOS can change `/private/tmp` to `/tmp` once an ancestor
        // exists, which would make two identical stored roots compare as if
        // the state directory had escaped between the two mkdir steps.
        let rootPath = stateRootURL.path
        let statePath = url.path
        guard statePath != rootPath,
              statePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw AgentRuntimeError.runtimeStateUnavailable(
                "Onyx's private Codex data path escaped its Application Support folder."
            )
        }

        let relativePath = String(statePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var cursor = stateRootURL
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            var componentStat = stat()
            let componentResult = cursor.path.withCString { lstat($0, &componentStat) }
            if componentResult == 0 {
                guard (componentStat.st_mode & S_IFMT) == S_IFDIR else {
                    throw AgentRuntimeError.runtimeStateUnavailable(
                        "Onyx's private Codex data path cannot contain a file or symbolic link."
                    )
                }
            } else if errno != ENOENT {
                throw AgentRuntimeError.runtimeStateUnavailable(
                    "Onyx could not inspect its private Codex data path."
                )
            }
        }
    }

    private func createPrivateDirectoryIfNeeded(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try Self.validateStatePath(url, below: stateRootURL)
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw AgentRuntimeError.runtimeStateUnavailable(
                "Onyx could not prepare its private Codex data folder."
            )
        }
        try Self.validateStatePath(url, below: stateRootURL)
    }
}
