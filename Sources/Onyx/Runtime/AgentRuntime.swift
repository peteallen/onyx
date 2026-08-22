import Foundation

protocol AgentRuntime: Sendable {
    var kind: AgentRuntimeKind { get }
    var events: AsyncStream<AgentRuntimeEvent> { get }

    func connect() async throws -> RuntimeSession
    func disconnect() async
    func startLogin(methodID: String) async throws -> RuntimeLoginStart
    func cancelLogin(id: String) async throws
    func logout() async throws
    func refreshAccount() async throws -> RuntimeSession
    func listThreads(limit: Int, archived: Bool) async throws -> [RuntimeThread]
    func readThread(id: String) async throws -> RuntimeConversation
    func resumeThread(id: String) async throws -> RuntimeConversation
    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread
    func forkThread(id: String) async throws -> RuntimeThread
    func compactThread(id: String) async throws
    func deleteThread(id: String) async throws
    func startTurn(_ request: StartTurnRequest) async throws
    func startReview(_ request: StartReviewRequest) async throws -> RuntimeReviewRun
    func steer(threadID: String, text: String) async throws
    func steer(threadID: String, inputs: [RuntimeTurnInput]) async throws
    func interrupt(threadID: String) async throws
    func respond(to interactionID: RuntimeRequestID, with response: RuntimeUserInteractionResponse) async throws
    func renameThread(id: String, name: String) async throws
    func archiveThread(id: String) async throws
    func unarchiveThread(id: String) async throws
}

extension AgentRuntime {
    func steer(threadID: String, inputs: [RuntimeTurnInput]) async throws {
        guard inputs.allSatisfy({ if case .text = $0 { true } else { false } }) else {
            throw AgentRuntimeError.unsupported("image input")
        }
        let text = inputs.compactMap { input -> String? in
            guard case let .text(text) = input else { return nil }
            return text
        }.joined(separator: "\n")
        try await steer(threadID: threadID, text: text)
    }

    func startReview(_: StartReviewRequest) async throws -> RuntimeReviewRun {
        throw AgentRuntimeError.unsupported("code review")
    }

    func startLogin(methodID _: String) async throws -> RuntimeLoginStart {
        throw AgentRuntimeError.unsupported("account login")
    }

    func cancelLogin(id _: String) async throws {
        throw AgentRuntimeError.unsupported("canceling login")
    }

    func logout() async throws {
        throw AgentRuntimeError.unsupported("logout")
    }

    func refreshAccount() async throws -> RuntimeSession {
        try await connect()
    }

    func listThreads(limit: Int) async throws -> [RuntimeThread] {
        try await listThreads(limit: limit, archived: false)
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await readThread(id: id)
    }

    func forkThread(id _: String) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("thread forking")
    }

    func compactThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("thread compaction")
    }

    func deleteThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("thread deletion")
    }
}

enum AgentRuntimeError: LocalizedError, Sendable {
    case executableNotFound
    case processExited(Int32)
    case protocolFailure(String)
    case requestFailed(code: Int, message: String)
    case missingField(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Onyx could not find a Codex runtime. Install ChatGPT/Codex or set ONYX_CODEX_PATH."
        case let .processExited(code):
            "Codex app-server stopped unexpectedly (exit \(code))."
        case let .protocolFailure(message):
            "Codex protocol error: \(message)"
        case let .requestFailed(code, message):
            "Codex request failed (\(code)): \(message)"
        case let .missingField(field):
            "Codex response was missing \(field)."
        case let .unsupported(feature):
            "This runtime does not support \(feature)."
        }
    }
}
