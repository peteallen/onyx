import Darwin
import Foundation
import XCTest
@testable import Onyx

final class CodexRuntimeLaunchConfigurationTests: XCTestCase {
    func testProductionUsesOnlyBundledStandaloneServerAndPrivateCodexHome() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let helper = try fixture.installHelper()
        let installedOverride = try fixture.installExecutable(named: "external-codex")

        let configuration = try CodexRuntimeLaunchConfiguration.production(
            bundleURL: fixture.bundleURL,
            userApplicationSupportURL: fixture.applicationSupportURL,
            inheritedEnvironment: [
                "PATH": "/usr/bin",
                "CODEX_HOME": "/Users/example/.codex",
                "CODEX_SQLITE_HOME": "/tmp/escaped-sqlite",
                "CODEX_ROLLOUT_TRACE_ROOT": "/tmp/escaped-rollouts",
                "ONYX_CODEX_PATH": installedOverride.path,
                "OPENAI_API_KEY": "must-not-reach-onyx",
                "CODEX_AUTH": "must-not-reach-onyx",
                "CODEX_URL": "https://redirect.invalid",
                "CODEX_APP_SERVER_CHATGPT_BASE_URL": "https://redirect.invalid",
                "CODEX_APP_SERVER_LOGIN_CLIENT_ID": "redirected-client",
                "CODEX_AUTHAPI_BASE_URL": "https://redirect.invalid",
                "CODEX_REFRESH_TOKEN_URL_OVERRIDE": "https://redirect.invalid",
                "CODEX_REVOKE_TOKEN_URL_OVERRIDE": "https://redirect.invalid",
                "CODEX_GITHUB_PERSONAL_ACCESS_TOKEN": "must-not-reach-onyx",
                "GH_TOKEN": "must-not-reach-onyx",
                "GITHUB_TOKEN": "must-not-reach-onyx",
                "CODEX_ACCESS_TOKEN": "must-not-reach-onyx",
                "CODEX_CONNECTORS_TOKEN": "must-not-reach-onyx",
                "CODEX_AGENT_IDENTITY_AUTHAPI_BASE_URL": "https://redirect.invalid",
                "CODEX_AGENT_IDENTITY_JWKS_BASE_URL": "https://redirect.invalid",
                "OPENAI_BASE_URL": "https://redirect.invalid",
                "OPENAI_IDENTITY_TOKEN_FILE": "/tmp/identity-token",
                "OPENAI_WORKLOAD_IDENTITY_CONTEXT": "redirected-context",
                "OPENAI_FEDERATION_RULE_ID": "redirected-rule",
                "GITHUB_PERSONAL_ACCESS_TOKEN": "must-not-reach-onyx",
                "GH_ENTERPRISE_TOKEN": "must-not-reach-onyx",
                "GITHUB_ENTERPRISE_TOKEN": "must-not-reach-onyx",
                "CHATGPT_INTERNAL_ORIGIN": "must-not-reach-onyx",
                "SHELL": "/bin/zsh",
                "USER": "example",
                "LOGNAME": "example",
                "TMPDIR": "/private/tmp/example/",
                "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
                "DEVELOPER_DIR": "/Applications/Xcode.app",
                "SDKROOT": "/Applications/Xcode.app/SDKs/MacOSX.sdk",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "HTTPS_PROXY": "http://proxy.example:8080",
                "NO_PROXY": "localhost,127.0.0.1",
                "SSL_CERT_FILE": "/private/tmp/company-ca.pem",
                "CUSTOM_TOOLCHAIN_FLAG": "keep-me",
            ]
        )

