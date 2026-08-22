import Foundation
import XCTest
@testable import Onyx

@MainActor
final class GitDiffViewerTests: XCTestCase {
    func testProjectChangeDiscardsTheOlderRepositoryResult() async throws {
        let reader = SequencedSnapshotReader(responses: [
            .init(path: "/old-project", delayNanoseconds: 80_000_000, snapshot: snapshot(branch: "old")),
            .init(path: "/new-project", delayNanoseconds: 1_000_000, snapshot: snapshot(branch: "new")),
        ])
        let model = GitDiffViewerModel(reader: reader)

        let olderLoad = Task { await model.load(path: "/old-project") }
        try await Task.sleep(nanoseconds: 10_000_000)
        await model.load(path: "/new-project")
        await olderLoad.value

        guard case let .loaded(result) = model.state else {
            return XCTFail("Expected the newer repository snapshot")
        }
        XCTAssertEqual(result.status.branch.name, "new")
        XCTAssertEqual(model.selectedFileID, "new.swift")
    }

    func testOverlappingRefreshDiscardsTheSlowerEarlierRefresh() async throws {
        let reader = SequencedSnapshotReader(responses: [
            .init(path: "/project", delayNanoseconds: 0, snapshot: snapshot(branch: "initial")),
            .init(path: "/project", delayNanoseconds: 80_000_000, snapshot: snapshot(branch: "stale")),
            .init(path: "/project", delayNanoseconds: 1_000_000, snapshot: snapshot(branch: "latest")),
        ])
        let model = GitDiffViewerModel(reader: reader)
        await model.load(path: "/project")

        let olderRefresh = Task { await model.refresh() }
        try await Task.sleep(nanoseconds: 10_000_000)
        await model.refresh()
        await olderRefresh.value

        guard case let .loaded(result) = model.state else {
            return XCTFail("Expected a loaded refresh result")
        }
        XCTAssertEqual(result.status.branch.name, "latest")
        XCTAssertFalse(model.isRefreshing)
    }

    func testNoProjectAndNotRepositoryHaveSpecificStates() async {
        let model = GitDiffViewerModel(reader: NotRepositoryReader())

        await model.load(path: nil)
        XCTAssertEqual(model.state, .noProject)

        await model.load(path: "/not-a-repository")
        XCTAssertEqual(model.state, .notRepository)
    }

    func testPreparingProjectDoesNotReadUntilExplicitInspection() async {
        let reader = SequencedSnapshotReader(responses: [
            .init(path: "/Users/test/Documents/project", delayNanoseconds: 0, snapshot: snapshot(branch: "main")),
        ])
        let model = GitDiffViewerModel(reader: reader)

        model.prepare(path: " /Users/test/Documents/project ")

        XCTAssertEqual(model.state, .needsExplicitLoad("/Users/test/Documents/project"))
        XCTAssertTrue(reader.recordedReadPaths.isEmpty)

        await model.load(path: "/Users/test/Documents/project")

        XCTAssertEqual(reader.recordedReadPaths, ["/Users/test/Documents/project"])
        guard case .loaded = model.state else {
            return XCTFail("Explicit inspection should load the repository")
        }

        model.prepare(path: "/Users/test/Documents/project")
        guard case .loaded = model.state else {
            return XCTFail("Re-rendering the same project should preserve its loaded snapshot")
        }
        XCTAssertEqual(reader.recordedReadPaths, ["/Users/test/Documents/project"])
    }

    func testRenderPlanBoundsFilesHunksLinesAndMetadata() {
        let lines = (1 ... 5).map { (number: Int) in
            GitDiffLine(kind: .addition, content: "line \(number)", newLineNumber: number)
        }
        let selected = GitDiffFile(
            path: "one.swift",
            hunks: [
                GitDiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 3, lines: Array(lines.prefix(3))),
                GitDiffHunk(oldStart: 4, oldCount: 0, newStart: 4, newCount: 2, lines: Array(lines.suffix(2))),
            ],
            metadata: ["first", "second"]
        )
        let diff = GitDiff(scope: .unstaged, files: [
            selected,
            GitDiffFile(path: "two.swift"),
            GitDiffFile(path: "three.swift"),
        ])

        let plan = GitDiffRenderPlan(
            diff: diff,
            selectedFile: selected,
            limits: .init(maximumFiles: 2, maximumHunks: 1, maximumLines: 2, maximumMetadataLines: 1)
        )

