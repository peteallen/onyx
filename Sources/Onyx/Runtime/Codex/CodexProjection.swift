import Foundation

enum CodexProjection {
    private static let maximumProjectedDataURLCharacters = 24 * 1_024 * 1_024 * 4 / 3 + 512
    private static let maximumTurnFailureCharacters = 2_000

    static func thread(from value: JSONValue) -> RuntimeThread? {
        guard let id = value["id"]?.stringValue else { return nil }

        let preview = firstString(
            value["preview"]?.stringValue,
            value["name"]?.stringValue,
            value["title"]?.stringValue,
            "Untitled task"
        )
        let title = firstString(
            value["name"]?.stringValue,
            value["title"]?.stringValue,
            preview.firstNonemptyLine,
            "Untitled task"
        )

        return RuntimeThread(
            id: id,
            title: title,
            preview: preview,
            cwd: value["cwd"]?.stringValue,
            updatedAt: date(from: value["updatedAt"] ?? value["updated_at"]) ?? .distantPast,
            status: status(from: value["status"]),
            isPinned: value["isPinned"]?.boolValue ?? value["pinned"]?.boolValue ?? false,
            runtime: .codex,
            model: value["model"]?.stringValue,
            branch: value["gitInfo"]?["branch"]?.stringValue ?? value["branch"]?.stringValue
        )
    }

    static func conversation(from result: JSONValue) throws -> RuntimeConversation {
        let threadValue = result["thread"] ?? result
        guard let thread = thread(from: threadValue) else {
            throw AgentRuntimeError.missingField("thread.id")
        }

        let turns = threadValue["turns"]?.arrayValue ?? []
        var items: [TimelineItem] = []
        var projectedTurns: [RuntimeConversationTurn] = []
        for turn in turns {
            let fallbackTimestamp = date(from: turn["startedAt"])
                ?? date(from: turn["completedAt"])
                ?? thread.updatedAt
            if let projectedTurn = conversationTurn(
                from: turn,
                fallbackTimestamp: fallbackTimestamp
            ) {
                projectedTurns.append(projectedTurn)
                items.append(contentsOf: projectedTurn.items)
            } else {
                // Keep the historical flat projection tolerant of malformed
                // turns, even though turn-aware operations require a stable
                // turn ID and therefore omit that turn from `turns`.
                items.append(contentsOf: (turn["items"]?.arrayValue ?? []).map {
                    timelineItem(
                        from: $0,
                        fallbackTimestamp: fallbackTimestamp
                    )
                })
            }
        }
        return RuntimeConversation(
            thread: thread,
            items: items,
            turns: projectedTurns
        )
    }

    static func historyPage(
        from result: JSONValue,
        direction: RuntimeHistoryDirection
    ) throws -> RuntimeThreadHistoryPage {
        guard let values = result["data"]?.arrayValue ?? result.arrayValue else {
            throw AgentRuntimeError.missingField("thread/turns/list.data")
        }
        let turns = try values.map { value in
            guard let turn = conversationTurn(from: value) else {
                throw AgentRuntimeError.missingField("thread/turns/list.data[].id")
            }
            return turn
        }
        return RuntimeThreadHistoryPage(
            turns: turns,
            nextCursor: result["nextCursor"]?.stringValue,
            backwardsCursor: result["backwardsCursor"]?.stringValue,
            direction: direction
        )
    }

    static func conversationTurn(
        from value: JSONValue,
        fallbackTimestamp inheritedFallbackTimestamp: Date? = nil
    ) -> RuntimeConversationTurn? {
        guard let id = value["id"]?.stringValue else { return nil }
        let status = conversationTurnStatus(from: value["status"]?.stringValue)
        let startedAt = date(from: value["startedAt"])
        let completedAt = date(from: value["completedAt"])
        let fallbackTimestamp = startedAt ?? completedAt ?? inheritedFallbackTimestamp
        let defaultItemStatus: TimelineItemStatus = switch status {
        case .inProgress: .running
        case .failed: .failed
        case .completed, .interrupted, .unknown: .completed
        }
        var items = (value["items"]?.arrayValue ?? []).map {
            timelineItem(
                from: $0,
                defaultStatus: defaultItemStatus,
                fallbackTimestamp: fallbackTimestamp
            )
        }
        if let failure = turnFailureTimelineItem(
            from: value,
            fallbackTimestamp: fallbackTimestamp
        ), !items.contains(where: { $0.kind == .error }) {
            items.append(failure)
        }
        return RuntimeConversationTurn(
            id: id,
            items: items,
            status: status,
            itemDetail: turnItemDetail(from: value["itemsView"]?.stringValue),
            startedAt: startedAt,
            completedAt: completedAt,
            durationMilliseconds: value["durationMs"]?.intValue
        )
    }

    private static func conversationTurnStatus(from rawValue: String?) -> RuntimeConversationTurnStatus {
        switch rawValue {
        case "completed": .completed
        case "interrupted": .interrupted
        case "failed": .failed
        case "inProgress": .inProgress
        case let value?: .unknown(value)
        case nil: .unknown("unknown")
        }
    }

    static func turnFailureMessage(from value: JSONValue) -> String? {
        let candidates = [
            value["error"]?["message"]?.stringValue,
            value["error"]?.stringValue,
            value["message"]?.stringValue,
        ]
        return candidates.lazy.compactMap(boundedTurnFailureMessage).first
    }

    static func turnFailureTimelineItem(
        from value: JSONValue,
        fallbackTurnID: String? = nil,
        fallbackMessage: String? = nil,
        fallbackTimestamp: Date? = nil
    ) -> TimelineItem? {
        let isFailedTurn = value["status"]?.stringValue?.lowercased() == "failed"
        guard isFailedTurn || fallbackMessage != nil,
              let turnID = value["id"]?.stringValue ?? fallbackTurnID else { return nil }
        let message = turnFailureMessage(from: value)
            ?? boundedTurnFailureMessage(fallbackMessage)
            ?? "The provider stopped before completing this response."
        let timestamp = date(from: value["completedAt"])
            ?? date(from: value["startedAt"])
            ?? fallbackTimestamp
            ?? .distantPast
        return TimelineItem(
            id: "codex-turn-error:\(turnID)",
            kind: .error,
            title: "Response failed",
            body: message,
            status: .failed,
            timestamp: timestamp,
            detail: nil
        )
    }

    private static func boundedTurnFailureMessage(_ raw: String?) -> String? {
        guard let raw, let safe = safeTextCandidate(raw) else { return nil }
        return boundedText(safe, maximumCharacters: maximumTurnFailureCharacters)
    }

    private static func turnItemDetail(from rawValue: String?) -> RuntimeTurnItemDetail {
        switch rawValue {
        case "notLoaded": .notLoaded
        case "summary": .summary
        case "full", nil: .full
        case let value?: .unknown(value)
        }
    }

    static func threadLifecycleEvent(from notification: AppServerNotification) -> AgentRuntimeEvent? {
        let params = notification.params
        guard let threadID = params["threadId"]?.stringValue else { return nil }

        switch notification.method {
        case "thread/name/updated":
            return .threadNameChanged(threadID: threadID, name: params["threadName"]?.stringValue)
        case "thread/status/changed":
            return .threadStatusChanged(threadID: threadID, status: status(from: params["status"]))
        case "thread/archived":
            return .threadArchived(threadID: threadID)
        case "thread/unarchived":
            return .threadUnarchived(threadID: threadID)
        case "thread/deleted":
            return .threadDeleted(threadID: threadID)
        case "thread/reverted":
            return .threadRefreshRequested(threadID: threadID)
        default:
            return nil
        }
    }

