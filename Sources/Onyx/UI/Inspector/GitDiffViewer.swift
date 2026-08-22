import Combine
import Foundation
import SwiftUI

@MainActor
final class GitDiffViewerModel: ObservableObject {
    struct ActiveOperation: Equatable, Sendable {
        let action: GitFileAction
        let fileID: String
        let path: String
    }

    enum State: Equatable {
        case noProject
        /// A persisted project path is known, but the checkout has not been
        /// touched yet. Review uses this gate so opening the pane alone cannot
        /// trigger a macOS protected-folder prompt.
        case needsExplicitLoad(String)
        case loading
        case loaded(GitRepositorySnapshot)
        case empty(GitRepositorySnapshot)
        case notRepository
        case failed(String)
    }

    @Published private(set) var state: State = .noProject
    @Published private(set) var selectedScope: GitDiffScope = .unstaged
    @Published private(set) var selectedFileID: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var activeOperation: ActiveOperation?
    @Published private(set) var actionErrorMessage: String?

    private let reader: any GitRepositoryReading
    private var revision = 0
    private var operationRevision = 0
    private var projectPath: String?

    init(reader: any GitRepositoryReading = GitDiffViewerModel.makeLiveReader()) {
        self.reader = reader
    }

    var snapshot: GitRepositorySnapshot? {
        switch state {
        case let .loaded(snapshot), let .empty(snapshot): snapshot
        default: nil
        }
    }

    var selectedDiff: GitDiff? {
        guard let snapshot else { return nil }
        return selectedScope == .staged ? snapshot.staged : snapshot.unstaged
    }

    var selectedFile: GitDiffFile? {
        guard let selectedFileID else { return nil }
        return selectedDiff?.files.first { $0.id == selectedFileID }
    }

    func load(path: String?) async {
        await performLoad(path: path, isRefresh: false)
    }

    /// Updates the project shown by the inspector without reading it. The
    /// caller should invoke `load(path:)` only after an intentional,
    /// project-scoped user action.
    func prepare(path: String?) {
        let usablePath = Self.normalizedProjectPath(path)
        guard usablePath != projectPath || snapshot == nil else { return }
        revision += 1
        operationRevision += 1
        activeOperation = nil
        actionErrorMessage = nil
        isRefreshing = false
        projectPath = usablePath
        selectedFileID = nil
        state = usablePath.map(State.needsExplicitLoad) ?? .noProject
    }

    func refresh() async {
        guard activeOperation == nil else { return }
        await performLoad(path: projectPath, isRefresh: true)
    }

    func selectScope(_ scope: GitDiffScope) {
        selectedScope = scope
        selectFirstAvailableFile(preserving: selectedFileID)
    }

    func selectFile(id: String) {
        guard selectedDiff?.files.contains(where: { $0.id == id }) == true else { return }
        selectedFileID = id
    }

    func canPerform(_ action: GitFileAction, on fileID: String? = nil) -> Bool {
        guard activeOperation == nil,
              !isRefreshing,
              projectPath != nil,
              let file = file(for: fileID),
              let change = statusChange(for: file),
              !change.isConflict else { return false }

        return switch action {
        case .stage:
            selectedScope == .unstaged && change.isUnstaged
        case .unstage:
            selectedScope == .staged && change.isStaged
        case .discard:
            selectedScope == .unstaged && change.isUnstaged
        }
    }

    func requiresConflictResolution(on fileID: String? = nil) -> Bool {
        guard let file = file(for: fileID) else { return false }
        return statusChange(for: file)?.isConflict == true
    }