        XCTAssertEqual(plan.files.map(\.path), ["one.swift", "two.swift"])
        XCTAssertEqual(plan.hiddenFileCount, 1)
        XCTAssertEqual(plan.hunks.count, 1)
        XCTAssertEqual(plan.hunks.first?.lines.count, 2)
        XCTAssertEqual(plan.hiddenLineCount, 3)
        XCTAssertEqual(plan.metadata, ["first"])
        XCTAssertEqual(plan.hiddenMetadataCount, 1)
    }

    func testAccessibilityLabelsDescribeMeaningWithoutDependingOnColor() {
        let addition = GitDiffLine(kind: .addition, content: "let answer = 42", newLineNumber: 7)
        XCTAssertEqual(
            GitDiffAccessibility.lineLabel(addition),
            "Added, no old line, new line 7: let answer = 42"
        )

        let binaryRename = GitDiffFile(
            path: "new image.png",
            oldPath: "old image.png",
            kind: .renamed,
            isBinary: true
        )
        let label = GitDiffAccessibility.fileLabel(binaryRename)
        XCTAssertTrue(label.contains("renamed from old image.png"))
        XCTAssertTrue(label.contains("binary or preview unavailable"))
    }

    func testStagePublishesOnlyPostActionSnapshotAndFollowsFileToStagedScope() async {
        let reader = MutableActionReader(snapshots: [
            "/project": [
                actionSnapshot(scope: .unstaged, branch: "before", state: .untracked),
                actionSnapshot(scope: .staged, branch: "after", state: .added),
            ],
        ])
        let model = GitDiffViewerModel(reader: reader)
        await model.load(path: "/project")

        XCTAssertTrue(model.canPerform(.stage, on: "change.swift"))
        await model.perform(.stage, on: "change.swift")

        XCTAssertEqual(model.selectedScope, .staged)
        XCTAssertEqual(model.selectedFileID, "change.swift")
        XCTAssertEqual(model.snapshot?.status.branch.name, "after")
        XCTAssertEqual(reader.recordedActions.map(\.action), [.stage])
    }

    func testActionFailureKeepsLastGoodSnapshotAndExposesLocalError() async {
        let reader = MutableActionReader(
            snapshots: ["/project": [actionSnapshot(scope: .unstaged, branch: "stable", state: .modified)]],
            actionError: ActionFailure(message: "index is locked")
        )
        let model = GitDiffViewerModel(reader: reader)
        await model.load(path: "/project")

        await model.perform(.stage, on: "change.swift")

        XCTAssertEqual(model.snapshot?.status.branch.name, "stable")
        XCTAssertEqual(model.actionErrorMessage, "index is locked")
        XCTAssertNil(model.activeOperation)
        XCTAssertTrue(model.canPerform(.stage, on: "change.swift"))
        model.dismissActionError()
        XCTAssertNil(model.actionErrorMessage)
    }

    func testProjectSwitchInvalidatesSlowActionCompletion() async throws {
        let reader = MutableActionReader(
            snapshots: [
                "/old": [actionSnapshot(scope: .unstaged, branch: "old", state: .modified)],
                "/new": [actionSnapshot(scope: .unstaged, branch: "new", state: .modified)],
            ],
            actionDelayNanoseconds: 80_000_000
        )
        let model = GitDiffViewerModel(reader: reader)
        await model.load(path: "/old")

        let mutation = Task { await model.perform(.stage, on: "change.swift") }
        try await Task.sleep(nanoseconds: 10_000_000)
        await model.load(path: "/new")
        await mutation.value

        XCTAssertEqual(model.snapshot?.status.branch.name, "new")
        XCTAssertNil(model.activeOperation)
        XCTAssertNil(model.actionErrorMessage)
    }

    func testConflictDisablesEveryFileAction() async {
        let reader = MutableActionReader(snapshots: [
            "/project": [actionSnapshot(scope: .unstaged, branch: "conflict", state: .unmerged)],
        ])
        let model = GitDiffViewerModel(reader: reader)
        await model.load(path: "/project")

        XCTAssertTrue(model.requiresConflictResolution(on: "change.swift"))
        XCTAssertFalse(model.canPerform(.stage, on: "change.swift"))
        XCTAssertFalse(model.canPerform(.unstage, on: "change.swift"))
        XCTAssertFalse(model.canPerform(.discard, on: "change.swift"))
        await model.perform(.stage, on: "change.swift")
        XCTAssertTrue(reader.recordedActions.isEmpty)
    }

    private func snapshot(branch: String) -> GitRepositorySnapshot {
        let file = GitDiffFile(
            path: "new.swift",
            hunks: [
                GitDiffHunk(
                    oldStart: 0,
                    oldCount: 0,
                    newStart: 1,
                    newCount: 1,
                    lines: [GitDiffLine(kind: .addition, content: branch, newLineNumber: 1)]
                ),
            ]
        )
        return GitRepositorySnapshot(
            status: GitRepositoryStatus(
                repositoryPath: "/\(branch)",
                branch: GitBranchStatus(name: branch),
                changes: [GitFileChange(path: "new.swift", worktreeState: .modified)]
            ),
            staged: GitDiff(scope: .staged),
            unstaged: GitDiff(scope: .unstaged, files: [file])
        )
    }

    private func actionSnapshot(
        scope: GitDiffScope,
        branch: String,
        state: GitStatusState
    ) -> GitRepositorySnapshot {
        let file = GitDiffFile(
            path: "change.swift",
            kind: state == .untracked ? .untracked : (state == .unmerged ? .unmerged : .modified),
            hunks: [
                GitDiffHunk(
                    oldStart: 1,
                    oldCount: 1,
                    newStart: 1,
                    newCount: 1,
                    lines: [GitDiffLine(kind: .addition, content: branch, newLineNumber: 1)]
                ),
            ]
        )
        let change = GitFileChange(
            path: file.path,
            indexState: scope == .staged ? state : .unchanged,
            worktreeState: scope == .unstaged ? state : .unchanged
        )
        return GitRepositorySnapshot(
            status: GitRepositoryStatus(
                repositoryPath: "/project",
                branch: GitBranchStatus(name: branch),
                changes: [change]
            ),
            staged: GitDiff(scope: .staged, files: scope == .staged ? [file] : []),
            unstaged: GitDiff(scope: .unstaged, files: scope == .unstaged ? [file] : [])
        )
    }
}

