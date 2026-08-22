import Darwin
import Foundation

/// The small command boundary used by `GitRepositoryReader`. Keeping it
/// injectable makes parsing tests deterministic and gives the app a safe place
/// to add telemetry or a sandboxed command implementation later.
protocol GitCommandExecuting: Sendable {
    func execute(
        arguments: [String],
        repositoryURL: URL,
        timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> GitCommandResult
}

struct GitCommandResult: Sendable, Equatable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32

    init(standardOutput: Data = Data(), standardError: Data = Data(), terminationStatus: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
    }

    var errorText: String {
        String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GitRecoveredFile: Equatable, Sendable {
    let originalURL: URL
    let recoveryURL: URL
}

/// A recoverable removal boundary used before discarding working-copy bytes.
/// The live implementation uses the macOS Trash, while tests can provide an
/// isolated recovery folder without touching the user's files.
protocol GitFileRecovering: Sendable {
    func moveToRecovery(_ fileURL: URL) async throws -> GitRecoveredFile
    func restoreFromRecovery(_ recoveredFile: GitRecoveredFile) async throws
}

struct MacOSTrashGitFileRecovery: GitFileRecovering, Sendable {
    func moveToRecovery(_ fileURL: URL) async throws -> GitRecoveredFile {
        try await Task.detached(priority: .userInitiated) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: &resultingURL)
            guard let recoveryURL = resultingURL as URL? else {
                throw GitRepositoryError.discardFailed(
                    path: fileURL.path,
                    message: "macOS did not return the Trash location"
                )
            }
            return GitRecoveredFile(originalURL: fileURL, recoveryURL: recoveryURL)
        }.value
    }

    func restoreFromRecovery(_ recoveredFile: GitRecoveredFile) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: recoveredFile.originalURL.path) else { return }
            try fileManager.moveItem(at: recoveredFile.recoveryURL, to: recoveredFile.originalURL)
        }.value
    }
}

/// Executes one explicit `git -C <repository> ...` command. No shell is
/// involved, so project paths and Git arguments cannot become shell syntax.
struct LocalGitCommandExecutor: GitCommandExecuting, Sendable {
    let executableURL: URL

    init(executableURL: URL? = nil) throws {
        if let executableURL {
            self.executableURL = executableURL
            return
        }
        guard let found = Self.defaultExecutableURL() else {
            throw GitRepositoryError.gitExecutableNotFound
        }
        self.executableURL = found
    }

    /// This initializer is useful for dependency injection and avoids a
    /// throwing construction path when the caller has already resolved Git.
    init(uncheckedExecutableURL: URL) {
        self.executableURL = uncheckedExecutableURL
    }

    func execute(
        arguments: [String],
        repositoryURL: URL,
        timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> GitCommandResult {
        let localExecutableURL = executableURL
        let localRepositoryURL = repositoryURL
        let localArguments = arguments
        let localTimeout = timeout
        let localOutputLimit = outputLimit
        // `Process` is intentionally confined to this detached operation. No
        // Foundation process object crosses an actor/task boundary.
        return try await Task.detached(priority: .userInitiated) {
            try Self.runSynchronously(
                executableURL: localExecutableURL,
                repositoryURL: localRepositoryURL,
                arguments: localArguments,
                timeout: localTimeout,
                outputLimit: localOutputLimit
            )
        }.value
    }

    static func defaultExecutableURL(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/local/git/bin/git",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func runSynchronously(
        executableURL: URL,
        repositoryURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int
    ) throws -> GitCommandResult {
        guard timeout > 0 else {
            throw GitRepositoryError.timedOut(arguments: arguments, timeout: timeout)
        }
        guard outputLimit > 0 else {
            throw GitRepositoryError.outputLimitExceeded(arguments: arguments, limit: outputLimit)
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let stdoutCollector = BoundedDataCollector(limit: outputLimit)
        let stderrCollector = BoundedDataCollector(limit: min(outputLimit, 1_048_576))
        var didTimeOut = false

        // Keep `-C` explicit even though Process also receives a working
        // directory. This makes the command auditable and avoids accidental
        // dependence on the caller's current directory.
        process.executableURL = executableURL
        process.arguments = ["-C", repositoryURL.path] + arguments
        process.currentDirectoryURL = repositoryURL
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
            if stdoutCollector.didExceedLimit, process.isRunning { process.terminate() }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
            if stderrCollector.didExceedLimit, process.isRunning { process.terminate() }
        }
        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let deadline = DispatchTime.now() + timeout
        while process.isRunning, DispatchTime.now() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            didTimeOut = true
            process.terminate()
            // Git itself should exit immediately. The short grace period
            // prevents a wedged child from surviving a timed-out request.
            let graceDeadline = DispatchTime.now() + .milliseconds(250)
            while process.isRunning, DispatchTime.now() < graceDeadline {
                usleep(5_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()

        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.append(standardError.fileHandleForReading.readDataToEndOfFile())

        let timedOut = didTimeOut
        if timedOut {
            throw GitRepositoryError.timedOut(arguments: arguments, timeout: timeout)
        }
        if stdoutCollector.didExceedLimit || stderrCollector.didExceedLimit {
            throw GitRepositoryError.outputLimitExceeded(arguments: arguments, limit: outputLimit)
        }

        return GitCommandResult(
            standardOutput: stdoutCollector.data,
            standardError: stderrCollector.data,
            terminationStatus: process.terminationStatus
        )
    }
}

private final class BoundedDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()
    private var exceededLimit = false
    let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return collectedData
    }

    var didExceedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit
    }

