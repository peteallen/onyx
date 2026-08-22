import Foundation
import XCTest
@testable import Onyx

final class GitRepositoryReaderTests: XCTestCase {
    func testStatusPreservesSpacesRenameSidesAndUntrackedPaths() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }

        try fixture.write("old\n", to: "folder name/old name.txt")
        try fixture.write("base\n", to: "modified.txt")
        try fixture.commitAll(message: "initial")

        try fixture.git(["mv", "folder name/old name.txt", "folder name/new name.txt"])
        try fixture.append("working\n", to: "folder name/new name.txt")
        try fixture.write("draft\n", to: "untracked name.txt")
        try fixture.write(Data([0, 1, 2, 3]), to: "image data.bin")

        let reader = try GitRepositoryReader()
        let status = try await reader.readStatus(at: fixture.url.path)

        XCTAssertEqual(status.repositoryPath, fixture.url.path)
        XCTAssertFalse(status.branch.name?.isEmpty ?? true)

        let renamed = try XCTUnwrap(status.changes.first { $0.path == "folder name/new name.txt" })
        XCTAssertEqual(renamed.oldPath, "folder name/old name.txt")
        XCTAssertEqual(renamed.indexState, .renamed)
        XCTAssertEqual(renamed.worktreeState, .modified)
        XCTAssertEqual(renamed.kind, .renamed)
        XCTAssertTrue(renamed.isStaged)
        XCTAssertTrue(renamed.isUnstaged)

        let untracked = try XCTUnwrap(status.changes.first { $0.path == "untracked name.txt" })
        XCTAssertEqual(untracked.kind, .untracked)
        XCTAssertFalse(untracked.isStaged)
        XCTAssertTrue(untracked.isUnstaged)
        XCTAssertTrue(untracked.isUntracked)

        XCTAssertTrue(status.changes.contains { $0.path == "image data.bin" && $0.kind == .untracked })
        XCTAssertEqual(status.stagedChanges.map(\.path), ["folder name/new name.txt"])
        XCTAssertEqual(
            Set(status.unstagedChanges.map(\.path)),
            Set(["folder name/new name.txt", "image data.bin", "untracked name.txt"])
        )
    }

    func testSnapshotParsesStagedAndUnstagedHunksWithLineNumbers() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }

        try fixture.write("alpha\nbeta\ngamma\n", to: "notes.txt")
        try fixture.commitAll(message: "initial")

        try fixture.write("alpha\nBETA\ngamma\nstaged\n", to: "notes.txt")
        try fixture.git(["add", "--", "notes.txt"])
        try fixture.write("alpha\nBETA\ngamma\nstaged\nworking\n", to: "notes.txt")
        try fixture.write("first\nsecond", to: "new notes.txt")

        let reader = try GitRepositoryReader()
        let snapshot = try await reader.readSnapshot(at: fixture.url.path)

        let stagedFile = try XCTUnwrap(snapshot.staged.files.first { $0.path == "notes.txt" })
        XCTAssertEqual(stagedFile.kind, .modified)
        XCTAssertFalse(stagedFile.isBinary)
        XCTAssertEqual(stagedFile.additions, 2)
        XCTAssertEqual(stagedFile.deletions, 1)
        let stagedLines = try XCTUnwrap(stagedFile.hunks.first).lines
        XCTAssertTrue(stagedLines.contains {
            $0.kind == .deletion && $0.content == "beta" && $0.oldLineNumber == 2 && $0.newLineNumber == nil
        })
        XCTAssertTrue(stagedLines.contains {
            $0.kind == .addition && $0.content == "BETA" && $0.oldLineNumber == nil && $0.newLineNumber == 2
        })

        let workingFile = try XCTUnwrap(snapshot.unstaged.files.first { $0.path == "notes.txt" })
        XCTAssertEqual(workingFile.additions, 1)
        XCTAssertTrue(workingFile.hunks.flatMap(\.lines).contains {
            $0.kind == .addition && $0.content == "working" && $0.newLineNumber == 5
        })

        let untracked = try XCTUnwrap(snapshot.unstaged.files.first { $0.path == "new notes.txt" })
        XCTAssertEqual(untracked.kind, .untracked)
        XCTAssertFalse(untracked.isBinary)
        XCTAssertEqual(untracked.additions, 2)
        XCTAssertEqual(
            untracked.hunks.flatMap(\.lines).map(\.kind),
            [.addition, .addition, .noNewline]
        )
        XCTAssertEqual(
            untracked.hunks.flatMap(\.lines).compactMap(\.newLineNumber),
            [1, 2]
        )
    }

    func testStagedRenameAndBinaryFilesAreStructuredWithoutTextHunks() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }

        try fixture.write("same\n", to: "old path.txt")
        try fixture.write(Data([0, 1, 2, 3]), to: "asset.bin")
        try fixture.commitAll(message: "initial")

        try fixture.git(["mv", "old path.txt", "new path.txt"])
        try fixture.write(Data([0, 1, 8, 9, 10]), to: "asset.bin")
        try fixture.git(["add", "--", "asset.bin"])

        let reader = try GitRepositoryReader()
        let diff = try await reader.readDiff(at: fixture.url.path, scope: .staged)

        let rename = try XCTUnwrap(diff.files.first { $0.path == "new path.txt" })
        XCTAssertEqual(rename.oldPath, "old path.txt")
        XCTAssertEqual(rename.kind, .renamed)
        XCTAssertTrue(rename.hunks.isEmpty)

        let binary = try XCTUnwrap(diff.files.first { $0.path == "asset.bin" })
        XCTAssertTrue(binary.isBinary)
        XCTAssertTrue(binary.hunks.isEmpty)
        XCTAssertTrue(binary.metadata.contains { $0 == "GIT binary patch" || $0.hasPrefix("Binary files ") })
    }

    func testLargeUntrackedFileIsNotLoadedIntoTranscriptModels() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        try fixture.commitAll(message: "empty initial")
        try fixture.write(Data(repeating: UInt8(ascii: "a"), count: 64), to: "large.txt")

        let reader = try GitRepositoryReader(
            executor: LocalGitCommandExecutor(),
            configuration: .init(
                timeout: 5,
                outputLimit: 1_048_576,
                maxUntrackedFileBytes: 16,
                unifiedContextLines: 3
            )
        )
        let diff = try await reader.readDiff(at: fixture.url.path, scope: .unstaged)
        let file = try XCTUnwrap(diff.files.first { $0.path == "large.txt" })

        XCTAssertTrue(file.isBinary)
        XCTAssertTrue(file.hunks.isEmpty)
        XCTAssertEqual(file.metadata, ["Untracked file is larger than the preview limit."])
    }

    func testNonRepositoryReturnsSpecificError() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxGitNonRepository \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try GitRepositoryReader()
        do {
            _ = try await reader.readStatus(at: url.path)
            XCTFail("Expected a not-repository error")
        } catch let error as GitRepositoryError {
            XCTAssertEqual(error, .notRepository(url.path))
        }
    }

    func testCommandUsesExplicitGitCPathWithoutShellQuoting() async throws {
        let fixture = try GitRepositoryFixture(pathSuffix: "path; with $ shell chars")
        defer { fixture.remove() }
        try fixture.commitAll(message: "initial")

        let executor = try LocalGitCommandExecutor()
        let result = try await executor.execute(
            arguments: ["status", "--porcelain=v1", "-z"],
            repositoryURL: fixture.url,
            timeout: 5,
            outputLimit: 1024
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.standardOutput.isEmpty)
    }

    func testCommandTimeoutAndOutputLimitAreEnforced() async throws {
        let repositoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let timeoutScript = try TemporaryExecutableScript(contents: "#!/bin/sh\nexec /bin/sleep 1\n")
        defer { timeoutScript.remove() }
        let timeoutExecutor = LocalGitCommandExecutor(uncheckedExecutableURL: timeoutScript.url)
        do {
            _ = try await timeoutExecutor.execute(
                arguments: ["1"],
                repositoryURL: repositoryURL,
                timeout: 0.01,
                outputLimit: 1024
            )
            XCTFail("Expected timeout")
        } catch let error as GitRepositoryError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }

        let outputScript = try TemporaryExecutableScript(contents: "#!/bin/sh\nexec /usr/bin/yes\n")
        defer { outputScript.remove() }
        let outputExecutor = LocalGitCommandExecutor(uncheckedExecutableURL: outputScript.url)
        do {
            _ = try await outputExecutor.execute(
                arguments: [],
                repositoryURL: repositoryURL,
                timeout: 1,
                outputLimit: 64
            )
            XCTFail("Expected output limit")
        } catch let error as GitRepositoryError {
            XCTAssertEqual(error, .outputLimitExceeded(arguments: [], limit: 64))
        }
    }

    func testStageUnstageAndDiscardPreserveExpectedVersions() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }

        try fixture.write("base\n", to: "notes.txt")
        try fixture.commitAll(message: "initial")
        try fixture.write("staged\n", to: "notes.txt")
        try fixture.git(["add", "--", "notes.txt"])
        try fixture.write("staged\nworking\n", to: "notes.txt")

        let recovery = try TestGitFileRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.url) }
        let reader = try GitRepositoryReader(fileRecovery: recovery)
        let target = GitFileActionTarget(path: "notes.txt", kind: .modified)

        try await reader.perform(.discard, on: target, at: fixture.url.path)
        XCTAssertEqual(try fixture.read("notes.txt"), "staged\n")
        XCTAssertEqual(try fixture.git(["diff", "--cached", "--", "notes.txt"]), "diff --git a/notes.txt b/notes.txt\nindex df967b9..19d9cc8 100644\n--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-base\n+staged\n")

        try fixture.write("staged\nworking again\n", to: "notes.txt")
        let workingBytes = try Data(contentsOf: fixture.url.appendingPathComponent("notes.txt"))
        try await reader.perform(.unstage, on: target, at: fixture.url.path)
        XCTAssertEqual(try Data(contentsOf: fixture.url.appendingPathComponent("notes.txt")), workingBytes)
        let status = try await reader.readStatus(at: fixture.url.path)
        let change = try XCTUnwrap(status.changes.first { $0.path == "notes.txt" })
        XCTAssertFalse(change.isStaged)
        XCTAssertTrue(change.isUnstaged)
    }

    func testUntrackedStageUnstageAndRecoverableDiscard() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        try fixture.commitAll(message: "initial")
        try fixture.write("draft\n", to: "new file.txt")
        let originalBytes = try Data(contentsOf: fixture.url.appendingPathComponent("new file.txt"))

        let recovery = try TestGitFileRecovery()
        defer { try? FileManager.default.removeItem(at: recovery.url) }
        let reader = try GitRepositoryReader(fileRecovery: recovery)
        let target = GitFileActionTarget(path: "new file.txt", kind: .untracked)

        try await reader.perform(.stage, on: target, at: fixture.url.path)
        XCTAssertEqual(try Data(contentsOf: fixture.url.appendingPathComponent("new file.txt")), originalBytes)
        let stagedStatus = try await reader.readStatus(at: fixture.url.path)
        XCTAssertTrue(stagedStatus.changes.first { $0.path == "new file.txt" }?.isStaged == true)

        try await reader.perform(.unstage, on: target, at: fixture.url.path)
        XCTAssertEqual(try Data(contentsOf: fixture.url.appendingPathComponent("new file.txt")), originalBytes)
        let unstagedStatus = try await reader.readStatus(at: fixture.url.path)
        XCTAssertTrue(unstagedStatus.changes.first { $0.path == "new file.txt" }?.isUntracked == true)

        try await reader.perform(.discard, on: target, at: fixture.url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("new file.txt").path))
        let recoveredBytes = try await recovery.recoveredData(named: "new file.txt")
        XCTAssertEqual(recoveredBytes, originalBytes)
    }

    func testUnbornRepositoryCanUnstageWithoutResolvingHead() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        try fixture.write("first\n", to: "first.txt")

        let reader = try GitRepositoryReader()
        let target = GitFileActionTarget(path: "first.txt", kind: .untracked)
        try await reader.perform(.stage, on: target, at: fixture.url.path)
        try await reader.perform(.unstage, on: target, at: fixture.url.path)

        XCTAssertEqual(try fixture.read("first.txt"), "first\n")
        let status = try await reader.readStatus(at: fixture.url.path)
        XCTAssertTrue(status.changes.first { $0.path == "first.txt" }?.isUntracked == true)
    }

    func testLiteralPathspecPreventsMagicFilenameFromTouchingNeighbor() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        try fixture.commitAll(message: "initial")
        try fixture.write("magic\n", to: ":(glob)**")
        try fixture.write("sentinel\n", to: "sentinel.txt")

        let reader = try GitRepositoryReader()
        try await reader.perform(
            .stage,
            on: GitFileActionTarget(path: ":(glob)**", kind: .untracked),
            at: fixture.url.path
        )

        let status = try await reader.readStatus(at: fixture.url.path)
        XCTAssertTrue(status.changes.first { $0.path == ":(glob)**" }?.isStaged == true)
        XCTAssertTrue(status.changes.first { $0.path == "sentinel.txt" }?.isUntracked == true)
    }

    func testMutationCommandsUseLiteralBoundedArgumentsAndCorrectRenameSides() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Onyx Git Command Spy \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        let executor = RecordingGitCommandExecutor(statusOutput: Data("R  new name.txt\0old name.txt\0".utf8))
        let reader = GitRepositoryReader(executor: executor)
        try await reader.perform(
            .unstage,
            on: GitFileActionTarget(path: "new name.txt", oldPath: "old name.txt", kind: .renamed),
            at: repositoryURL.path
        )

        let invocations = executor.invocations
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(
            invocations[1].arguments,
            ["--literal-pathspecs", "reset", "--quiet", "--", "new name.txt", "old name.txt"]
        )
        XCTAssertEqual(invocations[1].timeout, GitRepositoryReader.Configuration.default.timeout)
        XCTAssertEqual(invocations[1].outputLimit, GitRepositoryReader.Configuration.default.outputLimit)

        let copied = GitFileActionTarget(path: "copy.txt", oldPath: "source.txt", kind: .copied)
        XCTAssertEqual(copied.pathspecs, ["copy.txt"])
    }

    func testConflictIsRejectedBeforeMutation() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.remove() }
        try fixture.write("base\n", to: "conflict.txt")
        try fixture.commitAll(message: "base")
        let mainBranch = try fixture.git(["branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["checkout", "--quiet", "-b", "other"])
        try fixture.write("other\n", to: "conflict.txt")
        try fixture.commitAll(message: "other")
        try fixture.git(["checkout", "--quiet", mainBranch])
        try fixture.write("master\n", to: "conflict.txt")
        try fixture.commitAll(message: "master")
        _ = try? fixture.git(["merge", "other"])

        let before = try Data(contentsOf: fixture.url.appendingPathComponent("conflict.txt"))
        let reader = try GitRepositoryReader()
        do {
            try await reader.perform(
                .stage,
                on: GitFileActionTarget(path: "conflict.txt", kind: .unmerged),
                at: fixture.url.path
            )
            XCTFail("Expected conflict rejection")
        } catch let error as GitRepositoryError {
            XCTAssertEqual(error, .conflictedChange("conflict.txt"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url.appendingPathComponent("conflict.txt")), before)
        let status = try await reader.readStatus(at: fixture.url.path)
        XCTAssertTrue(status.changes.first { $0.path == "conflict.txt" }?.isConflict == true)
    }
}

private final class RecordingGitCommandExecutor: GitCommandExecuting, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        let arguments: [String]
        let repositoryURL: URL
        let timeout: TimeInterval
        let outputLimit: Int
    }

    private let lock = NSLock()
    private let statusOutput: Data
    private var recordedInvocations: [Invocation] = []

    init(statusOutput: Data) {
        self.statusOutput = statusOutput
    }

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    func execute(
        arguments: [String],
        repositoryURL: URL,
        timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> GitCommandResult {
        lock.withLock {
            recordedInvocations.append(
                Invocation(
                    arguments: arguments,
                    repositoryURL: repositoryURL,
                    timeout: timeout,
                    outputLimit: outputLimit
                )
            )
        }
        if arguments.first == "status" {
            return GitCommandResult(standardOutput: statusOutput)
        }
        return GitCommandResult()
    }
}