private final class MutableActionReader: GitRepositoryReading, @unchecked Sendable {
    struct RecordedAction: Sendable {
        let action: GitFileAction
        let target: GitFileActionTarget
        let path: String
    }

    private let lock = NSLock()
    private var snapshots: [String: [GitRepositorySnapshot]]
    private let actionError: (any Error & Sendable)?
    private let actionDelayNanoseconds: UInt64
    private var actions: [RecordedAction] = []

    init(
        snapshots: [String: [GitRepositorySnapshot]],
        actionError: (any Error & Sendable)? = nil,
        actionDelayNanoseconds: UInt64 = 0
    ) {
        self.snapshots = snapshots
        self.actionError = actionError
        self.actionDelayNanoseconds = actionDelayNanoseconds
    }

    var recordedActions: [RecordedAction] {
        lock.withLock { actions }
    }

    func readStatus(at path: String) async throws -> GitRepositoryStatus {
        try await readSnapshot(at: path).status
    }

    func readDiff(at path: String, scope: GitDiffScope) async throws -> GitDiff {
        let snapshot = try await readSnapshot(at: path)
        return scope == .staged ? snapshot.staged : snapshot.unstaged
    }

    func readSnapshot(at path: String) async throws -> GitRepositorySnapshot {
        try lock.withLock {
            guard var available = snapshots[path], !available.isEmpty else {
                throw ActionFailure(message: "No snapshot for \(path)")
            }
            let snapshot = available.removeFirst()
            snapshots[path] = available
            return snapshot
        }
    }

    func perform(_ action: GitFileAction, on target: GitFileActionTarget, at path: String) async throws {
        lock.withLock { actions.append(RecordedAction(action: action, target: target, path: path)) }
        if actionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: actionDelayNanoseconds)
        }
        if let actionError { throw actionError }
    }
}

private struct ActionFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private final class SequencedSnapshotReader: GitRepositoryReading, @unchecked Sendable {
    struct Response: Sendable {
        let path: String
        let delayNanoseconds: UInt64
        let snapshot: GitRepositorySnapshot
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var readPaths: [String] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var recordedReadPaths: [String] {
        lock.withLock { readPaths }
    }

    func readStatus(at path: String) async throws -> GitRepositoryStatus {
        try await readSnapshot(at: path).status
    }

    func readDiff(at path: String, scope: GitDiffScope) async throws -> GitDiff {
        let result = try await readSnapshot(at: path)
        return scope == .staged ? result.staged : result.unstaged
    }

    func readSnapshot(at path: String) async throws -> GitRepositorySnapshot {
        lock.withLock { readPaths.append(path) }
        let response = try nextResponse(for: path)
        if response.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: response.delayNanoseconds)
        }
        return response.snapshot
    }

    func perform(_: GitFileAction, on _: GitFileActionTarget, at _: String) async throws {}

    private func nextResponse(for path: String) throws -> Response {
        lock.lock()
        defer { lock.unlock() }
        guard let index = responses.firstIndex(where: { $0.path == path }) else {
            throw MissingResponse(path: path)
        }
        return responses.remove(at: index)
    }

    private struct MissingResponse: Error, Sendable {
        let path: String
    }
}

private struct NotRepositoryReader: GitRepositoryReading {
    func readStatus(at path: String) async throws -> GitRepositoryStatus {
        throw GitRepositoryError.notRepository(path)
    }

    func readDiff(at path: String, scope _: GitDiffScope) async throws -> GitDiff {
        throw GitRepositoryError.notRepository(path)
    }

    func readSnapshot(at path: String) async throws -> GitRepositorySnapshot {
        throw GitRepositoryError.notRepository(path)
    }

    func perform(_: GitFileAction, on _: GitFileActionTarget, at path: String) async throws {
        throw GitRepositoryError.notRepository(path)
    }
}