    func append(_ incoming: Data?) {
        guard let incoming, !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return }
        if collectedData.count + incoming.count > limit {
            exceededLimit = true
            // Retain only the safe prefix so a diagnostic never allocates an
            // unbounded amount of memory after the limit is crossed.
            let remaining = max(0, limit - collectedData.count)
            if remaining > 0 { collectedData.append(incoming.prefix(remaining)) }
            return
        }
        collectedData.append(incoming)
    }
}

protocol GitRepositoryReading: Sendable {
    func readStatus(at path: String) async throws -> GitRepositoryStatus
    func readDiff(at path: String, scope: GitDiffScope) async throws -> GitDiff
    func readSnapshot(at path: String) async throws -> GitRepositorySnapshot
    func perform(_ action: GitFileAction, on target: GitFileActionTarget, at path: String) async throws
}

struct GitRepositoryReader: GitRepositoryReading, Sendable {
    struct Configuration: Sendable, Equatable {
        var timeout: TimeInterval
        var outputLimit: Int
        var maxUntrackedFileBytes: Int
        var unifiedContextLines: Int

        static let `default` = Self(
            timeout: 10,
            outputLimit: 16 * 1024 * 1024,
            maxUntrackedFileBytes: 8 * 1024 * 1024,
            unifiedContextLines: 3
        )

        init(
            timeout: TimeInterval = 10,
            outputLimit: Int = 16 * 1024 * 1024,
            maxUntrackedFileBytes: Int = 8 * 1024 * 1024,
            unifiedContextLines: Int = 3
        ) {
            self.timeout = timeout
            self.outputLimit = outputLimit
            self.maxUntrackedFileBytes = max(1, maxUntrackedFileBytes)
            self.unifiedContextLines = min(max(0, unifiedContextLines), 100)
        }
    }

    let executor: any GitCommandExecuting
    let fileRecovery: any GitFileRecovering
    let configuration: Configuration

    init(
        executor: (any GitCommandExecuting)? = nil,
        fileRecovery: (any GitFileRecovering)? = nil,
        configuration: Configuration = .default
    ) throws {
        self.executor = try executor ?? LocalGitCommandExecutor()
        self.fileRecovery = fileRecovery ?? MacOSTrashGitFileRecovery()
        self.configuration = configuration
    }

    init(
        executor: any GitCommandExecuting,
        fileRecovery: any GitFileRecovering = MacOSTrashGitFileRecovery(),
        configuration: Configuration = .default
    ) {
        self.executor = executor
        self.fileRecovery = fileRecovery
        self.configuration = configuration
    }

