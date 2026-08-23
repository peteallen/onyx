import Darwin
import Foundation
import XCTest
@testable import Onyx

final class CodexBundledRuntimeLiveTests: XCTestCase {
    func testPackagedRuntimeStartsSignedOutInAnIsolatedHomeWhenEnabled() async throws {
        guard let appPath = ProcessInfo.processInfo.environment["ONYX_BUNDLED_CODEX_APP_PATH"],
              !appPath.isEmpty else {
            throw XCTSkip(
                "Set ONYX_BUNDLED_CODEX_APP_PATH to exercise a packaged Onyx runtime."
            )
        }

        let fileManager = FileManager.default
        let fixtureRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "OnyxBundledRuntimeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let applicationSupport = fixtureRoot.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let inheritedCodexHome = fixtureRoot.appendingPathComponent(
            "Official Codex",
            isDirectory: true
        )
        let inheritedSQLiteHome = fixtureRoot.appendingPathComponent(
            "Official SQLite",
            isDirectory: true
        )
        let inheritedRolloutRoot = fixtureRoot.appendingPathComponent(
            "Official Rollouts",
            isDirectory: true
        )
        try fileManager.createDirectory(at: inheritedCodexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inheritedSQLiteHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inheritedRolloutRoot, withIntermediateDirectories: true)
        for directory in [inheritedCodexHome, inheritedSQLiteHome, inheritedRolloutRoot] {
            try Data("unchanged\n".utf8).write(to: directory.appendingPathComponent("sentinel"))
        }
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let configuration = try CodexRuntimeLaunchConfiguration.production(
            bundleURL: URL(fileURLWithPath: appPath, isDirectory: true),
            userApplicationSupportURL: applicationSupport,
            inheritedEnvironment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "CODEX_HOME": inheritedCodexHome.path,
                "CODEX_SQLITE_HOME": inheritedSQLiteHome.path,
                "CODEX_ROLLOUT_TRACE_ROOT": inheritedRolloutRoot.path,
                "CODEX_ACCESS_TOKEN": "must-not-reach-packaged-runtime",
                "OPENAI_API_KEY": "must-not-reach-packaged-runtime",
            ]
        )

        let runtime = CodexRuntime(launchConfiguration: configuration)

        do {
            let session = try await runtime.connect()
            let activeThreads = try await runtime.listThreads(limit: 20, archived: false)
            let archivedThreads = try await runtime.listThreads(limit: 20, archived: true)
            await runtime.disconnect()

            XCTAssertEqual(session.runtime, .codex)
            XCTAssertTrue(session.auth.requiresAuthentication)
            XCTAssertFalse(session.auth.isSignedIn)
            XCTAssertTrue(activeThreads.isEmpty)
            XCTAssertTrue(archivedThreads.isEmpty)
        } catch {
            await runtime.disconnect()
            throw error
        }

        XCTAssertEqual(permissions(at: configuration.codexHomeURL), 0o700)
        for directory in [inheritedCodexHome, inheritedSQLiteHome, inheritedRolloutRoot] {
            XCTAssertEqual(
                try fileManager.contentsOfDirectory(atPath: directory.path),
                ["sentinel"],
                "The packaged runtime touched inherited Codex state at \(directory.path)."
            )
        }
    }

    private func permissions(at url: URL) -> Int {
        var information = stat()
        XCTAssertEqual(lstat(url.path, &information), 0)
        return Int(information.st_mode & 0o777)
    }
}