    static func timelineItem(
        from value: JSONValue,
        defaultStatus: TimelineItemStatus = .completed,
        fallbackTimestamp: Date? = nil
    ) -> TimelineItem {
        let type = value["type"]?.stringValue ?? "unknown"
        let id = value["id"]?.stringValue ?? UUID().uuidString
        let status = itemStatus(from: value["status"]?.stringValue, default: defaultStatus)
        let timestamp = date(from: value["createdAt"] ?? value["timestamp"])
            ?? fallbackTimestamp
            ?? .now

        switch type {
        case "userMessage":
            let attachments = messageImageAttachments(from: value, itemID: id)
            return .init(
                id: id,
                kind: .userMessage,
                title: nil,
                // Attachments are rendered as native previews below the
                // message. Keep the body as exact text evidence: image-only
                // turns have an empty body, while a literal phrase such as
                // "[Image attachment]" remains editable text.
                body: messageText(from: value),
                status: status,
                timestamp: timestamp,
                detail: nil,
                attachments: attachments
            )
        case "agentMessage":
            return .init(
                id: id,
                kind: .assistantMessage,
                title: nil,
                body: firstString(value["text"]?.stringValue, value["message"]?.stringValue, messageText(from: value)),
                status: status,
                timestamp: timestamp,
                detail: value["phase"]?.stringValue
            )
        case "reasoning":
            return .init(
                id: id,
                kind: .reasoning,
                title: "Reasoning",
                body: reasoningText(from: value),
                status: status,
                timestamp: timestamp,
                detail: nil
            )
        case "commandExecution":
            let command = commandText(from: value)
            let output = firstString(
                value["aggregatedOutput"]?.stringValue,
                value["output"]?.stringValue
            )
            return .init(
                id: id,
                kind: .command,
                title: command.isEmpty ? "Ran command" : command,
                body: output,
                status: status,
                timestamp: timestamp,
                detail: value["cwd"]?.stringValue
            )
        case "fileChange":
            let changes = value["changes"]?.arrayValue ?? []
            let paths = changes.compactMap { $0["path"]?.stringValue }
            return .init(
                id: id,
                kind: .fileChange,
                title: paths.isEmpty ? "Changed files" : paths.joined(separator: ", "),
                body: changes.compactMap { $0["diff"]?.stringValue }.joined(separator: "\n"),
                status: status,
                timestamp: timestamp,
                detail: "\(changes.count) file\(changes.count == 1 ? "" : "s")"
            )
        case "dynamicToolCall" where value["tool"]?.stringValue == "onyx_delegate":
            return onyxDelegationTimelineItem(
                from: value,
                id: id,
                status: status,
                timestamp: timestamp
            )
        case "mcpToolCall", "dynamicToolCall", "webSearch":
            let attachments = toolImageAttachments(from: value, itemID: id)
            let links = toolLinks(from: value, itemID: id)
            return .init(
                id: id,
                kind: .tool,
                title: toolTitle(from: value, fallback: type),
                body: toolBody(
                    from: value,
                    attachmentCount: attachments.count,
                    linkCount: links.count
                ),
                status: status,
                timestamp: timestamp,
                detail: value["server"]?.stringValue,
                attachments: attachments,
                links: links
            )
        case "collabAgentToolCall":
            return collaborationToolTimelineItem(
                from: value,
                id: id,
                status: status,
                timestamp: timestamp
            )
        case "subAgentActivity":
            return subAgentActivityTimelineItem(
                from: value,
                id: id,
                status: status,
                timestamp: timestamp
            )
        case "imageView":
            let attachments = imageViewAttachments(from: value, itemID: id)
            return .init(
                id: id,
                kind: .tool,
                title: "Viewed image",
                body: attachments.isEmpty ? "The image path was unavailable." : "Opened an image preview.",
                status: attachments.isEmpty ? .failed : status,
                timestamp: timestamp,
                detail: safePathDetail(value["path"]?.stringValue),
                attachments: attachments
            )
        case "imageGeneration":
            return imageGenerationTimelineItem(
                from: value,
                id: id,
                defaultStatus: status,
                timestamp: timestamp
            )
        case "plan":
            return .init(
                id: id,
                kind: .plan,
                title: "Plan",
                body: firstString(value["text"]?.stringValue, value["plan"]?.compactDescription),
                status: status,
                timestamp: timestamp,
                detail: nil
            )
        case "contextCompaction":
            return .init(
                id: id,
                kind: .system,
                title: "Conversation compacted",
                body: "Earlier messages were condensed so the task can keep moving within its context window.",
                status: status,
                timestamp: timestamp,
                detail: "Context management"
            )
        case "enteredReviewMode":
            return .init(
                id: id,
                kind: .system,
                title: "Code review started",
                body: firstString(
                    value["review"]?.stringValue,
                    "Codex is reviewing the project changes."
                ),
                status: status,
                timestamp: timestamp,
                detail: "Working tree"
            )
        case "exitedReviewMode":
            return .init(
                id: id,
                kind: .system,
                title: "Code review completed",
                body: firstString(
                    value["review"]?.stringValue,
                    "Codex finished reviewing the project changes."
                ),
                status: status,
                timestamp: timestamp,
                detail: "Working tree"
            )
        case "error":
            return .init(
                id: id,
                kind: .error,
                title: "Runtime error",
                body: firstString(value["message"]?.stringValue, value.compactDescription),
                status: .failed,
                timestamp: timestamp,
                detail: nil
            )
        default:
            return .init(
                id: id,
                kind: .system,
                title: humanized(type),
                body: value.compactDescription,
                status: status,
                timestamp: timestamp,
                detail: type
            )
        }
    }