    func readStatus(at path: String) async throws -> GitRepositoryStatus {
        let repositoryURL = try Self.repositoryURL(path)
        let result = try await execute(
            arguments: [
                "status",
                "--porcelain=v1",
                "--branch",
                "--untracked-files=all",
                "-z",
                "--renames",
            ],
            repositoryURL: repositoryURL
        )
        guard result.terminationStatus == 0 else {
            throw Self.commandError(result, arguments: ["status"] , path: repositoryURL.path)
        }
        let parsed = try GitPorcelainStatusParser.parse(result.standardOutput)
        return GitRepositoryStatus(
            repositoryPath: repositoryURL.path,
            branch: parsed.branch,
            changes: parsed.changes
        )
    }

    func readDiff(at path: String, scope: GitDiffScope) async throws -> GitDiff {
        let repositoryURL = try Self.repositoryURL(path)
        let status = scope == .unstaged ? try await readStatus(at: repositoryURL.path) : nil
        return try await readDiff(at: repositoryURL, scope: scope, status: status)
    }

    func readSnapshot(at path: String) async throws -> GitRepositorySnapshot {
        let repositoryURL = try Self.repositoryURL(path)
        let status = try await readStatus(at: repositoryURL.path)
        async let staged = readDiff(at: repositoryURL, scope: .staged, status: status)
        async let unstaged = readDiff(at: repositoryURL, scope: .unstaged, status: status)
        return try await GitRepositorySnapshot(status: status, staged: staged, unstaged: unstaged)
    }

    func perform(_ action: GitFileAction, on target: GitFileActionTarget, at path: String) async throws {
        let repositoryURL = try Self.repositoryURL(path)
        let requestedPathspecs = action == .discard ? [target.path] : target.pathspecs
        let pathspecs = try requestedPathspecs.map { pathspec in
            try Self.validatedPathspec(pathspec, root: repositoryURL)
        }

        if action == .discard {
            try await discard(target: target, repositoryURL: repositoryURL)
            return
        }

        let status = try await readStatus(at: repositoryURL.path)
        guard let currentChange = status.changes.first(where: { $0.path == target.path }) else {
            throw GitRepositoryError.changeNoLongerAvailable(target.path)
        }
        guard !currentChange.isConflict else {
            throw GitRepositoryError.conflictedChange(target.path)
        }
        switch action {
        case .stage where !currentChange.isUnstaged,
             .unstage where !currentChange.isStaged:
            throw GitRepositoryError.changeNoLongerAvailable(target.path)
        default:
            break
        }
        if target.kind == .renamed,
           (currentChange.kind != .renamed || currentChange.oldPath != target.oldPath) {
            throw GitRepositoryError.changeNoLongerAvailable(target.path)
        }

        let arguments: [String]
        switch action {
        case .stage:
            // `--all` makes a rename or deletion complete when both path
            // identities are supplied. `--literal-pathspecs` prevents Git
            // pathspec magic, while `--` prevents option interpretation.
            arguments = ["--literal-pathspecs", "add", "--all", "--"] + pathspecs
        case .unstage:
            // Path-scoped reset changes only the index and also works in an
            // unborn repository where `git restore --staged` cannot resolve
            // HEAD.
            arguments = ["--literal-pathspecs", "reset", "--quiet", "--"] + pathspecs
        case .discard:
            preconditionFailure("Discard returns through its recoverable path above")
        }

        let result = try await execute(arguments: arguments, repositoryURL: repositoryURL)
        guard result.terminationStatus == 0 else {
            throw Self.commandError(result, arguments: arguments, path: repositoryURL.path)
        }
    }

