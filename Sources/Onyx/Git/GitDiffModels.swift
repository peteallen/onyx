import Foundation

/// The side of the Git index represented by a diff request.
///
/// `staged` reads the index against `HEAD`; `unstaged` reads the working tree
/// against the index.  Untracked files are represented in an unstaged diff as
/// synthetic add-only files by `GitRepositoryReader`.
enum GitDiffScope: String, Codable, CaseIterable, Hashable, Sendable {
    case staged
    case unstaged
}

/// A path-scoped working-copy operation exposed by the Git inspector.
///
/// These are deliberately whole-file operations. Hunk staging can be layered
/// on later without weakening the command boundary used for this first
/// writable slice.
enum GitFileAction: String, Codable, CaseIterable, Hashable, Sendable {
    case stage
    case unstage
    case discard
}

/// The immutable file identity captured when a user starts a Git operation.
/// Keeping both sides of a rename lets staging and unstaging update the
/// deletion and addition together without constructing a shell command.
struct GitFileActionTarget: Codable, Equatable, Hashable, Sendable {
    let path: String
    let oldPath: String?
    let kind: GitDiffFileKind

    init(path: String, oldPath: String? = nil, kind: GitDiffFileKind) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
    }

    init(file: GitDiffFile) {
        self.init(path: file.path, oldPath: file.oldPath, kind: file.kind)
    }

    var pathspecs: [String] {
        var paths = [path]
        if kind == .renamed, let oldPath, oldPath != path { paths.append(oldPath) }
        return paths
    }
}

/// A normalized interpretation of one of Git's two porcelain status columns.
/// Keeping this separate from the raw status character lets the UI and future
/// providers use the same model without knowing Git's wire format.
enum GitStatusState: String, Codable, Hashable, Sendable {
    case unchanged
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case unmerged
    case untracked
    case ignored
    case unknown

    init(rawCharacter: UInt8, untracked: Bool = false, ignored: Bool = false) {
        if untracked {
            self = .untracked
            return
        }
        if ignored {
            self = .ignored
            return
        }

        self = switch rawCharacter {
        case UInt8(ascii: " "): .unchanged
        case UInt8(ascii: "M"): .modified
        case UInt8(ascii: "A"): .added
        case UInt8(ascii: "D"): .deleted
        case UInt8(ascii: "R"): .renamed
        case UInt8(ascii: "C"): .copied
        case UInt8(ascii: "T"): .typeChanged
        case UInt8(ascii: "U"): .unmerged
        case UInt8(ascii: "?"): .untracked
        case UInt8(ascii: "!"): .ignored
        default: .unknown
        }
    }

    var isChanged: Bool {
        self != .unchanged
    }
}

/// The provider-neutral kind shown for a changed path.  For a rename with
/// additional worktree edits, `GitFileChange.kind` remains `.renamed` while
/// the two side-specific states preserve the extra detail.
enum GitChangeKind: String, Codable, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case unmerged
    case untracked
    case ignored
    case unknown
}

/// One record from `git status --porcelain=v1 -z`.
struct GitFileChange: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// The current path relative to the repository root, using `/` separators.
    let path: String
    /// The previous path for a rename or copy, if Git supplied one.
    let oldPath: String?
    let indexState: GitStatusState
    let worktreeState: GitStatusState

    init(
        path: String,
        oldPath: String? = nil,
        indexState: GitStatusState = .unchanged,
        worktreeState: GitStatusState = .unchanged
    ) {
        self.path = path
        self.oldPath = oldPath
        self.indexState = indexState
        self.worktreeState = worktreeState
    }

    var id: String {
        if let oldPath { return "\(oldPath)→\(path)" }
        return path
    }

    var kind: GitChangeKind {
        if indexState == .untracked || worktreeState == .untracked { return .untracked }
        if indexState == .ignored || worktreeState == .ignored { return .ignored }
        if indexState == .renamed || worktreeState == .renamed { return .renamed }
        if indexState == .copied || worktreeState == .copied { return .copied }
        if indexState == .unmerged || worktreeState == .unmerged { return .unmerged }
        if indexState == .added || worktreeState == .added { return .added }
        if indexState == .deleted || worktreeState == .deleted { return .deleted }
        if indexState == .typeChanged || worktreeState == .typeChanged { return .typeChanged }
        if indexState == .modified || worktreeState == .modified { return .modified }
        return .unknown
    }

    var isStaged: Bool {
        indexState.isChanged && indexState != .untracked && indexState != .ignored
    }

    var isUnstaged: Bool {
        worktreeState.isChanged || worktreeState == .untracked
    }

    var isUntracked: Bool {
        indexState == .untracked || worktreeState == .untracked
    }

    var isConflict: Bool {
        indexState == .unmerged || worktreeState == .unmerged
    }
}

/// Branch and ahead/behind information returned alongside file status.
struct GitBranchStatus: Codable, Equatable, Hashable, Sendable {
    let name: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    let isDetached: Bool
    let description: String?

    init(
        name: String?,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        isDetached: Bool = false,
        description: String? = nil
    ) {
        self.name = name
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isDetached = isDetached
        self.description = description
    }

    static let unknown = Self(name: nil, isDetached: false)
}

struct GitRepositoryStatus: Codable, Equatable, Sendable {
    let repositoryPath: String
    let branch: GitBranchStatus
    let changes: [GitFileChange]

    init(repositoryPath: String, branch: GitBranchStatus = .unknown, changes: [GitFileChange] = []) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.changes = changes
    }

    var hasChanges: Bool { !changes.isEmpty }
    var stagedChanges: [GitFileChange] { changes.filter(\.isStaged) }
    var unstagedChanges: [GitFileChange] { changes.filter(\.isUnstaged) }
    var untrackedChanges: [GitFileChange] { changes.filter(\.isUntracked) }
}

