import Darwin
import Foundation

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
    private let stateRootURL: URL

    static func production(
        bundleURL: URL = Bundle.main.bundleURL,
        userApplicationSupportURL: URL? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
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
            codexHomeURL: stateRootURL
                .appendingPathComponent("Onyx", isDirectory: true)
                .appendingPathComponent("Codex", isDirectory: true),
            stateRootURL: stateRootURL,
            inheritedEnvironment: inheritedEnvironment,
            fileManager: fileManager,
            usesStandaloneServerBinary: true,
            scrubProductionCredentials: true
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
        applicationSupportURL: URL? = nil
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
            codexHomeURL: homeURL,
            stateRootURL: stateRootURL,
            inheritedEnvironment: inheritedEnvironment,
            fileManager: fileManager,
            usesStandaloneServerBinary: executableURL.lastPathComponent == "codex-app-server",
            scrubProductionCredentials: false
        )
    }

    func prepareStateDirectory(fileManager: FileManager = .default) throws {
        let parentURL = codexHomeURL.deletingLastPathComponent()
        if parentURL != stateRootURL {
            try createPrivateDirectoryIfNeeded(parentURL, fileManager: fileManager)
        }
        try createPrivateDirectoryIfNeeded(codexHomeURL, fileManager: fileManager)
    }

    private static func make(
        executableURL: URL,
        codexHomeURL: URL,
        stateRootURL: URL,
        inheritedEnvironment: [String: String],
        fileManager: FileManager,
        usesStandaloneServerBinary: Bool,
        scrubProductionCredentials: Bool
    ) throws -> Self {
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
        environment["CODEX_HOME"] = standardizedHome.path
        return Self(
            executableURL: executableURL.standardizedFileURL,
            processArguments: usesStandaloneServerBinary
                ? defaultArguments
                : ["app-server"] + defaultArguments,
            processEnvironment: environment,
            codexHomeURL: standardizedHome,
            stateRootURL: stateRootURL.standardizedFileURL
        )
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