    static func plan(from value: JSONValue) -> RuntimePlan? {
        guard let turnID = value["turnId"]?.stringValue,
              let rawSteps = value["plan"]?.arrayValue else { return nil }

        var steps: [RuntimePlanStep] = []
        steps.reserveCapacity(rawSteps.count)
        for rawStep in rawSteps {
            guard let text = rawStep["step"]?.stringValue,
                  let rawStatus = rawStep["status"]?.stringValue else { return nil }
            steps.append(RuntimePlanStep(text: text, status: RuntimePlanStepStatus(rawValue: rawStatus)))
        }

        let explanation = value["explanation"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RuntimePlan(
            turnID: turnID,
            explanation: explanation?.isEmpty == false ? explanation : nil,
            steps: steps
        )
    }

    static func userInteraction(from request: AppServerRequest) -> RuntimeUserInteraction? {
        let params = request.params
        let threadID = params["threadId"]?.stringValue ?? params["conversationId"]?.stringValue
        let command = commandText(from: request.params)
        let reason = firstString(
            params["reason"]?.stringValue,
            params["message"]?.stringValue,
            params["prompt"]?.stringValue
        )

        switch request.method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let networkContext = params["networkApprovalContext"]
            let host = networkContext?["host"]?.stringValue
            let networkDetail = host.map { host in
                let transport = networkContext?["protocol"]?.stringValue?.uppercased() ?? "Network"
                return "Network request: \(transport) \(host)."
            }
            let isNetworkRequest = host != nil
            let targetDetail = isNetworkRequest ? networkDetail : nil
            let additionalPermissionsDetail = permissionSummaryIfPresent(
                from: params["additionalPermissions"]
            )
            let cwdDetail = params["cwd"]?.stringValue.map { "Working directory: \($0)." }
            let environmentDetail = params["environmentId"]?.stringValue.map { "Environment: \($0)." }
            let detail = [reason, cwdDetail, environmentDetail, targetDetail, additionalPermissionsDetail]
                .compactMap { $0 }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            return .init(
                id: request.id,
                threadID: threadID,
                providerMethod: request.method,
                title: isNetworkRequest ? "Allow network access?" : "Run this command?",
                detail: firstString(detail, isNetworkRequest ? nil : command, "Codex needs approval to continue."),
                kind: .approval(
                    RuntimeApprovalPrompt(
                        subject: isNetworkRequest ? .network : .command,
                        command: command.isEmpty || isNetworkRequest ? nil : command,
                        allowedDecisions: allowedApprovalDecisions(from: params)
                    )
                )
            )

        case "item/fileChange/requestApproval", "applyPatchApproval":
            let files = params["fileChanges"]?.objectValue?.keys.sorted().joined(separator: ", ")
            let detail = [reason, files, params["grantRoot"]?.stringValue]
                .compactMap { $0 }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
            return .init(
                id: request.id,
                threadID: threadID,
                providerMethod: request.method,
                title: "Apply these changes?",
                detail: firstString(detail, "Codex wants to change files."),
                kind: .approval(
                    RuntimeApprovalPrompt(
                        subject: .fileChanges,
                        command: nil
                    )
                )
            )

        case "item/permissions/requestApproval":
            let permissionDetail = permissionSummary(from: params["permissions"])
            let cwdDetail = params["cwd"]?.stringValue.map { "Working directory: \($0)." }
            let environmentDetail = params["environmentId"]?.stringValue.map { "Environment: \($0)." }
            let detail = [reason, cwdDetail, environmentDetail, permissionDetail]
                .compactMap { $0 }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            return .init(
                id: request.id,
                threadID: threadID,
                providerMethod: request.method,
                title: "Grant additional access?",
                detail: firstString(detail, "Codex needs additional access to continue."),
                kind: .approval(
                    RuntimeApprovalPrompt(
                        subject: .permissions,
                        command: nil
                    )
                )
            )

        case "item/tool/requestUserInput":
            let questions = (params["questions"]?.arrayValue ?? []).compactMap(question(from:))
            let questionIDs = questions.map(\.id)
            let hasDuplicateIDs = Set(questionIDs).count != questionIDs.count
            return .init(
                id: request.id,
                threadID: threadID,
                providerMethod: request.method,
                title: questions.count == 1 ? questions[0].header : "A few details are needed",
                detail: questions.count == 1 ? questions[0].prompt : "Answer these so Codex can continue.",
                kind: questions.isEmpty || hasDuplicateIDs
                    ? .unsupported
                    : .questions(
                        RuntimeQuestionPrompt(
                            questions: questions,
                            isBlocking: params["isBlocking"]?.boolValue ?? true
                        )
                    )
            )

        case "mcpServer/elicitation/request":
            let sourceName = params["serverName"]?.stringValue
            let message = firstString(params["message"]?.stringValue, "An MCP tool needs input to continue.")
            switch params["mode"]?.stringValue {
            case "url":
                guard let rawURL = params["url"]?.stringValue,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http" else {
                    return .init(
                        id: request.id,
                        threadID: threadID,
                        providerMethod: request.method,
                        title: "Input needed",
                        detail: message,
                        kind: .unsupported
                    )
                }
                return .init(
                    id: request.id,
                    threadID: threadID,
                    providerMethod: request.method,
                    title: sourceName.map { "Continue with \($0)" } ?? "Continue in your browser",
                    detail: message,
                    kind: .externalLink(RuntimeExternalLinkPrompt(sourceName: sourceName, url: url))
                )
            case "form":
                return .init(
                    id: request.id,
                    threadID: threadID,
                    providerMethod: request.method,
                    title: sourceName.map { "\($0) needs input" } ?? "Input needed",
                    detail: message,
                    kind: .form(
                        RuntimeFormPrompt(
                            sourceName: sourceName,
                            fields: formFields(from: params["requestedSchema"])
                        )
                    )
                )
            default:
                // `openai/form` is only sent to clients that advertise the
                // matching capability. Onyx does not opt in until it has the
                // provider-hosted form renderer needed to handle it safely.
                return .init(
                    id: request.id,
                    threadID: threadID,
                    providerMethod: request.method,
                    title: "Input needed",
                    detail: message,
                    kind: .unsupported
                )
            }

        default:
            return nil
        }
    }

    private static func question(from value: JSONValue) -> RuntimeQuestion? {
        guard let id = value["id"]?.stringValue,
              let prompt = value["question"]?.stringValue else { return nil }
        let options = (value["options"]?.arrayValue ?? []).compactMap { option -> RuntimeQuestionOption? in
            guard let label = option["label"]?.stringValue else { return nil }
            return RuntimeQuestionOption(
                label: label,
                detail: option["description"]?.stringValue ?? ""
            )
        }
        return RuntimeQuestion(
            id: id,
            header: firstString(value["header"]?.stringValue, "Question"),
            prompt: prompt,
            options: options,
            allowsOther: value["isOther"]?.boolValue ?? false,
            isSecret: value["isSecret"]?.boolValue ?? false
        )
    }

    private static func formFields(from schema: JSONValue?) -> [RuntimeFormField] {
        guard let properties = schema?["properties"]?.objectValue else { return [] }
        let required = Set(schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])

        return properties.sorted(by: { $0.key < $1.key }).map { id, field in
            RuntimeFormField(
                id: id,
                label: firstString(field["title"]?.stringValue, humanized(id)),
                detail: field["description"]?.stringValue,
                isRequired: required.contains(id),
                kind: formFieldKind(from: field),
                initialValue: formValue(from: field["default"])
            )
        }
    }

    private static func formFieldKind(from field: JSONValue) -> RuntimeFormField.Kind {
        let type = field["type"]?.stringValue
        if type == "boolean" { return .toggle }
        if type == "number" { return .number(integerOnly: false) }
        if type == "integer" { return .number(integerOnly: true) }

        if type == "array" {
            let choices = formChoices(from: field["items"])
            return choices.isEmpty ? .text(format: nil) : .multipleChoice(choices)
        }

        let choices = formChoices(from: field)
        if !choices.isEmpty { return .singleChoice(choices) }
        return .text(format: field["format"]?.stringValue)
    }

    private static func formChoices(from field: JSONValue?) -> [RuntimeFormChoice] {
        if let values = field?["enum"]?.arrayValue {
            let labels = field?["enumNames"]?.arrayValue ?? []
            return values.enumerated().compactMap { index, value in
                guard let value = value.stringValue else { return nil }
                return RuntimeFormChoice(
                    value: value,
                    label: labels.indices.contains(index)
                        ? firstString(labels[index].stringValue, value)
                        : value
                )
            }
        }
        let choices = field?["oneOf"]?.arrayValue ?? field?["anyOf"]?.arrayValue ?? []
        return choices.compactMap { choice in
            guard let value = choice["const"]?.stringValue ?? choice["value"]?.stringValue else { return nil }
            return RuntimeFormChoice(
                value: value,
                label: firstString(choice["title"]?.stringValue, value)
            )
        }
    }

    private static func formValue(from value: JSONValue?) -> RuntimeFormValue? {
        guard let value else { return nil }
        switch value {
        case let .string(value): return .string(value)
        case let .integer(value): return .integer(value)
        case let .number(value): return .number(value)
        case let .bool(value): return .boolean(value)
        case let .array(values): return .strings(values.compactMap(\.stringValue))
        case .object, .null: return nil
        }
    }

    private static func permissionSummary(from permissions: JSONValue?) -> String {
        guard let permissions else { return "Codex requested additional permissions." }
        var parts: [String] = []
        if let networkEnabled = permissions["network"]?["enabled"]?.boolValue {
            parts.append(networkEnabled ? "network access" : "network access disabled")
        }
        if let fileSystem = permissions["fileSystem"] {
            var readTargets = permissionTargets(from: fileSystem["read"])
            var writeTargets = permissionTargets(from: fileSystem["write"])
            var deniedTargets: [String] = []
            let entries = fileSystem["entries"]?.arrayValue ?? []
            for entry in entries {
                let targets = permissionTargets(from: entry["path"])
                switch entry["access"]?.stringValue {
                case "read": readTargets.append(contentsOf: targets)
                case "write": writeTargets.append(contentsOf: targets)
                case "deny": deniedTargets.append(contentsOf: targets)
                default: break
                }
            }
            if !readTargets.isEmpty {
                parts.append(permissionPart("additional file reads", targets: readTargets))
            }
            if !writeTargets.isEmpty {
                parts.append(permissionPart("additional file writes", targets: writeTargets))
            }
            if !deniedTargets.isEmpty {
                parts.append(permissionPart("denied file access", targets: deniedTargets))
            }
        }
        guard !parts.isEmpty else { return "Codex requested additional permissions." }
        return "Requested: \(parts.joined(separator: ", "))."
    }

    private static func permissionSummaryIfPresent(from permissions: JSONValue?) -> String? {
        guard case let .object(values)? = permissions, !values.isEmpty else { return nil }
        return permissionSummary(from: permissions)
    }

    private static func permissionPart(_ label: String, targets: [String]) -> String {
        let uniqueTargets = Array(Set(targets)).sorted()
        guard !uniqueTargets.isEmpty else { return label }
        return "\(label) (\(uniqueTargets.joined(separator: ", ")))"
    }

    private static func permissionTargets(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        if let values = value.arrayValue {
            return values.flatMap { permissionTargets(from: $0) }
        }
        if let direct = value.stringValue { return [direct] }
        guard let object = value.objectValue else { return [] }

        switch object["type"]?.stringValue {
        case "path":
            return object["path"]?.stringValue.map { ["path \($0)"] } ?? []
        case "glob_pattern":
            return object["pattern"]?.stringValue.map { ["glob \($0)"] } ?? []
        case "special":
            guard let special = object["value"] else { return [] }
            let kind = special["kind"]?.stringValue ?? "special"
            var components = ["special \(kind)"]
            if let path = special["path"]?.stringValue {
                components.append("path \(path)")
            }
            if let subpath = special["subpath"]?.stringValue {
                components.append("subpath \(subpath)")
            }
            return [components.joined(separator: "; ")]
        default:
            return object["path"]?.stringValue.map { [$0] } ?? []
        }
    }

    private static func allowedApprovalDecisions(from params: JSONValue) -> Set<ApprovalDecision> {
        guard let available = params["availableDecisions"], available != .null else {
            return Set(ApprovalDecision.allCases)
        }
        return Set(
            (available.arrayValue ?? []).compactMap { value in
                value.stringValue.flatMap(ApprovalDecision.init(rawValue:))
            }
        )
    }

    private static func messageText(from value: JSONValue) -> String {
        if let text = value["text"]?.stringValue.flatMap(safeTextCandidate) { return text }
        let content = value["content"]?.arrayValue ?? []
        return content.compactMap { part -> String? in
            let type = part["type"]?.stringValue?.lowercased()
            guard type == nil || type == "text" || type == "inputtext" else { return nil }
            return (part["text"]?.stringValue ?? part["content"]?.stringValue)
                .flatMap(safeTextCandidate)
        }.joined(separator: "\n")
    }

    private static func reasoningText(from value: JSONValue) -> String {
        let summary = value["summary"]?.arrayValue?.compactMap { part in
            part["text"]?.stringValue ?? part.stringValue
        }.joined(separator: "\n")
        let content = value["content"]?.arrayValue?.compactMap { part in
            part["text"]?.stringValue ?? part.stringValue
        }.joined(separator: "\n")
        return firstString(summary, content, value["text"]?.stringValue)
    }

    private static func commandText(from value: JSONValue) -> String {
        if let command = value["command"]?.stringValue { return command }
        if let command = value["command"]?.arrayValue {
            return command.compactMap(\.stringValue).joined(separator: " ")
        }
        if let command = value["cmd"]?.stringValue { return command }
        if let command = value["cmd"]?.arrayValue {
            return command.compactMap(\.stringValue).joined(separator: " ")
        }
        return ""
    }

    private static func toolTitle(from value: JSONValue, fallback: String) -> String {
        let tool = firstString(
            value["tool"]?.stringValue,
            value["name"]?.stringValue,
            humanized(fallback)
        )
        guard let namespace = value["namespace"]?.stringValue ?? value["server"]?.stringValue,
              !namespace.isEmpty else { return tool }
        return "\(namespace) · \(tool)"
    }

    private static func toolBody(
        from value: JSONValue,
        attachmentCount: Int,
        linkCount: Int
    ) -> String {
        if let contentItems = value["contentItems"]?.arrayValue {
            let text = contentItems.compactMap { item in
                item["text"]?.stringValue.flatMap(cleanToolText)
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }

        if let content = value["result"]?["content"]?.arrayValue {
            let text = content.compactMap { item in
                let type = item["type"]?.stringValue?.lowercased()
                guard type == nil || type == "text" || type == "inputtext" else { return nil }
                return (item["text"]?.stringValue ?? item["content"]?.stringValue ?? item.stringValue)
                    .flatMap(cleanToolText)
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }

        if let error = value["error"]?["message"]?.stringValue.flatMap(safeTextCandidate) { return error }
        if let query = value["query"]?.stringValue.flatMap(safeTextCandidate) { return query }
        if let title = value["arguments"]?["title"]?.stringValue.flatMap(safeTextCandidate) { return title }
        if let command = value["arguments"]?["cmd"]?.stringValue.flatMap(safeTextCandidate) { return command }
        if attachmentCount > 0, linkCount > 0 {
            let imageWord = attachmentCount == 1 ? "image" : "images"
            let linkWord = linkCount == 1 ? "link" : "links"
            return "Returned " + String(attachmentCount) + " " + imageWord + " and "
                + String(linkCount) + " " + linkWord + "."
        }
        if attachmentCount > 0 { return attachmentSummary(count: attachmentCount, verb: "Returned") }
        if linkCount > 0 { return resourceLinkSummary(count: linkCount) }
        if let result = value["result"], result != .null { return redactedDescription(of: result) }
        return value["arguments"].map(redactedDescription(of:)) ?? ""
    }

    private static func cleanToolText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8),
              let nested = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return safeTextCandidate(text)
        }

        if let content = nested["content"]?.arrayValue {
            let extracted = content.compactMap { item -> String? in
                let type = item["type"]?.stringValue?.lowercased()
                guard type == nil || type == "text" || type == "inputtext" else { return nil }
                return (item["text"]?.stringValue ?? item.stringValue).flatMap(safeTextCandidate)
            }.joined(separator: "\n")
            if !extracted.isEmpty { return extracted }
        }
        if let output = nested["output"]?.stringValue.flatMap(safeTextCandidate) { return output }
        return nestedContainsMedia(nested) || nestedContainsResourceLink(nested) ? nil : safeTextCandidate(text)
    }

    private static func messageImageAttachments(from value: JSONValue, itemID: String) -> [TimelineAttachment] {
        attachments(
            from: imageCandidates(in: value["content"]?.arrayValue ?? [], defaultLabel: "Attached image"),
            itemID: itemID
        )
    }

    private static func toolImageAttachments(from value: JSONValue, itemID: String) -> [TimelineAttachment] {
        var candidates = imageCandidates(
            in: value["contentItems"]?.arrayValue ?? [],
            defaultLabel: "Tool image"
        )
        candidates += imageCandidates(
            in: value["result"]?["content"]?.arrayValue ?? [],
            defaultLabel: "Tool image"
        )
        return attachments(from: candidates, itemID: itemID)
    }

    private struct ResourceLinkCandidate {
        let title: String?
        let url: URL
        let detail: String?
    }

    /// Projects explicit MCP/resource-link result content into bounded native
    /// links. We never infer links from arbitrary prose or tool arguments.
    private static func toolLinks(from value: JSONValue, itemID: String) -> [TimelineResourceLink] {
        var candidates: [ResourceLinkCandidate] = []
        if value["type"]?.stringValue?.lowercased() == "websearch" {
            collectResourceLink(
                from: value["action"] ?? .null,
                title: value["query"]?.stringValue,
                into: &candidates
            )
        } else if value["type"]?.stringValue?.lowercased() == "mcptoolcall" {
            let appContext = value["appContext"]
            collectResourceLink(
                from: .object([
                    "uri": appContext?["resourceUri"]
                        ?? value["mcpAppResourceUri"]
                        ?? .null,
                    "description": appContext?["appName"] ?? value["server"] ?? .null,
                ]),
                title: firstString(
                    appContext?["appName"]?.stringValue,
                    appContext?["actionName"]?.stringValue,
                    value["tool"]?.stringValue
                ),
                into: &candidates
            )
        }
        collectResourceLinks(in: value["contentItems"], into: &candidates)
        collectResourceLinks(in: value["result"]?["content"], into: &candidates)
        collectResourceLinks(in: value["result"]?["structuredContent"], into: &candidates)
        collectResourceLinks(in: value["action"], into: &candidates)

        var seenURLs: Set<URL> = []
        var links: [TimelineResourceLink] = []
        links.reserveCapacity(min(6, candidates.count))
        for candidate in candidates {
            guard links.count < 6 else { break }
            guard seenURLs.insert(candidate.url).inserted else { continue }
            let title = boundedLinkText(
                candidate.title,
                maximumCharacters: 180
            ) ?? candidate.url.host ?? candidate.url.absoluteString
            let detail = boundedLinkText(
                candidate.detail ?? candidate.url.host,
                maximumCharacters: 240
            )
            links.append(TimelineResourceLink(
                id: itemID + ":link:" + String(seenURLs.count - 1),
                title: title,
                url: candidate.url,
                detail: detail
            ))
        }
        return links
    }

    private static func collectResourceLinks(
        in value: JSONValue?,
        into candidates: inout [ResourceLinkCandidate],
        depth: Int = 0
    ) {
        guard let value, depth < 6 else { return }
        switch value {
        case let .array(values):
            for value in values {
                collectResourceLinks(in: value, into: &candidates, depth: depth + 1)
            }
        case let .object(object):
            let type = object["type"]?.stringValue?.lowercased()
            if type == "resource_link" || type == "resourcelink" || type == "link" {
                collectResourceLink(
                    from: value,
                    title: firstString(
                        object["title"]?.stringValue,
                        object["name"]?.stringValue,
                        object["label"]?.stringValue
                    ),
                    into: &candidates
                )
            } else if type == "resource" {
                let resource = object["resource"] ?? value
                collectResourceLink(
                    from: resource,
                    title: firstString(
                        object["title"]?.stringValue,
                        object["name"]?.stringValue,
                        resource["title"]?.stringValue
                    ),
                    into: &candidates
                )
            } else if type == "openpage" || type == "findinpage" {
                collectResourceLink(from: value, title: object["pattern"]?.stringValue, into: &candidates)
            }

            if (type == "text" || type == "inputtext"),
               let text = object["text"]?.stringValue,
               let nested = decodedJSON(from: text) {
                collectResourceLinks(in: nested, into: &candidates, depth: depth + 1)
            }

            // Only inspect result/content containers. Arguments and arbitrary
            // metadata can contain URLs that are not intended for navigation.
            for key in ["content", "contentItems", "links", "items", "resource", "action"] {
                collectResourceLinks(in: object[key], into: &candidates, depth: depth + 1)
            }
        case .string, .integer, .number, .bool, .null:
            break
        }
    }

    private static func collectResourceLink(
        from value: JSONValue,
        title: String?,
        into candidates: inout [ResourceLinkCandidate]
    ) {
        let object = value.objectValue ?? [:]
        let rawURL = firstString(
            object["uri"]?.stringValue,
            object["url"]?.stringValue,
            object["href"]?.stringValue
        )
        guard let url = validatedHTTPURL(rawURL) else { return }
        candidates.append(
            ResourceLinkCandidate(
                title: title,
                url: url,
                detail: firstString(
                    object["description"]?.stringValue,
                    object["mimeType"]?.stringValue,
                    object["mime_type"]?.stringValue,
                    url.host
                )
            )
        )
    }

    private static func validatedHTTPURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 8_192,
              !trimmed.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F
              }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    private static func boundedLinkText(_ text: String?, maximumCharacters: Int) -> String? {
        guard let text else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let normalized = text
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func imageViewAttachments(from value: JSONValue, itemID: String) -> [TimelineAttachment] {
        guard let path = value["path"]?.stringValue,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [
            TimelineAttachment(
                id: "\(itemID):image:0",
                source: .localFilePath(path),
                accessibilityLabel: "Viewed image"
            ),
        ]
    }

    private static func imageGenerationTimelineItem(
        from value: JSONValue,
        id: String,
        defaultStatus: TimelineItemStatus,
        timestamp: Date
    ) -> TimelineItem {
        let failure = value["failure"]
        let failed = failure != nil && failure != .null || defaultStatus == .failed
        var candidates: [ImageCandidate] = []
        if !failed, let savedPath = value["savedPath"]?.stringValue,
           !savedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(.init(source: .localFilePath(savedPath), label: "Generated image"))
        } else if !failed, let result = value["result"]?.stringValue,
                  let source = attachmentSource(from: result, allowLocalPath: true) {
            candidates.append(.init(source: source, label: "Generated image"))
        }
        let projectedAttachments = attachments(from: candidates, itemID: id)
        let status: TimelineItemStatus = failed ? .failed : defaultStatus
        let safeResult = value["result"]?.stringValue.flatMap { result -> String? in
            guard attachmentSource(from: result, allowLocalPath: true) == nil else { return nil }
            return safeTextCandidate(result)
        }
        let body: String
        if failed {
            body = imageGenerationFailureSummary(from: failure, fallback: safeResult)
        } else if status == .running || status == .pending {
            body = "Generating an image…"
        } else {
            body = firstString(safeResult, "Generated an image.")
        }
        return TimelineItem(
            id: id,
            kind: .tool,
            title: failed ? "Image generation failed" : "Generated image",
            body: body,
            status: status,
            timestamp: timestamp,
            detail: safePathDetail(value["savedPath"]?.stringValue),
            attachments: projectedAttachments
        )
    }

    private static func imageGenerationFailureSummary(from failure: JSONValue?, fallback: String?) -> String {
        guard let failure, failure != .null else {
            return firstString(fallback, "Image generation failed.")
        }
        if failure["type"]?.stringValue == "usageLimitExceeded" {
            if let reset = date(from: failure["resetsAt"]) {
                return "Image generation reached its usage limit. It resets \(reset.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Image generation reached its usage limit."
        }
        return firstString(
            failure["message"]?.stringValue.flatMap(safeTextCandidate),
            fallback,
            "Image generation failed."
        )
    }

    private struct ImageCandidate {
        let source: TimelineAttachmentSource
        let label: String
    }

    private static func imageCandidates(
        in content: [JSONValue],
        defaultLabel: String,
        depth: Int = 0
    ) -> [ImageCandidate] {
        guard depth < 3 else { return [] }
        var candidates: [ImageCandidate] = []
        for item in content {
            let type = item["type"]?.stringValue?.lowercased()
            let label = firstString(
                item["altText"]?.stringValue.flatMap(safeTextCandidate),
                item["alt"]?.stringValue.flatMap(safeTextCandidate),
                item["name"]?.stringValue.flatMap(safeTextCandidate),
                defaultLabel
            )

            if type == "localimage", let path = item["path"]?.stringValue,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append(.init(source: .localFilePath(path), label: label))
                continue
            }

            if type == "image" || type == "inputimage" || type == "image_url" {
                let rawURL = item["imageUrl"]?.stringValue
                    ?? item["image_url"]?.stringValue
                    ?? item["image_url"]?["url"]?.stringValue
                    ?? item["url"]?.stringValue
                if let rawURL, let source = attachmentSource(from: rawURL, allowLocalPath: false) {
                    candidates.append(.init(source: source, label: label))
                } else if let rawData = item["data"]?.stringValue,
                          let source = imageDataSource(
                            from: rawData,
                            mimeType: item["mimeType"]?.stringValue ?? item["mime_type"]?.stringValue
                          ) {
                    candidates.append(.init(source: source, label: label))
                }
            }

            if (type == "text" || type == "inputtext"),
               let text = item["text"]?.stringValue,
               let nested = decodedJSON(from: text) {
                let nestedContent = nested["content"]?.arrayValue ?? nested["contentItems"]?.arrayValue ?? []
                candidates += imageCandidates(in: nestedContent, defaultLabel: defaultLabel, depth: depth + 1)
            }
        }
        return candidates
    }

    private static func attachments(from candidates: [ImageCandidate], itemID: String) -> [TimelineAttachment] {
        var seen: Set<TimelineAttachmentSource> = []
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.source).inserted else { return nil }
            let index = seen.count - 1
            return TimelineAttachment(
                id: "\(itemID):image:\(index)",
                source: candidate.source,
                accessibilityLabel: firstString(candidate.label, "Image attachment"),
                // A new projection receives a new lightweight cache revision.
                // If a streaming item reuses its provider ID with changed
                // bytes/URL, it cannot retrieve the previous thumbnail.
                cacheIdentity: "\(itemID):\(index):\(UUID().uuidString)"
            )
        }
    }

    private static func attachmentSource(from raw: String, allowLocalPath: Bool) -> TimelineAttachmentSource? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.prefix(5).lowercased() == "data:" {
            guard trimmed.utf8.count <= maximumProjectedDataURLCharacters,
                  let comma = trimmed.firstIndex(of: ","),
                  trimmed.distance(from: trimmed.startIndex, to: comma) <= 256 else { return nil }
            let metadata = trimmed[..<comma].lowercased()
            guard metadata.hasPrefix("data:image/") else { return nil }
            return .dataURL(trimmed)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https": return .remoteURL(url)
            case "file" where allowLocalPath: return .localFilePath(url.path)
            default: return nil
            }
        }
        if allowLocalPath, trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            return .localFilePath(trimmed)
        }
        return nil
    }

    private static func imageDataSource(from raw: String, mimeType: String?) -> TimelineAttachmentSource? {
        if let source = attachmentSource(from: raw, allowLocalPath: false) { return source }
        let mime = mimeType?.lowercased() ?? "image/png"
        guard mime.hasPrefix("image/"),
              !raw.isEmpty,
              raw.utf8.count <= maximumProjectedDataURLCharacters else { return nil }
        return .dataURL("data:\(mime);base64,\(raw)")
    }

    private static func safeTextCandidate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.prefix(11).lowercased() != "data:image/",
              !looksLikeEncodedMedia(trimmed) else { return nil }
        return raw
    }

    private static func looksLikeEncodedMedia(_ text: String) -> Bool {
        guard text.count > 512 else { return false }
        let sample = text.prefix(1_024)
        let base64Characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=\r\n"))
        return sample.unicodeScalars.allSatisfy(base64Characters.contains)
    }

    private static func decodedJSON(from text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func nestedContainsMedia(_ value: JSONValue) -> Bool {
        switch value {
        case let .string(text):
            return attachmentSource(from: text, allowLocalPath: false) != nil || looksLikeEncodedMedia(text)
        case let .array(values):
            return values.contains(where: nestedContainsMedia)
        case let .object(object):
            if let type = object["type"]?.stringValue?.lowercased(),
               type == "image" || type == "inputimage" || type == "image_url" || type == "audio" {
                return true
            }
            return object.values.contains(where: nestedContainsMedia)
        case .integer, .number, .bool, .null:
            return false
        }
    }

    private static func nestedContainsResourceLink(_ value: JSONValue) -> Bool {
        switch value {
        case let .array(values):
            return values.contains(where: nestedContainsResourceLink)
        case let .object(object):
            if let type = object["type"]?.stringValue?.lowercased(),
               type == "resource_link" || type == "resourcelink" || type == "resource" || type == "link" {
                return true
            }
            return object.values.contains(where: nestedContainsResourceLink)
        case .string, .integer, .number, .bool, .null:
            return false
        }
    }

    private static func redactedDescription(of value: JSONValue) -> String {
        redactedMedia(in: value).compactDescription
    }

    private static func redactedMedia(in value: JSONValue, fieldName: String? = nil) -> JSONValue {
        switch value {
        case let .string(text):
            let field = fieldName?.lowercased() ?? ""
            let isMediaField = ["data", "database64", "imageurl", "image_url", "audiourl", "audio_url"]
                .contains(field)
            if isMediaField || safeTextCandidate(text) == nil {
                return .string("[media omitted]")
            }
            return value
        case let .array(values):
            return .array(values.map { redactedMedia(in: $0) })
        case let .object(object):
            return .object(
                Dictionary(uniqueKeysWithValues: object.map { key, nested in
                    (key, redactedMedia(in: nested, fieldName: key))
                })
            )
        case .integer, .number, .bool, .null:
            return value
        }
    }

    private static func attachmentSummary(count: Int, verb: String) -> String {
        count == 1 ? "\(verb) an image." : "\(verb) \(count) images."
    }

    private static func resourceLinkSummary(count: Int) -> String {
        count == 1 ? "Returned a link." : "Returned \(count) links."
    }

    private static func safePathDetail(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Onyx-owned delegation is represented by Codex as a normal dynamic tool
    /// call. Project it as collaboration activity so the transcript stays quiet
    /// and the inspector can follow the child agent without learning about the
    /// app-server wire format. All other dynamic tools continue through the
    /// ordinary collapsed tool projection above.
    private static func onyxDelegationTimelineItem(
        from value: JSONValue,
        id: String,
        status: TimelineItemStatus,
        timestamp: Date
    ) -> TimelineItem {
        let arguments = onyxDelegationArguments(from: value["arguments"])
        let result = onyxDelegationResult(from: value)
        let providerConnectionID = firstNonemptyOptionalString(
            result?["provider_connection_id"]?.stringValue,
            arguments?["provider"]?.stringValue
        )
        let model = firstNonemptyOptionalString(
            result?["model"]?.stringValue,
            arguments?["model"]?.stringValue
        )
        let prompt = boundedText(arguments?["prompt"]?.stringValue, maximumCharacters: 560)
        let errorMessage = firstNonemptyOptionalString(
            boundedText(result?["error_message"]?.stringValue, maximumCharacters: 560),
            onyxDelegationPlainTextFailure(from: value)
        )
        let childConversationID = firstNonemptyOptionalString(
            result?["child_conversation_id"]?.stringValue
        )
        let destination: RuntimeCollaborationAgentDestination? = if let providerConnectionID,
                                                                    let childConversationID {
            RuntimeCollaborationAgentDestination(
                connectionID: ProviderConnectionID(providerConnectionID),
                threadID: childConversationID
            )
        } else {
            nil
        }
        let reportedSuccess = result?["success"]?.boolValue ?? value["success"]?.boolValue
        let projectedStatus: TimelineItemStatus = if reportedSuccess == false || status == .failed {
            .failed
        } else {
            status
        }

        let agentStatus: RuntimeCollaborationAgentStatus = switch projectedStatus {
        case .running, .pending: .working
        case .completed: reportedSuccess == false ? .failed : .completed
        case .failed: .failed
        case .declined: .interrupted
        }
        let displayModel = onyxDelegationModelDisplayName(model)
        let title: String = switch projectedStatus {
        case .running, .pending: "Delegating to \(displayModel)"
        case .completed: "\(displayModel) completed"
        case .failed: "Delegation failed"
        case .declined: "Delegation interrupted"
        }
        let body = if projectedStatus == .failed {
            firstString(errorMessage, "The delegated task could not be completed.")
        } else {
            firstString(prompt, "A configured provider handled part of this task.")
        }
        let agentMessage: String? = if projectedStatus == .failed {
            errorMessage
        } else if let prompt {
            boundedText(prompt, maximumCharacters: 280)
        } else {
            nil
        }
        let agent = RuntimeCollaborationAgent(
            id: id,
            path: model,
            status: agentStatus,
            message: agentMessage,
            updatedAt: timestamp,
            destination: destination
        )
        let detailParts = [providerConnectionID, model].compactMap { $0 }

        return TimelineItem(
            id: id,
            kind: .tool,
            title: title,
            body: body,
            status: projectedStatus,
            timestamp: timestamp,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
            collaboration: RuntimeCollaborationActivity(action: .spawn, agents: [agent])
        )
    }

    private static func onyxDelegationArguments(from value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if value.objectValue != nil { return value }
        guard let text = value.stringValue else { return nil }
        return decodedJSON(from: text)
    }

    private static func onyxDelegationResult(from value: JSONValue) -> JSONValue? {
        let contentItems = value["contentItems"]?.arrayValue ?? []
        for item in contentItems {
            guard let text = item["text"]?.stringValue,
                  text.count <= 128 * 1_024,
                  let decoded = decodedJSON(from: text),
                  decoded["type"]?.stringValue == "onyx_delegation_result",
                  decoded["version"]?.intValue == 1 else { continue }
            return decoded
        }

        guard let direct = value["result"],
              direct["type"]?.stringValue == "onyx_delegation_result",
              direct["version"]?.intValue == 1 else { return nil }
        return direct
    }

    private static func onyxDelegationPlainTextFailure(from value: JSONValue) -> String? {
        guard value["success"]?.boolValue == false else { return nil }
        for item in value["contentItems"]?.arrayValue ?? [] {
            guard let text = item["text"]?.stringValue,
                  decodedJSON(from: text) == nil,
                  let safeText = safeTextCandidate(text),
                  let bounded = boundedText(safeText, maximumCharacters: 560) else { continue }
            return bounded
        }
        return nil
    }

    private static func onyxDelegationModelDisplayName(_ model: String?) -> String {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return "another model" }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    private static func firstNonemptyOptionalString(_ candidates: String?...) -> String? {
        candidates.compactMap { candidate -> String? in
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty else { return nil }
            return candidate
        }.first
    }

    private static func collaborationToolTimelineItem(
        from value: JSONValue,
        id: String,
        status: TimelineItemStatus,
        timestamp: Date
    ) -> TimelineItem {
        let rawTool = value["tool"]?.stringValue ?? "wait"
        let action = collaborationAction(from: rawTool)
        let stateValues = value["agentsStates"]?.objectValue ?? [:]
        let receiverIDs = value["receiverThreadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let agentIDs = Set(receiverIDs).union(stateValues.keys).sorted()
        let agents = agentIDs.map { agentID in
            let state = stateValues[agentID]
            return RuntimeCollaborationAgent(
                id: agentID,
                path: nil,
                status: collaborationAgentStatus(
                    from: state?["status"]?.stringValue,
                    action: action,
                    callStatus: status
                ),
                message: boundedText(state?["message"]?.stringValue, maximumCharacters: 280),
                updatedAt: timestamp,
                destination: RuntimeCollaborationAgentDestination(
                    connectionID: .codexDefault,
                    threadID: agentID,
                    inheritsParentConnection: true
                )
            )
        }

        let count = max(agentIDs.count, receiverIDs.count)
        let title = collaborationTitle(action: action, status: status, count: count)
        var bodyParts: [String] = []
        if action == .spawn || action == .sendInput,
           let prompt = boundedText(value["prompt"]?.stringValue, maximumCharacters: 560) {
            bodyParts.append(prompt)
        }
        if let summary = collaborationAgentSummary(agents) {
            bodyParts.append(summary)
        }
        let messages = agents.compactMap { agent -> String? in
            guard let message = agent.message else { return nil }
            return agents.count == 1 ? message : "\(agent.displayName): \(message)"
        }
        bodyParts.append(contentsOf: messages.prefix(3))
        if messages.count > 3 {
            bodyParts.append("\(messages.count - 3) more agent update\(messages.count - 3 == 1 ? "" : "s")")
        }

        let model = value["model"]?.stringValue
        let countDetail = count == 0 ? nil : "\(count) agent\(count == 1 ? "" : "s")"
        return TimelineItem(
            id: id,
            kind: .tool,
            title: title,
            body: firstString(bodyParts.joined(separator: "\n"), defaultCollaborationBody(action: action)),
            status: status,
            timestamp: timestamp,
            detail: [countDetail, model].compactMap { $0 }.joined(separator: " · "),
            collaboration: RuntimeCollaborationActivity(action: action, agents: agents)
        )
    }

    private static func subAgentActivityTimelineItem(
        from value: JSONValue,
        id: String,
        status: TimelineItemStatus,
        timestamp: Date
    ) -> TimelineItem {
        let rawKind = value["kind"]?.stringValue ?? "interacted"
        let action: RuntimeCollaborationAction = switch rawKind {
        case "started": .started
        case "interrupted": .interrupted
        default: .interacted
        }
        let agentID = value["agentThreadId"]?.stringValue ?? ""
        let path = value["agentPath"]?.stringValue
        let agentStatus: RuntimeCollaborationAgentStatus = switch action {
        case .started, .interacted: .working
        case .interrupted: .interrupted
        default: .unknown
        }
        let agent = RuntimeCollaborationAgent(
            id: agentID,
            path: path,
            status: agentStatus,
            message: nil,
            updatedAt: timestamp,
            destination: RuntimeCollaborationAgentDestination(
                connectionID: .codexDefault,
                threadID: agentID,
                inheritsParentConnection: true
            )
        )
        let title: String = switch action {
        case .started: "Agent started"
        case .interacted: "Agent updated"
        case .interrupted: "Agent interrupted"
        default: "Agent activity"
        }
        return TimelineItem(
            id: id,
            kind: .tool,
            title: title,
            body: agent.displayName,
            status: status,
            timestamp: timestamp,
            detail: "Collaboration",
            collaboration: RuntimeCollaborationActivity(action: action, agents: [agent])
        )
    }

    private static func collaborationAction(from rawTool: String) -> RuntimeCollaborationAction {
        switch rawTool {
        case "spawnAgent": .spawn
        case "sendInput": .sendInput
        case "resumeAgent": .resume
        case "closeAgent": .close
        default: .wait
        }
    }

    private static func collaborationAgentStatus(
        from rawStatus: String?,
        action: RuntimeCollaborationAction,
        callStatus: TimelineItemStatus
    ) -> RuntimeCollaborationAgentStatus {
        switch rawStatus {
        case "pendingInit": return .starting
        case "running": return .working
        case "completed": return .completed
        case "interrupted": return .interrupted
        case "errored": return .failed
        case "shutdown": return .stopped
        case "notFound": return .unavailable
        default: break
        }

        guard callStatus != .failed else { return .unknown }
        return switch action {
        case .spawn: callStatus == .running ? .starting : .working
        case .sendInput, .resume: .working
        case .close: .stopped
        case .wait, .started, .interacted, .interrupted: .unknown
        }
    }

    private static func collaborationTitle(
        action: RuntimeCollaborationAction,
        status: TimelineItemStatus,
        count: Int
    ) -> String {
        let plural = count == 1 ? "agent" : "agents"
        switch (action, status) {
        case (.spawn, .failed): return "Could not start \(plural)"
        case (.spawn, .running), (.spawn, .pending): return "Starting \(plural)"
        case (.spawn, _): return "Started \(plural)"
        case (.sendInput, .failed): return "Could not send agent guidance"
        case (.sendInput, .running), (.sendInput, .pending): return "Sending agent guidance"
        case (.sendInput, _): return "Sent agent guidance"
        case (.resume, .failed): return "Could not resume \(plural)"
        case (.resume, .running), (.resume, .pending): return "Resuming \(plural)"
        case (.resume, _): return "Resumed \(plural)"
        case (.wait, .failed): return "Could not check agent progress"
        case (.wait, .running), (.wait, .pending): return "Waiting for \(plural)"
        case (.wait, _): return "Checked agent progress"
        case (.close, .failed): return "Could not close \(plural)"
        case (.close, .running), (.close, .pending): return "Closing \(plural)"
        case (.close, _): return "Closed \(plural)"
        case (.started, _), (.interacted, _), (.interrupted, _): return "Agent activity"
        }
    }

    private static func defaultCollaborationBody(action: RuntimeCollaborationAction) -> String {
        switch action {
        case .spawn: "Delegated part of the task to another agent."
        case .sendInput: "Sent follow-up guidance to an agent."
        case .resume: "Resumed an agent."
        case .wait: "Checked the latest agent progress."
        case .close: "Closed an agent."
        case .started, .interacted, .interrupted: "Agent activity updated."
        }
    }

    private static func collaborationAgentSummary(_ agents: [RuntimeCollaborationAgent]) -> String? {
        guard !agents.isEmpty else { return nil }
        let order: [RuntimeCollaborationAgentStatus] = [
            .starting, .working, .completed, .interrupted, .failed, .stopped, .unavailable, .unknown,
        ]
        let counts = Dictionary(grouping: agents, by: \.status).mapValues(\.count)
        return order.compactMap { status in
            guard let count = counts[status], count > 0 else { return nil }
            return "\(count) \(status.label.lowercased())"
        }
        .joined(separator: " · ")
    }

    private static func boundedText(_ text: String?, maximumCharacters: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }


    private static func status(from value: JSONValue?) -> RuntimeThreadStatus {
        let raw = value?.stringValue ?? value?["type"]?.stringValue ?? ""
        switch raw.lowercased() {
        case "idle", "completed", "notloaded": return .idle
        case "active":
            let activeFlags = value?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if activeFlags.contains("waitingOnApproval") { return .waitingForApproval }
            if activeFlags.contains("waitingOnUserInput") { return .waitingForInput }
            return .running
        case "running", "inprogress": return .running
        case "waitingforinput", "waiting_for_input": return .waitingForInput
        case "waitingforapproval", "waiting_for_approval": return .waitingForApproval
        case "failed", "error", "systemerror": return .failed
        default: return .unknown
        }
    }

    private static func itemStatus(
        from raw: String?,
        default defaultStatus: TimelineItemStatus
    ) -> TimelineItemStatus {
        switch raw?.lowercased() {
        case "inprogress", "running", "active": .running
        case "failed", "error": .failed
        case "declined", "cancelled", "canceled": .declined
        case "pending": .pending
        case "completed": .completed
        default: defaultStatus
        }
    }

    private static func date(from value: JSONValue?) -> Date? {
        if let number = value?.intValue {
            let seconds = number > 10_000_000_000 ? Double(number) / 1_000 : Double(number)
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value?.stringValue else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func firstString(_ candidates: String?...) -> String {
        candidates.compactMap { $0 }.first { value in
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? ""
    }

    private static func humanized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

private extension String {
    var firstNonemptyLine: String? {
        split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