    private func discard(target: GitFileActionTarget, repositoryURL: URL) async throws {
        let status = try await readStatus(at: repositoryURL.path)
        guard let currentChange = status.changes.first(where: { $0.path == target.path }),
              currentChange.isUnstaged else {
            throw GitRepositoryError.changeNoLongerAvailable(target.path)
        }
        guard !currentChange.isConflict else {
            throw GitRepositoryError.conflictedChange(target.path)
        }
        let fileURL = try Self.safeWorkingTreeFileURL(relativePath: target.path, root: repositoryURL)

        if currentChange.isUntracked {
            guard Self.pathEntryExists(fileURL) else {
                throw GitRepositoryError.changeNoLongerAvailable(target.path)
            }
            do {
                _ = try await fileRecovery.moveToRecovery(fileURL)
            } catch let error as GitRepositoryError {
                throw error
            } catch {
                throw GitRepositoryError.discardFailed(path: target.path, message: error.localizedDescription)
            }
            return
        }

        var recoveredFile: GitRecoveredFile?
        if Self.pathEntryExists(fileURL) {
            do {
                recoveredFile = try await fileRecovery.moveToRecovery(fileURL)
            } catch let error as GitRepositoryError {
                throw error
            } catch {
                throw GitRepositoryError.discardFailed(path: target.path, message: error.localizedDescription)
            }
        }

        let arguments = ["--literal-pathspecs", "restore", "--worktree", "--", target.path]
        do {
            let result = try await execute(arguments: arguments, repositoryURL: repositoryURL)
            guard result.terminationStatus == 0 else {
                throw Self.commandError(result, arguments: arguments, path: repositoryURL.path)
            }
        } catch {
            if let recoveredFile {
                try? await fileRecovery.restoreFromRecovery(recoveredFile)
            }
            throw error
        }
    }

    private func readDiff(
        at repositoryURL: URL,
        scope: GitDiffScope,
        status: GitRepositoryStatus?
    ) async throws -> GitDiff {
        var diffArguments = ["diff"]
        if scope == .staged { diffArguments.append("--cached") }
        diffArguments += [
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--find-renames",
            "--find-copies",
            "--unified=\(configuration.unifiedContextLines)",
            "--full-index",
        ]

        var nameArguments = ["diff"]
        if scope == .staged { nameArguments.append("--cached") }
        nameArguments += [
            "--name-status",
            "--find-renames",
            "--find-copies",
            "-z",
        ]

        async let patchResult = execute(arguments: diffArguments, repositoryURL: repositoryURL)
        async let nameResult = execute(arguments: nameArguments, repositoryURL: repositoryURL)
        let patch = try await checkedResult(patchResult, arguments: diffArguments, path: repositoryURL.path)
        let names = try await checkedResult(nameResult, arguments: nameArguments, path: repositoryURL.path)
        let metadata = try GitNameStatusParser.parse(names.standardOutput)
        var files = GitUnifiedDiffParser.parse(
            patch.standardOutput,
            scope: scope,
            metadata: metadata
        )

        if scope == .unstaged, let status {
            let existing = Set(files.map { $0.path })
            for change in status.changes where change.isUntracked && !existing.contains(change.path) {
                files.append(try makeUntrackedDiff(for: change, repositoryURL: repositoryURL))
            }
        }

        // Git normally emits files in stable path order. Sorting here makes
        // the model deterministic across Git versions and synthetic files.
        files.sort {
            let lhs = $0.path.localizedStandardCompare($1.path)
            if lhs != .orderedSame { return lhs == .orderedAscending }
            return ($0.oldPath ?? "") < ($1.oldPath ?? "")
        }
        return GitDiff(scope: scope, files: files)
    }