        XCTAssertEqual(configuration.executableURL, helper.standardizedFileURL)
        XCTAssertEqual(
            configuration.codexHomeURL,
            fixture.applicationSupportURL
                .appendingPathComponent("Onyx/Codex", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertEqual(configuration.processEnvironment["CODEX_HOME"], configuration.codexHomeURL.path)
        XCTAssertNil(configuration.processEnvironment["CODEX_SQLITE_HOME"])
        XCTAssertNil(configuration.processEnvironment["CODEX_ROLLOUT_TRACE_ROOT"])
        XCTAssertNil(configuration.processEnvironment["ONYX_CODEX_PATH"])
        XCTAssertNil(configuration.processEnvironment["OPENAI_API_KEY"])
        XCTAssertNil(configuration.processEnvironment["CODEX_AUTH"])
        XCTAssertNil(configuration.processEnvironment["CODEX_URL"])
        XCTAssertNil(configuration.processEnvironment["CODEX_APP_SERVER_CHATGPT_BASE_URL"])
        XCTAssertNil(configuration.processEnvironment["CODEX_APP_SERVER_LOGIN_CLIENT_ID"])
        XCTAssertNil(configuration.processEnvironment["CODEX_AUTHAPI_BASE_URL"])
        XCTAssertNil(configuration.processEnvironment["CODEX_REFRESH_TOKEN_URL_OVERRIDE"])
        XCTAssertNil(configuration.processEnvironment["CODEX_REVOKE_TOKEN_URL_OVERRIDE"])
        XCTAssertNil(configuration.processEnvironment["CODEX_GITHUB_PERSONAL_ACCESS_TOKEN"])
        XCTAssertNil(configuration.processEnvironment["GH_TOKEN"])
        XCTAssertNil(configuration.processEnvironment["GITHUB_TOKEN"])
        XCTAssertNil(configuration.processEnvironment["CODEX_ACCESS_TOKEN"])
        XCTAssertNil(configuration.processEnvironment["CODEX_CONNECTORS_TOKEN"])
        XCTAssertNil(configuration.processEnvironment["CODEX_AGENT_IDENTITY_AUTHAPI_BASE_URL"])
        XCTAssertNil(configuration.processEnvironment["CODEX_AGENT_IDENTITY_JWKS_BASE_URL"])
        XCTAssertNil(configuration.processEnvironment["OPENAI_BASE_URL"])
        XCTAssertNil(configuration.processEnvironment["OPENAI_IDENTITY_TOKEN_FILE"])
        XCTAssertNil(configuration.processEnvironment["OPENAI_WORKLOAD_IDENTITY_CONTEXT"])
        XCTAssertNil(configuration.processEnvironment["OPENAI_FEDERATION_RULE_ID"])
        XCTAssertNil(configuration.processEnvironment["GITHUB_PERSONAL_ACCESS_TOKEN"])
        XCTAssertNil(configuration.processEnvironment["GH_ENTERPRISE_TOKEN"])
        XCTAssertNil(configuration.processEnvironment["GITHUB_ENTERPRISE_TOKEN"])
        XCTAssertNil(configuration.processEnvironment["CHATGPT_INTERNAL_ORIGIN"])
        XCTAssertEqual(configuration.processEnvironment["SSH_AUTH_SOCK"], "/private/tmp/agent.sock")
        XCTAssertEqual(configuration.processEnvironment["DEVELOPER_DIR"], "/Applications/Xcode.app")
        XCTAssertEqual(configuration.processEnvironment["SDKROOT"], "/Applications/Xcode.app/SDKs/MacOSX.sdk")
        XCTAssertEqual(configuration.processEnvironment["SSL_CERT_FILE"], "/private/tmp/company-ca.pem")
        XCTAssertEqual(configuration.processEnvironment["CUSTOM_TOOLCHAIN_FLAG"], "keep-me")
        XCTAssertEqual(configuration.processEnvironment["PATH"], "/usr/bin")
        XCTAssertEqual(configuration.processEnvironment["SHELL"], "/bin/zsh")
        XCTAssertEqual(configuration.processEnvironment["USER"], "example")
        XCTAssertEqual(configuration.processEnvironment["LOGNAME"], "example")
        XCTAssertEqual(configuration.processEnvironment["TMPDIR"], "/private/tmp/example/")
        XCTAssertEqual(configuration.processEnvironment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(configuration.processEnvironment["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(configuration.processEnvironment["HTTPS_PROXY"], "http://proxy.example:8080")
        XCTAssertEqual(configuration.processEnvironment["NO_PROXY"], "localhost,127.0.0.1")
        XCTAssertEqual(configuration.processEnvironment["HOME"], NSHomeDirectory())
        XCTAssertEqual(
            Set(configuration.processEnvironment.keys),
            [
                "PATH", "SHELL", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL",
                "HTTPS_PROXY", "NO_PROXY", "HOME", "CODEX_HOME",
                "SSH_AUTH_SOCK", "DEVELOPER_DIR", "SDKROOT", "SSL_CERT_FILE",
                "CUSTOM_TOOLCHAIN_FLAG",
            ]
        )
        XCTAssertEqual(configuration.processArguments.first, "--listen")
        XCTAssertFalse(configuration.processArguments.contains("app-server"))
        XCTAssertTrue(configuration.processArguments.contains("forced_login_method=\"chatgpt\""))
        XCTAssertTrue(configuration.processArguments.contains("cli_auth_credentials_store=\"file\""))
        XCTAssertTrue(configuration.processArguments.contains("mcp_oauth_credentials_store=\"file\""))
    }

    func testProductionNeverFallsBackWhenBundledRuntimeIsMissing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let installedOverride = try fixture.installExecutable(named: "external-codex")

        XCTAssertThrowsError(
            try CodexRuntimeLaunchConfiguration.production(
                bundleURL: fixture.bundleURL,
                userApplicationSupportURL: fixture.applicationSupportURL,
                inheritedEnvironment: ["ONYX_CODEX_PATH": installedOverride.path]
            )
        ) { error in
            guard case AgentRuntimeError.bundledRuntimeUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testProductionRejectsSymlinkedAndNonExecutableHelpers() throws {
        for damagedKind in DamagedHelperKind.allCases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try fixture.installDamagedHelper(damagedKind)

            XCTAssertThrowsError(
                try CodexRuntimeLaunchConfiguration.production(
                    bundleURL: fixture.bundleURL,
                    userApplicationSupportURL: fixture.applicationSupportURL
                ),
                "Expected rejection for \(damagedKind)"
            ) { error in
                guard case AgentRuntimeError.bundledRuntimeUnavailable = error else {
                    return XCTFail("Unexpected error for \(damagedKind): \(error)")
                }
            }
        }
    }

    func testDevelopmentOverrideIsExplicitAndFailsInsteadOfFallingThrough() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let explicit = try fixture.installExecutable(named: "developer-codex")
        let home = fixture.root.appendingPathComponent("DevelopmentHome", isDirectory: true)

        let configuration = try CodexRuntimeLaunchConfiguration.developmentInstalled(
            explicitExecutableURL: explicit,
            codexHomeURL: home,
            inheritedEnvironment: ["CODEX_HOME": "/Users/example/.codex"]
        )
        XCTAssertEqual(configuration.executableURL, explicit.standardizedFileURL)
        XCTAssertEqual(configuration.processArguments.first, "app-server")
        XCTAssertEqual(configuration.processEnvironment["CODEX_HOME"], home.path)

        let missing = fixture.root.appendingPathComponent("missing-codex")
        XCTAssertThrowsError(
            try CodexRuntimeLaunchConfiguration.developmentInstalled(
                explicitExecutableURL: missing,
                codexHomeURL: home
            )
        ) { error in
            guard case let AgentRuntimeError.invalidCodexExecutable(path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    func testDevelopmentEnvironmentOverrideIsOptInAndAuthoritative() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let override = try fixture.installExecutable(named: "environment-codex")
        let home = fixture.root.appendingPathComponent("EnvironmentHome", isDirectory: true)

        let configuration = try CodexRuntimeLaunchConfiguration.developmentInstalled(
            codexHomeURL: home,
            inheritedEnvironment: ["ONYX_CODEX_PATH": override.path]
        )
        XCTAssertEqual(configuration.executableURL, override.standardizedFileURL)
        XCTAssertNil(configuration.processEnvironment["ONYX_CODEX_PATH"])

        let missing = fixture.root.appendingPathComponent("missing-environment-codex")
        XCTAssertThrowsError(
            try CodexRuntimeLaunchConfiguration.developmentInstalled(
                codexHomeURL: home,
                inheritedEnvironment: ["ONYX_CODEX_PATH": missing.path]
            )
        ) { error in
            guard case let AgentRuntimeError.invalidCodexExecutable(path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    func testDevelopmentResolverAcceptsAnOrdinaryHomebrewSymlink() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let installed = try fixture.installExecutable(named: "Cellar-codex")
        let homebrewLink = fixture.root.appendingPathComponent("homebrew-bin-codex")
        try FileManager.default.createSymbolicLink(at: homebrewLink, withDestinationURL: installed)

        let configuration = try CodexRuntimeLaunchConfiguration.developmentInstalled(
            explicitExecutableURL: homebrewLink,
            codexHomeURL: fixture.root.appendingPathComponent("DevelopmentHome", isDirectory: true)
        )

        XCTAssertEqual(configuration.executableURL, installed.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testPrivateStateDirectoryIsLazySecureAndReusable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.installHelper()
        let configuration = try CodexRuntimeLaunchConfiguration.production(
            bundleURL: fixture.bundleURL,
            userApplicationSupportURL: fixture.applicationSupportURL
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.codexHomeURL.path))

        try configuration.prepareStateDirectory()
        XCTAssertEqual(permissions(at: configuration.codexHomeURL), 0o700)
        try configuration.prepareStateDirectory()
        XCTAssertEqual(permissions(at: configuration.codexHomeURL), 0o700)
    }

    func testPrivateStatePreparationKeepsOneLexicalRootWhileCreatingMissingParents() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("OnyxCodexAliasTests-\(UUID().uuidString)", isDirectory: true)
        let fixture = CodexLaunchFixture(
            root: root,
            bundleURL: root.appendingPathComponent("Onyx.app", isDirectory: true),
            applicationSupportURL: root.appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
        )
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.bundleURL,
            withIntermediateDirectories: true
        )
        _ = try fixture.installHelper()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.applicationSupportURL.path))

        let configuration = try CodexRuntimeLaunchConfiguration.production(
            bundleURL: fixture.bundleURL,
            userApplicationSupportURL: fixture.applicationSupportURL
        )
        try configuration.prepareStateDirectory()
        try configuration.prepareStateDirectory()

        XCTAssertEqual(permissions(at: configuration.codexHomeURL), 0o700)
    }

    func testPrivateStateRejectsFileAndSymlinkBeforeLaunch() throws {
        for damagedKind in [DamagedStateKind.file, .symlink] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            _ = try fixture.installHelper()
            let stateURL = fixture.applicationSupportURL
                .appendingPathComponent("Onyx/Codex", isDirectory: true)
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            switch damagedKind {
            case .file:
                XCTAssertTrue(FileManager.default.createFile(atPath: stateURL.path, contents: Data()))
            case .symlink:
                let target = fixture.root.appendingPathComponent("redirected", isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: target)
            }

            XCTAssertThrowsError(
                try CodexRuntimeLaunchConfiguration.production(
                    bundleURL: fixture.bundleURL,
                    userApplicationSupportURL: fixture.applicationSupportURL
                ),
                "Expected state rejection for \(damagedKind)"
            ) { error in
                guard case AgentRuntimeError.runtimeStateUnavailable = error else {
                    return XCTFail("Unexpected error for \(damagedKind): \(error)")
                }
            }
        }
    }

    func testRealClientReceivesSanitizedEnvironmentAndExactCodexHome() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let environmentCaptureURL = fixture.root.appendingPathComponent("environment.txt")
        let helper = try fixture.installHelper(
            body: """
            #!/bin/zsh
            /usr/bin/printf '%s\n%s\n%s\n' \
              "$CODEX_HOME" "${CODEX_SQLITE_HOME-unset}" "${CODEX_ROLLOUT_TRACE_ROOT-unset}" \
              > "$ONYX_TEST_ENV_CAPTURE"
            while IFS= read -r line; do
              id="$(/bin/echo "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\\1/')"
              case "$line" in
                *'"method":"initialize"'*)
                  /usr/bin/printf '{"id":%s,"result":{"codexHome":"%s"}}\n' "$id" "$CODEX_HOME"
                  ;;
                *'"method":"initialized"'*) ;;
              esac
            done
            """
        )
        let configuration = try CodexRuntimeLaunchConfiguration.developmentInstalled(
            explicitExecutableURL: helper,
            codexHomeURL: fixture.root.appendingPathComponent("PrivateCodex", isDirectory: true),
            inheritedEnvironment: [
                "PATH": "/usr/bin:/bin",
                "CODEX_HOME": "/Users/example/.codex",
                "CODEX_SQLITE_HOME": "/tmp/escaped-sqlite",
                "CODEX_ROLLOUT_TRACE_ROOT": "/tmp/escaped-rollouts",
                "ONYX_TEST_ENV_CAPTURE": environmentCaptureURL.path,
            ]
        )
        let client = CodexAppServerClient(
            executableURL: configuration.executableURL,
            processArguments: configuration.processArguments,
            processEnvironment: configuration.processEnvironment,
            stateDirectoryPreparation: { try configuration.prepareStateDirectory() }
        )
        let connection = try await client.start()
        await client.stop()

        XCTAssertEqual(connection.initializeResponse["codexHome"]?.stringValue, configuration.codexHomeURL.path)
        let environmentLines = try String(contentsOf: environmentCaptureURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(environmentLines, [configuration.codexHomeURL.path, "unset", "unset"])
        XCTAssertEqual(permissions(at: configuration.codexHomeURL), 0o700)
    }

    func testRuntimeFailsClosedWhenServerReportsAnotherCodexHome() async throws {
        let expectedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxExpectedCodex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: expectedHome) }
        let transport = CodexHomeMismatchTransport()
        let runtime = CodexRuntime(client: transport, expectedCodexHomeURL: expectedHome)

        do {
            _ = try await runtime.connect()
            XCTFail("A server attached to another Codex home must not connect")
        } catch let AgentRuntimeError.protocolFailure(message) {
            XCTAssertTrue(message.contains("refused Onyx's private data folder"))
        }
        let stops = await transport.stopCount()
        XCTAssertEqual(stops, 1)
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private actor CodexHomeMismatchTransport: CodexAppServerTransport {
    nonisolated let events: AsyncStream<AppServerEvent> = {
        let stream = AsyncStream.makeStream(of: AppServerEvent.self)
        stream.continuation.finish()
        return stream.stream
    }()

    private var stops = 0

    func start() async throws -> AppServerConnection {
        AppServerConnection(
            generation: 1,
            initializeResponse: .object(["codexHome": .string("/Users/example/.codex")])
        )
    }

    func stop() async { stops += 1 }
    func request(method _: String, params _: JSONValue) async throws -> JSONValue { .object([:]) }
    func respond(id _: RuntimeRequestID, result _: JSONValue) async throws {}
    func stopCount() -> Int { stops }
}

private enum DamagedHelperKind: CaseIterable {
    case directory
    case symlink
    case nonExecutable
}

private enum DamagedStateKind {
    case file
    case symlink
}

private struct CodexLaunchFixture {
    let root: URL
    let bundleURL: URL
    let applicationSupportURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func installHelper(body: String = "#!/bin/zsh\nexit 0\n") throws -> URL {
        let helper = helperURL
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: helper.path,
            contents: Data(body.utf8),
            attributes: [.posixPermissions: 0o755]
        ))
        return helper
    }

    func installExecutable(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: Data("#!/bin/zsh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        ))
        return url
    }

    func installDamagedHelper(_ kind: DamagedHelperKind) throws {
        let helper = helperURL
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        switch kind {
        case .directory:
            try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        case .symlink:
            let target = try installExecutable(named: "symlink-target")
            try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: target)
        case .nonExecutable:
            XCTAssertTrue(FileManager.default.createFile(
                atPath: helper.path,
                contents: Data("not executable".utf8),
                attributes: [.posixPermissions: 0o644]
            ))
        }
    }

    private var helperURL: URL {
        bundleURL.appendingPathComponent(
            CodexRuntimeLaunchConfiguration.bundledHelperRelativePath,
            isDirectory: false
        )
    }
}

private func makeFixture() throws -> CodexLaunchFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OnyxCodexLaunchTests-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("Onyx.app", isDirectory: true)
    let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    return CodexLaunchFixture(
        root: root,
        bundleURL: bundle,
        applicationSupportURL: applicationSupport
    )
}