private struct TemporaryExecutableScript {
    let url: URL

    init(contents: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxGitCommandTest-\(UUID().uuidString).sh")
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct GitRepositoryFixture {
    let url: URL

    init(pathSuffix: String = UUID().uuidString) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Onyx Git Tests \(pathSuffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try git(["init", "--quiet"])
        try git(["config", "user.email", "onyx-tests@example.invalid"])
        try git(["config", "user.name", "Onyx Tests"])
    }

    func write(_ text: String, to relativePath: String) throws {
        try write(Data(text.utf8), to: relativePath)
    }

    func write(_ data: Data, to relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
    }

    func append(_ text: String, to relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func read(_ relativePath: String) throws -> String {
        let data = try Data(contentsOf: url.appendingPathComponent(relativePath))
        return String(decoding: data, as: UTF8.self)
    }

    func commitAll(message: String) throws {
        try git(["add", "--all"])
        try git(["commit", "--quiet", "--allow-empty", "--message", message])
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path] + arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitRepositoryFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: errorData, as: UTF8.self)]
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private actor TestGitFileRecovery: GitFileRecovering {
    let url: URL
    private var recoveredByName: [String: URL] = [:]

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Onyx Git Recovery \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func moveToRecovery(_ fileURL: URL) async throws -> GitRecoveredFile {
        let destination = url.appendingPathComponent("\(UUID().uuidString)-\(fileURL.lastPathComponent)")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        recoveredByName[fileURL.lastPathComponent] = destination
        return GitRecoveredFile(originalURL: fileURL, recoveryURL: destination)
    }

    func restoreFromRecovery(_ recoveredFile: GitRecoveredFile) async throws {
        try FileManager.default.moveItem(at: recoveredFile.recoveryURL, to: recoveredFile.originalURL)
    }

    func recoveredData(named name: String) throws -> Data {
        let recoveredURL = recoveredByName[name]
        return try Data(contentsOf: XCTUnwrap(recoveredURL))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