    private func makeUntrackedDiff(for change: GitFileChange, repositoryURL: URL) throws -> GitDiffFile {
        guard let fileURL = Self.safeChildURL(relativePath: change.path, root: repositoryURL) else {
            throw GitRepositoryError.unreadableFile(path: change.path, message: "path escapes the repository")
        }

        do {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
                return GitDiffFile(
                    path: change.path,
                    kind: .untracked,
                    hunks: Self.syntheticTextHunks(lines: [destination], hasTrailingNewline: false)
                )
            }

            if let fileSize = values.fileSize, fileSize > configuration.maxUntrackedFileBytes {
                return GitDiffFile(
                    path: change.path,
                    kind: .untracked,
                    isBinary: true,
                    metadata: ["Untracked file is larger than the preview limit."]
                )
            }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard data.count <= configuration.maxUntrackedFileBytes else {
                return GitDiffFile(
                    path: change.path,
                    kind: .untracked,
                    isBinary: true,
                    metadata: ["Untracked file is larger than the preview limit."]
                )
            }
            guard data.firstIndex(of: 0) == nil,
                  let text = String(data: data, encoding: .utf8) else {
                return GitDiffFile(path: change.path, kind: .untracked, isBinary: true)
            }
            let (lines, trailingNewline) = Self.splitTextLines(text)
            return GitDiffFile(
                path: change.path,
                kind: .untracked,
                hunks: Self.syntheticTextHunks(lines: lines, hasTrailingNewline: trailingNewline)
            )
        } catch let error as GitRepositoryError {
            throw error
        } catch {
            throw GitRepositoryError.unreadableFile(path: change.path, message: error.localizedDescription)
        }
    }

    private func execute(arguments: [String], repositoryURL: URL) async throws -> GitCommandResult {
        try await executor.execute(
            arguments: arguments,
            repositoryURL: repositoryURL,
            timeout: configuration.timeout,
            outputLimit: configuration.outputLimit
        )
    }

    private func checkedResult(
        _ result: GitCommandResult,
        arguments: [String],
        path: String
    ) throws -> GitCommandResult {
        guard result.terminationStatus == 0 else {
            throw Self.commandError(result, arguments: arguments, path: path)
        }
        return result
    }

    private static func commandError(
        _ result: GitCommandResult,
        arguments: [String],
        path: String
    ) -> GitRepositoryError {
        let message = result.errorText
        if result.terminationStatus == 128,
           message.localizedCaseInsensitiveContains("not a git repository") {
            return .notRepository(path)
        }
        return .commandFailed(arguments: arguments, exitCode: result.terminationStatus, message: message)
    }

    static func repositoryURL(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitRepositoryError.invalidRepositoryPath(path) }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitRepositoryError.invalidRepositoryPath(url.path)
        }
        return url
    }

    static func safeChildURL(relativePath: String, root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let candidate = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    private static func safeWorkingTreeFileURL(relativePath: String, root: URL) throws -> URL {
        guard let candidate = safeChildURL(relativePath: relativePath, root: root),
              candidate.path != root.standardizedFileURL.path else {
            throw GitRepositoryError.invalidChangePath(relativePath)
        }

        // Resolve the parent, but not the final entry. That permits safely
        // moving an untracked symlink itself while rejecting a path that walks
        // through a symlinked directory outside the checkout.
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedParent.path == resolvedRoot.path
                || resolvedParent.path.hasPrefix(resolvedRoot.path + "/") else {
            throw GitRepositoryError.invalidChangePath(relativePath)
        }
        return candidate
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        var fileStatus = stat()
        return lstat(url.path, &fileStatus) == 0
    }

    private static func validatedPathspec(_ path: String, root: URL) throws -> String {
        guard let candidate = safeChildURL(relativePath: path, root: root),
              candidate.path != root.standardizedFileURL.path else {
            throw GitRepositoryError.invalidChangePath(path)
        }
        return path
    }

    static func splitTextLines(_ text: String) -> (lines: [String], trailingNewline: Bool) {
        guard !text.isEmpty else { return ([], false) }
        var components = text.components(separatedBy: "\n")
        let trailingNewline = components.last == ""
        if trailingNewline { components.removeLast() }
        return (components.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }, trailingNewline)
    }

    static func syntheticTextHunks(lines: [String], hasTrailingNewline: Bool) -> [GitDiffHunk] {
        guard !lines.isEmpty else { return [] }
        var diffLines = lines.map {
            GitDiffLine(kind: .addition, content: $0, oldLineNumber: nil, newLineNumber: nil)
        }
        for index in diffLines.indices {
            diffLines[index] = GitDiffLine(
                kind: .addition,
                content: diffLines[index].content,
                newLineNumber: index + 1
            )
        }
        if !hasTrailingNewline {
            diffLines.append(GitDiffLine(kind: .noNewline, content: "No newline at end of file"))
        }
        return [GitDiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count, lines: diffLines)]
    }
}

private struct ParsedPorcelainStatus: Sendable {
    let branch: GitBranchStatus
    let changes: [GitFileChange]
}