    func perform(_ action: GitFileAction, on fileID: String) async {
        guard canPerform(action, on: fileID),
              let file = file(for: fileID),
              let target = actionTarget(for: file),
              let projectPath else { return }

        operationRevision += 1
        let expectedOperationRevision = operationRevision
        // Any read already in flight describes the checkout before this
        // mutation and must not replace the post-action refresh.
        revision += 1
        isRefreshing = false
        actionErrorMessage = nil
        activeOperation = ActiveOperation(action: action, fileID: fileID, path: file.path)

        do {
            try await reader.perform(action, on: target, at: projectPath)
            guard self.projectPath == projectPath,
                  operationRevision == expectedOperationRevision else { return }
            activeOperation = nil
            await performLoad(path: projectPath, isRefresh: true)
        } catch {
            guard self.projectPath == projectPath,
                  operationRevision == expectedOperationRevision else { return }
            activeOperation = nil
            actionErrorMessage = error.localizedDescription
        }
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    private func performLoad(path: String?, isRefresh: Bool) async {
        let usablePath = Self.normalizedProjectPath(path)
        if activeOperation != nil, usablePath == projectPath { return }
        revision += 1
        let expectedRevision = revision
        let previousSelection = selectedFileID
        if projectPath != usablePath {
            operationRevision += 1
            activeOperation = nil
            actionErrorMessage = nil
        }
        projectPath = usablePath

        guard let usablePath else {
            isRefreshing = false
            selectedFileID = nil
            state = .noProject
            return
        }

        if isRefresh, snapshot != nil {
            isRefreshing = true
        } else {
            isRefreshing = false
            selectedFileID = nil
            state = .loading
        }

        do {
            let snapshot = try await reader.readSnapshot(at: usablePath)
            guard revision == expectedRevision, projectPath == usablePath else { return }
            isRefreshing = false
            let isEmpty = snapshot.staged.isEmpty && snapshot.unstaged.isEmpty
            state = isEmpty ? .empty(snapshot) : .loaded(snapshot)
            if selectedDiff?.files.isEmpty == true {
                if selectedScope == .unstaged, !snapshot.staged.files.isEmpty {
                    selectedScope = .staged
                } else if selectedScope == .staged, !snapshot.unstaged.files.isEmpty {
                    selectedScope = .unstaged
                }
            }
            selectFirstAvailableFile(preserving: previousSelection)
        } catch let error as GitRepositoryError {
            guard revision == expectedRevision, projectPath == usablePath else { return }
            isRefreshing = false
            if isRefresh, snapshot != nil {
                actionErrorMessage = "Could not refresh repository changes: \(error.localizedDescription)"
                return
            }
            selectedFileID = nil
            if case .notRepository = error {
                state = .notRepository
            } else {
                state = .failed(error.localizedDescription)
            }
        } catch {
            guard revision == expectedRevision, projectPath == usablePath else { return }
            isRefreshing = false
            if isRefresh, snapshot != nil {
                actionErrorMessage = "Could not refresh repository changes: \(error.localizedDescription)"
                return
            }
            selectedFileID = nil
            state = .failed(error.localizedDescription)
        }
    }

    private static func normalizedProjectPath(_ path: String?) -> String? {
        let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedPath.flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
        }
    }

    private func selectFirstAvailableFile(preserving fileID: String?) {
        let files = selectedDiff?.files ?? []
        if let fileID, files.contains(where: { $0.id == fileID }) {
            selectedFileID = fileID
        } else {
            selectedFileID = files.first?.id
        }
    }

    private func file(for fileID: String?) -> GitDiffFile? {
        let requestedID = fileID ?? selectedFileID
        guard let requestedID else { return nil }
        return selectedDiff?.files.first { $0.id == requestedID }
    }

    private func statusChange(for file: GitDiffFile) -> GitFileChange? {
        snapshot?.status.changes.first { $0.path == file.path }
    }

    private func actionTarget(for file: GitDiffFile) -> GitFileActionTarget? {
        guard let change = statusChange(for: file) else { return nil }
        let kind: GitDiffFileKind
        switch change.kind {
        case .renamed: kind = .renamed
        case .copied: kind = .copied
        default: kind = file.kind
        }
        return GitFileActionTarget(
            path: file.path,
            oldPath: change.oldPath ?? file.oldPath,
            kind: kind
        )
    }