enum GitDiffLineKind: String, Codable, Hashable, Sendable {
    case context
    case addition
    case deletion
    /// The `\\ No newline at end of file` marker emitted by Git.
    case noNewline
    /// A non-hunk patch metadata line retained for consumers that want to
    /// render the raw patch (for example, binary patch metadata).
    case metadata
}

struct GitDiffLine: Identifiable, Codable, Equatable, Hashable, Sendable {
    let kind: GitDiffLineKind
    let content: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    init(
        kind: GitDiffLineKind,
        content: String,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil
    ) {
        self.kind = kind
        self.content = content
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }

    var id: String {
        let old = oldLineNumber.map(String.init) ?? "-"
        let new = newLineNumber.map(String.init) ?? "-"
        return "\(old):\(new):\(kind.rawValue):\(content)"
    }
}

struct GitDiffHunk: Identifiable, Codable, Equatable, Hashable, Sendable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let heading: String?
    let lines: [GitDiffLine]

    init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        heading: String? = nil,
        lines: [GitDiffLine] = []
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.heading = heading
        self.lines = lines
    }

    var id: String {
        "\(oldStart),\(oldCount)-\(newStart),\(newCount)-\(heading ?? "")"
    }

    var additions: Int { lines.reduce(into: 0) { if $1.kind == .addition { $0 += 1 } } }
    var deletions: Int { lines.reduce(into: 0) { if $1.kind == .deletion { $0 += 1 } } }
}

enum GitDiffFileKind: String, Codable, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case unmerged
    case untracked
    case unknown
}

struct GitDiffFile: Identifiable, Codable, Equatable, Hashable, Sendable {
    let path: String
    let oldPath: String?
    let kind: GitDiffFileKind
    let isBinary: Bool
    let hunks: [GitDiffHunk]
    /// Metadata lines outside hunks (mode changes, rename headers, binary
    /// patch markers, and similar). They are kept separate from source lines.
    let metadata: [String]

    init(
        path: String,
        oldPath: String? = nil,
        kind: GitDiffFileKind = .modified,
        isBinary: Bool = false,
        hunks: [GitDiffHunk] = [],
        metadata: [String] = []
    ) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.isBinary = isBinary
        self.hunks = hunks
        self.metadata = metadata
    }

    var id: String {
        if let oldPath { return "\(oldPath)→\(path)" }
        return path
    }

    var additions: Int { hunks.reduce(into: 0) { $0 += $1.additions } }
    var deletions: Int { hunks.reduce(into: 0) { $0 += $1.deletions } }
}

struct GitDiff: Identifiable, Codable, Equatable, Sendable {
    let scope: GitDiffScope
    let files: [GitDiffFile]

    init(scope: GitDiffScope, files: [GitDiffFile] = []) {
        self.scope = scope
        self.files = files
    }

    var id: String { scope.rawValue }
    var isEmpty: Bool { files.isEmpty }
    var additions: Int { files.reduce(into: 0) { $0 += $1.additions } }
    var deletions: Int { files.reduce(into: 0) { $0 += $1.deletions } }
}

struct GitRepositorySnapshot: Codable, Equatable, Sendable {
    let status: GitRepositoryStatus
    let staged: GitDiff
    let unstaged: GitDiff

    init(status: GitRepositoryStatus, staged: GitDiff, unstaged: GitDiff) {
        self.status = status
        self.staged = staged
        self.unstaged = unstaged
    }
}

enum GitRepositoryError: LocalizedError, Equatable, Sendable {
    case invalidRepositoryPath(String)
    case invalidChangePath(String)
    case changeNoLongerAvailable(String)
    case conflictedChange(String)
    case discardFailed(path: String, message: String)
    case gitExecutableNotFound
    case notRepository(String)
    case commandFailed(arguments: [String], exitCode: Int32, message: String)
    case timedOut(arguments: [String], timeout: TimeInterval)
    case outputLimitExceeded(arguments: [String], limit: Int)
    case malformedStatus(String)
    case malformedDiff(String)
    case unreadableFile(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRepositoryPath(path):
            return "The project folder is not available: \(path)"
        case let .invalidChangePath(path):
            return "The changed file is outside the project: \(path)"
        case let .changeNoLongerAvailable(path):
            return "The Git state for \(path) changed. Refresh and try again."
        case let .conflictedChange(path):
            return "Resolve the conflict in \(path) before staging, unstaging, or discarding it."
        case let .discardFailed(path, message):
            return "Could not safely discard \(path): \(message)"
        case .gitExecutableNotFound:
            return "Git is not installed or could not be located."
        case let .notRepository(path):
            return "The project is not a Git repository: \(path)"
        case let .commandFailed(arguments, exitCode, message):
            let detail = message.isEmpty ? "Git exited with status \(exitCode)." : message
            return "Git command failed (\(arguments.joined(separator: " "))): \(detail)"
        case let .timedOut(arguments, timeout):
            return "Git command timed out after \(timeout)s: \(arguments.joined(separator: " "))"
        case let .outputLimitExceeded(arguments, limit):
            return "Git output exceeded the \(limit)-byte safety limit: \(arguments.joined(separator: " "))"
        case let .malformedStatus(message):
            return "Git returned malformed status data: \(message)"
        case let .malformedDiff(message):
            return "Git returned malformed diff data: \(message)"
        case let .unreadableFile(path, message):
            return "Could not read untracked file \(path): \(message)"
        }
    }
}