private enum GitPorcelainStatusParser {
    static func parse(_ data: Data) throws -> ParsedPorcelainStatus {
        let records = splitNUL(data)
        var branch = GitBranchStatus.unknown
        var changes: [GitFileChange] = []
        var index = 0

        while index < records.count {
            let record = records[index]
            index += 1
            if record.isEmpty { continue }
            if record.starts(with: Array("## ".utf8)) {
                branch = parseBranch(String(decoding: record, as: UTF8.self).dropFirst(3))
                continue
            }
            guard record.count >= 3, record[record.startIndex + 2] == 0x20 else {
                throw GitRepositoryError.malformedStatus("status record is missing its XY separator")
            }
            let x = record[record.startIndex]
            let y = record[record.startIndex + 1]
            let pathBytes = record.dropFirst(3)
            var oldPath: String?
            if x == UInt8(ascii: "R") || x == UInt8(ascii: "C") || y == UInt8(ascii: "R") || y == UInt8(ascii: "C") {
                guard index < records.count else {
                    throw GitRepositoryError.malformedStatus("rename/copy record has no previous path")
                }
                oldPath = String(decoding: records[index], as: UTF8.self)
                index += 1
            }
            let ignored = x == UInt8(ascii: "!") && y == UInt8(ascii: "!")
            let untracked = x == UInt8(ascii: "?") && y == UInt8(ascii: "?")
            let pair = String(decoding: [x, y], as: UTF8.self)
            let unmerged = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair)
            let path = String(decoding: pathBytes, as: UTF8.self)
            guard !path.isEmpty else { throw GitRepositoryError.malformedStatus("status record has an empty path") }
            changes.append(
                GitFileChange(
                    path: path,
                    oldPath: oldPath,
                    indexState: unmerged
                        ? .unmerged
                        : GitStatusState(rawCharacter: x, untracked: untracked, ignored: ignored),
                    worktreeState: unmerged
                        ? .unmerged
                        : GitStatusState(rawCharacter: y, untracked: untracked, ignored: ignored)
                )
            )
        }
        return ParsedPorcelainStatus(branch: branch, changes: changes)
    }

    private static func parseBranch(_ payload: Substring) -> GitBranchStatus {
        let text = String(payload)
        if text == "HEAD (no branch)" || text.hasPrefix("HEAD ") {
            return GitBranchStatus(name: nil, isDetached: true, description: text)
        }
        if text.hasPrefix("No commits yet on ") {
            return GitBranchStatus(name: String(text.dropFirst("No commits yet on ".count)), description: text)
        }

        let branchAndTracking = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let branchPart = branchAndTracking.first.map(String.init) ?? text
        var name = branchPart
        var upstream: String?
        if let dots = branchPart.range(of: "...") {
            name = String(branchPart[..<dots.lowerBound])
            upstream = String(branchPart[dots.upperBound...])
        }
        var ahead = 0
        var behind = 0
        if let tracking = branchAndTracking.dropFirst().first {
            let trackingText = String(tracking)
            let numbers = trackingText
                .split(whereSeparator: { $0 == "," || $0 == "]" || $0 == "[" })
            for number in numbers {
                let part = number.trimmingCharacters(in: .whitespaces)
                if part.hasPrefix("ahead ") { ahead = Int(part.dropFirst(6)) ?? 0 }
                if part.hasPrefix("behind ") { behind = Int(part.dropFirst(7)) ?? 0 }
            }
        }
        return GitBranchStatus(name: name, upstream: upstream, ahead: ahead, behind: behind, description: text)
    }
}

private struct GitDiffMetadata: Sendable, Equatable {
    let path: String
    let oldPath: String?
    let kind: GitDiffFileKind
}

private enum GitNameStatusParser {
    static func parse(_ data: Data) throws -> [GitDiffMetadata] {
        let records = splitNUL(data)
        var result: [GitDiffMetadata] = []
        var index = 0
        while index < records.count {
            let statusBytes = records[index]
            index += 1
            if statusBytes.isEmpty { continue }
            let status = String(decoding: statusBytes, as: UTF8.self)
            guard let code = status.first else { continue }
            let kind = kind(for: code)
            if code == "R" || code == "C" {
                guard index + 1 < records.count else {
                    throw GitRepositoryError.malformedDiff("rename/copy name-status record is incomplete")
                }
                let oldPath = String(decoding: records[index], as: UTF8.self)
                let path = String(decoding: records[index + 1], as: UTF8.self)
                index += 2
                result.append(GitDiffMetadata(path: path, oldPath: oldPath, kind: kind))
            } else {
                guard index < records.count else {
                    throw GitRepositoryError.malformedDiff("name-status record is missing its path")
                }
                let path = String(decoding: records[index], as: UTF8.self)
                index += 1
                result.append(GitDiffMetadata(path: path, oldPath: nil, kind: kind))
            }
        }
        return result
    }