    private static func makeLiveReader() -> any GitRepositoryReading {
        do {
            return try GitRepositoryReader()
        } catch {
            return UnavailableGitRepositoryReader(message: error.localizedDescription)
        }
    }
}

private struct UnavailableGitRepositoryReader: GitRepositoryReading {
    let message: String

    func readStatus(at _: String) async throws -> GitRepositoryStatus { throw Failure(message: message) }
    func readDiff(at _: String, scope _: GitDiffScope) async throws -> GitDiff { throw Failure(message: message) }
    func readSnapshot(at _: String) async throws -> GitRepositorySnapshot { throw Failure(message: message) }
    func perform(_: GitFileAction, on _: GitFileActionTarget, at _: String) async throws {
        throw Failure(message: message)
    }

    private struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
}

struct GitDiffRenderLimits: Equatable, Sendable {
    var maximumFiles = 200
    var maximumHunks = 80
    var maximumLines = 2_500
    var maximumMetadataLines = 24

    static let `default` = Self()
}

struct GitDiffRenderPlan: Equatable, Sendable {
    struct Hunk: Equatable, Sendable {
        let source: GitDiffHunk
        let lines: [GitDiffLine]
    }

    let files: [GitDiffFile]
    let hiddenFileCount: Int
    let hunks: [Hunk]
    let hiddenLineCount: Int
    let metadata: [String]
    let hiddenMetadataCount: Int

    init(diff: GitDiff, selectedFile: GitDiffFile?, limits: GitDiffRenderLimits = .default) {
        let fileLimit = max(1, limits.maximumFiles)
        files = Array(diff.files.prefix(fileLimit))
        hiddenFileCount = max(0, diff.files.count - files.count)

        guard let selectedFile else {
            hunks = []
            hiddenLineCount = 0
            metadata = []
            hiddenMetadataCount = 0
            return
        }

        let hunkLimit = max(1, limits.maximumHunks)
        let lineLimit = max(1, limits.maximumLines)
        var remainingLines = lineLimit
        var visibleHunks: [Hunk] = []
        var visibleLineCount = 0
        for hunk in selectedFile.hunks.prefix(hunkLimit) where remainingLines > 0 {
            let lines = Array(hunk.lines.prefix(remainingLines))
            visibleHunks.append(Hunk(source: hunk, lines: lines))
            visibleLineCount += lines.count
            remainingLines -= lines.count
        }
        hunks = visibleHunks
        hiddenLineCount = max(0, selectedFile.hunks.reduce(0) { $0 + $1.lines.count } - visibleLineCount)

        let metadataLimit = max(1, limits.maximumMetadataLines)
        metadata = Array(selectedFile.metadata.prefix(metadataLimit))
        hiddenMetadataCount = max(0, selectedFile.metadata.count - metadata.count)
    }
}

enum GitDiffAccessibility {
    static func lineLabel(_ line: GitDiffLine) -> String {
        let kind = switch line.kind {
        case .context: "Unchanged"
        case .addition: "Added"
        case .deletion: "Deleted"
        case .noNewline: "Notice"
        case .metadata: "Metadata"
        }
        let old = line.oldLineNumber.map { "old line \($0)" } ?? "no old line"
        let new = line.newLineNumber.map { "new line \($0)" } ?? "no new line"
        return "\(kind), \(old), \(new): \(line.content)"
    }

    static func fileLabel(_ file: GitDiffFile) -> String {
        let previous = file.oldPath.map { ", renamed from \($0)" } ?? ""
        let format = file.isBinary ? ", binary or preview unavailable" : ""
        return "\(file.path), \(file.kind.accessibilityName)\(previous)\(format), \(file.additions) additions, \(file.deletions) deletions"
    }
}