    private static func kind(for code: Character) -> GitDiffFileKind {
        switch code {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .unmerged
        case "M": .modified
        default: .unknown
        }
    }
}

private enum GitUnifiedDiffParser {
    private struct FileBuilder {
        var path: String
        var oldPath: String?
        var kind: GitDiffFileKind
        var binary = false
        var hunks: [GitDiffHunk] = []
        var metadata: [String] = []
    }

    static func parse(
        _ data: Data,
        scope: GitDiffScope,
        metadata: [GitDiffMetadata]
    ) -> [GitDiffFile] {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else {
            return metadata.map {
                GitDiffFile(path: $0.path, oldPath: $0.oldPath, kind: $0.kind)
            }
        }
        let lines = text.components(separatedBy: "\n")
        var builders: [FileBuilder] = []
        var current: FileBuilder?
        var currentHunk: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String?, lines: [GitDiffLine], oldCursor: Int, newCursor: Int)?

        func finishHunk() {
            guard let hunk = currentHunk, var file = current else { return }
            file.hunks.append(
                GitDiffHunk(
                    oldStart: hunk.oldStart,
                    oldCount: hunk.oldCount,
                    newStart: hunk.newStart,
                    newCount: hunk.newCount,
                    heading: hunk.heading,
                    lines: hunk.lines
                )
            )
            current = file
            currentHunk = nil
        }

        func finishFile() {
            finishHunk()
            if let current { builders.append(current) }
            current = nil
            currentHunk = nil
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                finishFile()
                let parsedPaths = parseHeaderPaths(String(line.dropFirst("diff --git ".count)))
                let metadataMatch = matchMetadata(metadata: metadata, usedCount: builders.count)
                current = FileBuilder(
                    path: metadataMatch?.path ?? parsedPaths?.newPath ?? parsedPaths?.oldPath ?? "",
                    oldPath: metadataMatch?.oldPath ?? distinctOldPath(parsedPaths),
                    kind: metadataMatch?.kind ?? .modified
                )
                continue
            }
            guard current != nil else { continue }

            if line.hasPrefix("@@ ") || line.hasPrefix("@@-") {
                finishHunk()
                guard let header = parseHunkHeader(line) else {
                    current?.metadata.append(line)
                    continue
                }
                currentHunk = (
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    heading: header.heading,
                    lines: [],
                    oldCursor: header.oldStart,
                    newCursor: header.newStart
                )
                continue
            }

            if line == "\\ No newline at end of file" {
                if currentHunk != nil {
                    currentHunk?.lines.append(GitDiffLine(kind: .noNewline, content: "No newline at end of file"))
                } else {
                    current?.metadata.append(line)
                }
                continue
            }