struct GitDiffViewerView: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation
    @StateObject private var diffModel = GitDiffViewerModel()
    @State private var showsFileNavigation = true
    @State private var pendingDiscard: GitDiffFile?

    private var projectPath: String? {
        model.selectedThread?.cwd ?? model.draftWorkspacePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            reviewHeader
            if !model.supports(.codeReview), model.session != nil {
                Label("This runtime does not support structured code review.", systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            stateContent
        }
        .task(id: projectPath) {
            // A task cwd may be inside a macOS protected folder. Merely
            // opening Review must not read it (and therefore must not trigger
            // a broad Documents permission prompt). The state gate below
            // gives the user an explicit project-scoped action instead.
            diffModel.prepare(path: projectPath)
        }
        .alert(
            "Discard file changes?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            presenting: pendingDiscard
        ) { file in
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
            Button(file.kind == .untracked ? "Move to Trash" : "Discard Changes", role: .destructive) {
                pendingDiscard = nil
                Task { await diffModel.perform(.discard, on: file.id) }
            }
        } message: { file in
            if file.kind == .untracked {
                Text("This moves \(file.path) to the Trash. Git cannot restore an untracked file, but you can recover it from the Trash.")
            } else {
                Text("This replaces the unstaged changes in \(file.path) with the staged or committed version. Onyx moves the current version to the Trash first.")
            }
        }
    }

    private var reviewHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Working tree review")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(reviewScopeLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                reviewButton
            }
            Text("Inspect, stage, unstage, or discard individual file changes. Ask \(model.runtimeDisplayName) to review the whole checkout.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .onyxPanel(radius: 10)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch diffModel.state {
        case .noProject:
            repositoryState(
                title: "No project selected",
                detail: "Choose a project to inspect its current Git changes.",
                icon: "folder.badge.questionmark"
            ) {
                Button("Choose Project") {
                    model.chooseWorkspace(window: windowPresentation.window)
                }
                .controlSize(.small)
            }
        case let .needsExplicitLoad(path):
            repositoryState(
                title: "Review \(URL(fileURLWithPath: path).lastPathComponent)",
                detail: "Onyx has not accessed \(path). Choose Inspect Changes to read this Git checkout. If it is under Documents, macOS may label its request “Documents Folder.”",
                icon: "hand.raised"
            ) {
                Button("Inspect Changes", systemImage: "arrow.triangle.branch") {
                    Task { await diffModel.load(path: path) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(OnyxTheme.iris)
                .accessibilityLabel("Inspect changes in \(URL(fileURLWithPath: path).lastPathComponent)")
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading repository changes…")
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading repository changes")
        case .notRepository:
            repositoryState(
                title: "Not a Git repository",
                detail: "The selected project does not contain a Git checkout.",
                icon: "arrow.triangle.branch"
            ) { refreshButton(label: "Try Again") }
        case let .failed(message):
            repositoryState(
                title: "Could not read changes",
                detail: message,
                icon: "exclamationmark.triangle"
            ) { refreshButton(label: "Try Again") }
        case let .empty(snapshot):
            repositorySummary(snapshot)
            repositoryState(
                title: "Working tree is clean",
                detail: "There are no staged, unstaged, or untracked changes to preview.",
                icon: "checkmark.circle"
            ) { refreshButton(label: "Refresh") }
        case let .loaded(snapshot):
            repositorySummary(snapshot)
            diffContent(snapshot)
        }
    }

    private func repositorySummary(_ snapshot: GitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(OnyxTheme.iris)
                    .accessibilityHidden(true)
                Text(branchName(snapshot.status.branch))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if diffModel.isRefreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing changes")
                } else {
                    refreshButton(label: "")
                }
            }
            Text(trackingLabel(snapshot.status.branch))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                countBadge("Staged", count: snapshot.status.stagedChanges.count, color: OnyxTheme.iris)
                countBadge(
                    "Unstaged",
                    count: snapshot.status.unstagedChanges.filter { !$0.isUntracked }.count,
                    color: OnyxTheme.warning
                )
                countBadge("Untracked", count: snapshot.status.untrackedChanges.count, color: OnyxTheme.electric)
            }
        }
        .padding(10)
        .onyxPanel(radius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository status")
    }

    private func diffContent(_ snapshot: GitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Change scope", selection: Binding(
                get: { diffModel.selectedScope },
                set: { scope in diffModel.selectScope(scope) }
            )) {
                Text("Staged (\(snapshot.staged.files.count))").tag(GitDiffScope.staged)
                Text("Unstaged (\(snapshot.unstaged.files.count))").tag(GitDiffScope.unstaged)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Change scope")

            if let diff = diffModel.selectedDiff, diff.files.isEmpty {
                repositoryState(
                    title: "No \(diff.scope.title.lowercased()) changes",
                    detail: "Choose the other scope or refresh after editing files.",
                    icon: "doc"
                ) { EmptyView() }
            } else if let diff = diffModel.selectedDiff {
                let plan = GitDiffRenderPlan(diff: diff, selectedFile: diffModel.selectedFile)
                actionFailureNotice
                fileNavigation(plan)
                if let file = diffModel.selectedFile {
                    selectedFileHeader(file)
                    fileDiff(file, plan: plan)
                }
            }
        }
    }

    private func fileNavigation(_ plan: GitDiffRenderPlan) -> some View {
        DisclosureGroup(isExpanded: $showsFileNavigation) {
            LazyVStack(spacing: 2) {
                ForEach(plan.files) { file in
                    Button {
                        diffModel.selectFile(id: file.id)
                    } label: {
                        HStack(spacing: 7) {
                            Text(file.kind.shortName)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(file.kind.color)
                                .frame(width: 14)
                            Text(file.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if !file.isBinary {
                                Text("+\(file.additions) −\(file.deletions)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 26)
                        .background(diffModel.selectedFileID == file.id ? OnyxTheme.iris.opacity(0.14) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(GitDiffAccessibility.fileLabel(file))
                    .accessibilityAddTraits(diffModel.selectedFileID == file.id ? .isSelected : [])
                }
                if plan.hiddenFileCount > 0 {
                    truncationNotice("\(plan.hiddenFileCount) additional changed files are hidden to keep this view responsive.")
                }
            }
            .padding(.top, 5)
        } label: {
            Text("Changed files")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .padding(9)
        .onyxPanel(radius: 9)
    }

    private func selectedFileHeader(_ file: GitDiffFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(file.path)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 5)
                    Text(file.kind.title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(file.kind.color)
                }
                if let oldPath = file.oldPath {
                    Text("from \(oldPath)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !file.isBinary {
                    Text("\(file.additions) additions · \(file.deletions) deletions")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GitDiffAccessibility.fileLabel(file))

            if !model.isSelectedThreadArchived {
                selectedFileActions(file)
            }
        }
        .padding(9)
        .onyxPanel(radius: 9)
    }

    @ViewBuilder
    private func selectedFileActions(_ file: GitDiffFile) -> some View {
        if let operation = diffModel.activeOperation, operation.fileID == file.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(operation.action.progressTitle)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(height: 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(operation.action.progressTitle) \(file.path)")
        } else if diffModel.requiresConflictResolution(on: file.id) {
            Label("Resolve this conflict before changing its Git state.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(OnyxTheme.warning)
                .onyxHelp("Resolve the conflict before staging, unstaging, or discarding this file")
                .accessibilityLabel("Resolve the conflict in \(file.path) before using Git actions")
        } else {
            HStack(spacing: 6) {
                if diffModel.selectedScope == .unstaged {
                    Button {
                        Task { await diffModel.perform(.stage, on: file.id) }
                    } label: {
                        Label("Stage", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .disabled(!diffModel.canPerform(.stage, on: file.id))
                    .onyxHelp("Stage all changes in \(file.path)")
                    .accessibilityLabel("Stage \(file.path)")

                    Button(role: .destructive) {
                        pendingDiscard = file
                    } label: {
                        Label("Discard…", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!diffModel.canPerform(.discard, on: file.id))
                    .onyxHelp("Discard all unstaged changes in \(file.path)")
                    .accessibilityLabel("Discard changes in \(file.path)")
                } else {
                    Button {
                        Task { await diffModel.perform(.unstage, on: file.id) }
                    } label: {
                        Label("Unstage", systemImage: "minus.rectangle")
                    }
                    .disabled(!diffModel.canPerform(.unstage, on: file.id))
                    .onyxHelp("Move \(file.path) back to unstaged changes")
                    .accessibilityLabel("Unstage \(file.path)")
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var actionFailureNotice: some View {
        if let message = diffModel.actionErrorMessage {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(OnyxTheme.destructive)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    diffModel.dismissActionError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .onyxHelp("Dismiss Git error")
                .accessibilityLabel("Dismiss Git error")
            }
            .padding(8)
            .background(OnyxTheme.destructive.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Git operation failed: \(message)")
        }
    }

    @ViewBuilder
    private func fileDiff(_ file: GitDiffFile, plan: GitDiffRenderPlan) -> some View {
        if file.isBinary || file.hunks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    file.isBinary ? "Binary or preview unavailable" : "No textual changes",
                    systemImage: file.isBinary ? "doc.badge.ellipsis" : "doc"
                )
                .font(.system(size: 11.5, weight: .semibold))
                Text(file.isBinary
                    ? "Onyx does not load this file into the text diff viewer."
                    : "Git reported metadata changes without a text hunk.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                metadata(plan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .onyxPanel(radius: 10)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                metadata(plan)
                ScrollView(.horizontal) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(plan.hunks.enumerated()), id: \.offset) { _, hunk in
                            hunkHeader(hunk.source)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                diffLine(line)
                            }
                        }
                    }
                    .frame(minWidth: 300, alignment: .leading)
                }
                .scrollIndicators(.visible)
                if plan.hiddenLineCount > 0 {
                    truncationNotice("\(plan.hiddenLineCount) additional diff lines are hidden. Open the file or narrow the change to inspect the rest.")
                        .padding(8)
                }
            }
            .onyxPanel(radius: 8)
        }
    }

    @ViewBuilder
    private func metadata(_ plan: GitDiffRenderPlan) -> some View {
        if !plan.metadata.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(plan.metadata.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if plan.hiddenMetadataCount > 0 {
                    Text("\(plan.hiddenMetadataCount) more metadata lines hidden")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
        }
    }

    private func hunkHeader(_ hunk: GitDiffHunk) -> some View {
        Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(hunk.heading.map { " \($0)" } ?? "")")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(OnyxTheme.electric)
            .padding(.horizontal, 7)
            .frame(minWidth: 300, minHeight: 25, alignment: .leading)
            .background(OnyxTheme.electric.opacity(0.09))
            .accessibilityLabel("Diff hunk, old lines \(hunk.oldStart) through \(hunk.oldStart + max(0, hunk.oldCount - 1)), new lines \(hunk.newStart) through \(hunk.newStart + max(0, hunk.newCount - 1))")
    }

    private func diffLine(_ line: GitDiffLine) -> some View {
        HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(line.newLineNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(line.kind.marker)
                .foregroundStyle(line.kind.markerColor)
                .frame(width: 20, alignment: .center)
            Text(line.content.isEmpty ? " " : line.content)
                .padding(.trailing, 8)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
        .frame(minWidth: 300, minHeight: 20, alignment: .leading)
        .background(line.kind.backgroundColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GitDiffAccessibility.lineLabel(line))
    }

    private func repositoryState<Actions: View>(
        title: String,
        detail: String,
        icon: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 11.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
    }

    private func countBadge(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text("\(title) \(count)")
        }
        .font(.system(size: 9.5, weight: .medium))
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background(color.opacity(0.11))
        .clipShape(Capsule())
        .accessibilityLabel("\(title), \(count) files")
    }

    private func truncationNotice(_ message: String) -> some View {
        Label(message, systemImage: "ellipsis.circle")
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func refreshButton(label: String) -> some View {
        if label.isEmpty {
            Button {
                Task { await diffModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
            }
            .controlSize(.small)
            .buttonStyle(.plain)
            .disabled(diffModel.isRefreshing)
            .onyxHelp("Refresh repository changes")
            .accessibilityLabel("Refresh repository changes")
        } else {
            Button {
                Task { await diffModel.refresh() }
            } label: {
                Label(label, systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(diffModel.isRefreshing)
            .onyxHelp("Refresh repository changes")
            .accessibilityLabel("Refresh repository changes")
        }
    }

    private var reviewScopeLabel: String {
        if model.isSelectedThreadArchived { return "Restore this task to run a review" }
        guard let thread = model.selectedThread, thread.id != "onyx:welcome" else {
            return "Select a task with a project"
        }
        guard let cwd = thread.cwd else { return "Current project checkout" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    @ViewBuilder
    private var reviewButton: some View {
        if model.isSelectedReviewStarting {
            reviewProgress("Starting")
        } else if model.isReviewRunning {
            reviewProgress("Reviewing")
        } else {
            Button("Ask \(model.runtimeDisplayName) to Review", action: model.startReview)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(OnyxTheme.iris)
                .disabled(!model.canStartReview)
                .onyxHelp("Review staged, unstaged, and untracked project changes")
        }
    }

    private func reviewProgress(_ title: String) -> some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text("\(title)…")
        }
        .font(.system(size: 10.5, weight: .medium))
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Review status")
        .accessibilityValue(title)
    }

    private func branchName(_ branch: GitBranchStatus) -> String {
        if branch.isDetached { return branch.description ?? "Detached HEAD" }
        return branch.name ?? "Current checkout"
    }

    private func trackingLabel(_ branch: GitBranchStatus) -> String {
        guard branch.upstream != nil || branch.ahead > 0 || branch.behind > 0 else {
            return "No upstream tracking information"
        }
        let upstream = branch.upstream.map { " vs \($0)" } ?? ""
        return "\(branch.ahead) ahead · \(branch.behind) behind\(upstream)"
    }
}

private extension GitDiffScope {
    var title: String { self == .staged ? "Staged" : "Unstaged" }
}

private extension GitFileAction {
    var progressTitle: String {
        switch self {
        case .stage: "Staging…"
        case .unstage: "Unstaging…"
        case .discard: "Discarding…"
        }
    }
}

private extension GitDiffFileKind {
    var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .unmerged: "Conflict"
        case .untracked: "Untracked"
        case .unknown: "Changed"
        }
    }

    var accessibilityName: String { title.lowercased() }

    var shortName: String {
        switch self {
        case .added, .untracked: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unmerged: "!"
        case .unknown: "?"
        }
    }

    var color: Color {
        switch self {
        case .added, .untracked: OnyxTheme.success
        case .deleted, .unmerged: OnyxTheme.destructive
        case .modified, .typeChanged: OnyxTheme.warning
        case .renamed, .copied: OnyxTheme.electric
        case .unknown: .secondary
        }
    }
}

private extension GitDiffLineKind {
    var marker: String {
        switch self {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .noNewline: "↳"
        case .metadata: "•"
        }
    }

    var markerColor: Color {
        switch self {
        case .addition: OnyxTheme.success
        case .deletion: OnyxTheme.destructive
        case .context, .noNewline, .metadata: .secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .addition: OnyxTheme.success.opacity(0.12)
        case .deletion: OnyxTheme.destructive.opacity(0.12)
        case .context: .clear
        case .noNewline, .metadata: OnyxTheme.warning.opacity(0.08)
        }
    }
}