            if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                current?.binary = true
                current?.metadata.append(line)
                continue
            }

            if let hunk = currentHunk, let prefix = line.first,
               prefix == " " || prefix == "+" || prefix == "-" {
                let content = String(line.dropFirst())
                let oldNumber = prefix == "+" ? nil : hunk.oldCursor
                let newNumber = prefix == "-" ? nil : hunk.newCursor
                let kind: GitDiffLineKind = switch prefix {
                case "+": .addition
                case "-": .deletion
                default: .context
                }
                currentHunk?.lines.append(
                    GitDiffLine(kind: kind, content: content, oldLineNumber: oldNumber, newLineNumber: newNumber)
                )
                if prefix != "+" { currentHunk?.oldCursor += 1 }
                if prefix != "-" { currentHunk?.newCursor += 1 }
                continue
            }

            // Mode changes, similarity/rename headers, and index lines are
            // useful to a future renderer but are not source lines.
            if !line.isEmpty { current?.metadata.append(line) }
        }
        finishFile()

        var result = builders.map {
            GitDiffFile(
                path: $0.path,
                oldPath: $0.oldPath,
                kind: $0.kind,
                isBinary: $0.binary,
                hunks: $0.hunks,
                metadata: $0.metadata
            )
        }

        // Pure renames and other metadata-only files are sometimes easier to
        // obtain from --name-status than from the patch stream. Add any such
        // records without duplicating a parsed section.
        let represented = Set(result.map { "\($0.path)\u{001F}\($0.oldPath ?? "")" })
        for item in metadata {
            let key = "\(item.path)\u{001F}\(item.oldPath ?? "")"
            guard !represented.contains(key) else { continue }
            result.append(GitDiffFile(path: item.path, oldPath: item.oldPath, kind: item.kind))
        }
        return result
    }

    private struct HeaderPaths {
        let oldPath: String
        let newPath: String
    }

    private static func parseHeaderPaths(_ remainder: String) -> HeaderPaths? {
        var scanner = GitPathScanner(remainder)
        guard let first = scanner.nextToken(), let second = scanner.nextToken() else { return nil }
        guard first.hasPrefix("a/"), second.hasPrefix("b/") else { return nil }
        return HeaderPaths(oldPath: String(first.dropFirst(2)), newPath: String(second.dropFirst(2)))
    }

    private static func matchMetadata(metadata: [GitDiffMetadata], usedCount: Int) -> GitDiffMetadata? {
        guard usedCount < metadata.count else { return nil }
        return metadata[usedCount]
    }

    private static func distinctOldPath(_ paths: HeaderPaths?) -> String? {
        guard let paths, paths.oldPath != paths.newPath else { return nil }
        return paths.oldPath
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String?)? {
        guard line.hasPrefix("@@") else { return nil }
        let searchStart = line.index(line.startIndex, offsetBy: 2)
        guard let close = line.range(of: " @@", range: searchStart..<line.endIndex) else { return nil }
        let bodyStart = line.index(line.startIndex, offsetBy: 2)
        let body = line[bodyStart..<close.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2,
              let old = parseRange(tokens[0], prefix: "-"),
              let new = parseRange(tokens[1], prefix: "+") else { return nil }
        let headingStart = close.upperBound
        let heading = line[headingStart...].trimmingCharacters(in: .whitespaces)
        return (old.start, old.count, new.start, new.count, heading.isEmpty ? nil : heading)
    }

    private static func parseRange(_ token: Substring, prefix: Character) -> (start: Int, count: Int)? {
        guard token.first == prefix else { return nil }
        let body = token.dropFirst()
        let values = body.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(values[0]) else { return nil }
        let count = values.count > 1 ? (Int(values[1]) ?? 1) : 1
        return (start, count)
    }
}

private struct GitPathScanner {
    private let characters: Array<Character>
    private var index = 0

    init(_ string: String) {
        characters = Array(string)
    }

    mutating func nextToken() -> String? {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        guard index < characters.count else { return nil }
        if characters[index] == "\"" {
            index += 1
            var bytes: [UInt8] = []
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\"" { return String(decoding: bytes, as: UTF8.self) }
                if character != "\\" {
                    bytes.append(contentsOf: String(character).utf8)
                    continue
                }
                guard index < characters.count else { break }
                let escaped = characters[index]
                index += 1
                switch escaped {
                case "n": bytes.append(0x0A)
                case "t": bytes.append(0x09)
                case "r": bytes.append(0x0D)
                case "b": bytes.append(0x08)
                case "f": bytes.append(0x0C)
                case "v": bytes.append(0x0B)
                case "a": bytes.append(0x07)
                case "\\", "\"": bytes.append(contentsOf: String(escaped).utf8)
                default:
                    if escaped.isNumber {
                        var octal = String(escaped)
                        for _ in 0..<2 {
                            guard index < characters.count, characters[index].isNumber else { break }
                            octal.append(characters[index])
                            index += 1
                        }
                        bytes.append(UInt8(octal, radix: 8) ?? 0)
                    } else {
                        bytes.append(contentsOf: String(escaped).utf8)
                    }
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        let start = index
        while index < characters.count, !characters[index].isWhitespace { index += 1 }
        return String(characters[start..<index])
    }
}

private func splitNUL(_ data: Data) -> [[UInt8]] {
    var records: [[UInt8]] = []
    var current: [UInt8] = []
    current.reserveCapacity(128)
    for byte in data {
        if byte == 0 {
            records.append(current)
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(byte)
        }
    }
    if !current.isEmpty { records.append(current) }
    return records
}
