import SwiftUI

struct UserInteractionView: View {
    @ObservedObject var model: OnyxAppModel
    let interaction: RuntimeUserInteraction

    var body: some View {
        Group {
            switch interaction.kind {
            case let .approval(prompt):
                ApprovalInteractionView(model: model, interaction: interaction, prompt: prompt)
            case let .questions(prompt):
                QuestionInteractionView(model: model, interaction: interaction, prompt: prompt)
            case let .form(prompt):
                FormInteractionView(model: model, interaction: interaction, prompt: prompt)
            case let .externalLink(prompt):
                ExternalLinkInteractionView(model: model, interaction: interaction, prompt: prompt)
            case .unsupported:
                UnsupportedInteractionView(model: model, interaction: interaction)
            }
        }
        // Expired account access must not make a pending approval disappear:
        // it remains useful context beside the sign-in recovery strip. Keep
        // the whole request read-only until the provider freshly confirms it
        // after reauthentication, so an old Allow action can never be reused.
        .disabled(!model.canRespond(to: interaction))
    }
}

/// Keeps blocking prompts on the same readable axis as the conversation.
/// The surrounding composer stack may span a very wide window, but a question
/// and the controls that answer it should still read as one compact thought.
enum UserInteractionLayout {
    static let maximumWidth = OnyxWorkspaceMetrics.maximumConversationTextWidth
    static let cardPadding: CGFloat = 12
    static let headerIconSize: CGFloat = 30
    static let headerIconToTextSpacing: CGFloat = 10
    /// The leading edge of the header's title/detail column.  Command text
    /// uses this same axis instead of starting underneath the status icon.
    static let headerTextLeadingInset = headerIconSize + headerIconToTextSpacing
    static let commandTopGap: CGFloat = 8
    static let actionTopGap: CGFloat = 12
    static let actionSpacing: CGFloat = 8
    /// Below this usable card width the complete approval action set becomes
    /// a trailing vertical list. The controls may technically squeeze into a
    /// narrower row, but doing so makes the choices read like one run-on label.
    static let horizontalActionMinimumWidth: CGFloat = 360
    static let actionMinimumHeight = OnyxHitTarget.compact
}

private struct InteractionHeader: View {
    let interaction: RuntimeUserInteraction
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(
                width: UserInteractionLayout.headerIconSize,
                height: UserInteractionLayout.headerIconSize
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(interaction.title)
                    .font(.system(size: OnyxTypography.navigation, weight: .semibold))
                Text(interaction.detail)
                    .font(.system(size: OnyxTypography.secondary))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
    }
}

private struct ApprovalInteractionView: View {
    @ObservedObject var model: OnyxAppModel
    let interaction: RuntimeUserInteraction
    let prompt: RuntimeApprovalPrompt

    @FocusState private var focusedAction: ApprovalDecision?

    var body: some View {
        // Expand the interaction view to the available row width, then keep
        // the actual card on the same leading axis as transcript prose. This
        // protects the relationship even when a parent stack defaults to its
        // usual centered alignment (for example, in Side Chat).
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                InteractionHeader(
                    interaction: interaction,
                    icon: prompt.subject == .network ? "network.badge.shield.half.filled" : "checkmark.shield",
                    tint: OnyxTheme.warning
                )

                if let command = prompt.command, !command.isEmpty {
                    Text(command)
                        .font(.system(size: OnyxTypography.secondary, design: .monospaced))
                        .foregroundStyle(OnyxTheme.readingText)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, UserInteractionLayout.headerTextLeadingInset)
                        .padding(.trailing, 8)
                        .padding(.top, UserInteractionLayout.commandTopGap)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Command")
                        .accessibilityValue(command)
                }

                approvalActionsLayout
            }
            .padding(UserInteractionLayout.cardPadding)
            .frame(maxWidth: UserInteractionLayout.maximumWidth, alignment: .leading)
            .background(OnyxTheme.warning.opacity(0.055))
            .onyxPanel(radius: 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { moveFocus(to: initialFocusAction) }
    }

    /// Keep the primary action trailing on a normal card, but let the whole
    /// action group stack at compact widths instead of clipping labels.
    @ViewBuilder
    private var approvalActionsLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UserInteractionLayout.actionSpacing) {
                approvalActions
            }
            .frame(
                minWidth: UserInteractionLayout.horizontalActionMinimumWidth,
                alignment: .trailing
            )
            VStack(alignment: .trailing, spacing: UserInteractionLayout.actionSpacing) {
                approvalActions
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, UserInteractionLayout.actionTopGap)
    }

    @ViewBuilder
    private var approvalActions: some View {
        if model.isResponding(to: interaction) {
            ProgressView().controlSize(.small)
        } else {
            if prompt.allows(.cancel) {
                Button("Cancel") { model.respondToApproval(.cancel, for: interaction) }
                    .buttonStyle(.borderless)
                    .frame(minHeight: UserInteractionLayout.actionMinimumHeight)
                    .contentShape(Rectangle())
                    .keyboardShortcut(.cancelAction)
                    .focused($focusedAction, equals: .cancel)
            }

            if prompt.allows(.decline) {
                Button("Decline") { model.respondToApproval(.decline, for: interaction) }
                    .buttonStyle(.borderless)
                    .frame(minHeight: UserInteractionLayout.actionMinimumHeight)
                    .contentShape(Rectangle())
                    .promptKeyboardShortcut(.cancelAction, enabled: !prompt.allows(.cancel))
                    .focused($focusedAction, equals: .decline)
            }

            if prompt.allows(.accept), prompt.allows(.acceptForSession) {
                Menu {
                    Button("Allow once") { model.respondToApproval(.accept, for: interaction) }
                    Button("Allow for this session") {
                        model.respondToApproval(.acceptForSession, for: interaction)
                    }
                } label: {
                    Label("Allow", systemImage: "chevron.down")
                        .font(.system(size: OnyxTypography.secondary, weight: .semibold))
                        .foregroundStyle(OnyxTheme.canvas)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(minHeight: UserInteractionLayout.actionMinimumHeight)
                .background(OnyxTheme.warning)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .keyboardShortcut(.defaultAction)
                .focused($focusedAction, equals: .accept)
            } else if prompt.allows(.accept) {
                Button("Allow") { model.respondToApproval(.accept, for: interaction) }
                    .buttonStyle(.borderedProminent)
                    .tint(OnyxTheme.warning)
                    .foregroundStyle(OnyxTheme.canvas)
                    .controlSize(.small)
                    .frame(minHeight: UserInteractionLayout.actionMinimumHeight)
                    .keyboardShortcut(.defaultAction)
                    .focused($focusedAction, equals: .accept)
            } else if prompt.allows(.acceptForSession) {
                Button("Allow for this session") {
                    model.respondToApproval(.acceptForSession, for: interaction)
                }
                .buttonStyle(.borderedProminent)
                .tint(OnyxTheme.warning)
                .foregroundStyle(OnyxTheme.canvas)
                .controlSize(.small)
                .frame(minHeight: UserInteractionLayout.actionMinimumHeight)
                .keyboardShortcut(.defaultAction)
                .focused($focusedAction, equals: .acceptForSession)
            }
        }
    }

    private var initialFocusAction: ApprovalDecision {
        if prompt.allows(.accept) { return .accept }
        if prompt.allows(.acceptForSession) { return .acceptForSession }
        if prompt.allows(.decline) { return .decline }
        return .cancel
    }

    private func moveFocus(to action: ApprovalDecision) {
        Task { @MainActor in
            await Task.yield()
            focusedAction = action
        }
    }
}

private struct QuestionInteractionView: View {
    @ObservedObject var model: OnyxAppModel
    let interaction: RuntimeUserInteraction
    let prompt: RuntimeQuestionPrompt

    @State private var draft: RuntimeQuestionDraft
    @FocusState private var focusedControl: FocusTarget?

    private enum FocusTarget: Hashable {
        case option(questionID: String, label: String)
        case answer(questionID: String)
        case submit
    }

    init(model: OnyxAppModel, interaction: RuntimeUserInteraction, prompt: RuntimeQuestionPrompt) {
        self.model = model
        self.interaction = interaction
        self.prompt = prompt
        _draft = State(initialValue: model.questionDraft(for: interaction))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InteractionHeader(
                interaction: interaction,
                icon: "questionmark.bubble",
                tint: OnyxTheme.iris
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(prompt.questions) { question in
                        questionView(question)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .scrollIndicators(.visible)

            if prompt.questions.count > 1 {
                Label("Scroll to review all \(prompt.questions.count) questions", systemImage: "arrow.up.and.down")
                    .font(.system(size: OnyxTypography.metadata, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack {
                Button("Stop task", role: .cancel) { model.interruptInteraction(interaction) }
                    .buttonStyle(.borderless)
                    .promptKeyboardShortcut(.cancelAction, enabled: prompt.isBlocking)
                Spacer()
                if model.isResponding(to: interaction) {
                    ProgressView().controlSize(.small)
                }
                Button("Submit") { model.respond(to: interaction, with: .answers(answers)) }
                    .buttonStyle(.borderedProminent)
                    .tint(OnyxTheme.iris)
                    .foregroundStyle(OnyxTheme.canvas)
                    .disabled(!canSubmit)
                    .promptKeyboardShortcut(.defaultAction, enabled: prompt.isBlocking)
                    .focused($focusedControl, equals: .submit)
            }
        }
        .padding(12)
        .background(OnyxTheme.iris.opacity(0.045))
        .onyxPanel(radius: 12)
        .onAppear {
            guard prompt.isBlocking else { return }
            moveFocus(to: initialFocusTarget)
        }
        .onChange(of: draft) { _, value in
            model.updateQuestionDraft(value, for: interaction)
        }
        .onDisappear {
            model.updateQuestionDraft(draft, for: interaction)
        }
    }

    @ViewBuilder
    private func questionView(_ question: RuntimeQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.header.uppercased())
                .font(.system(size: OnyxTypography.metadata, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(question.prompt)
                .font(.system(size: OnyxTypography.navigation, weight: .medium))

            ForEach(question.options, id: \.self) { option in
                Button {
                    draft.selections[question.id] = option.label
                    draft.usesOther.remove(question.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: draft.selections[question.id] == option.label && !draft.usesOther.contains(question.id)
                            ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(OnyxTheme.iris)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label).font(.system(size: OnyxTypography.secondary, weight: .medium))
                            if !option.detail.isEmpty {
                                Text(option.detail).font(.system(size: OnyxTypography.secondary)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused(
                    $focusedControl,
                    equals: .option(questionID: question.id, label: option.label)
                )
            }

            if question.options.isEmpty || question.allowsOther {
                inputField(for: question)
                    .onTapGesture { draft.usesOther.insert(question.id) }
                    .onChange(of: draft.freeform[question.id] ?? "") { _, value in
                        if !value.isEmpty { draft.usesOther.insert(question.id) }
                    }
            }
        }
        .padding(10)
        .background(OnyxTheme.raisedSurface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func inputField(for question: RuntimeQuestion) -> some View {
        let binding = Binding(
            get: { draft.freeform[question.id] ?? "" },
            set: { draft.freeform[question.id] = $0 }
        )
        if question.isSecret {
            SecureField(question.options.isEmpty ? "Answer" : "Other", text: binding)
                .textFieldStyle(.roundedBorder)
                .focused($focusedControl, equals: .answer(questionID: question.id))
        } else {
            TextField(question.options.isEmpty ? "Answer" : "Other", text: binding)
                .textFieldStyle(.roundedBorder)
                .focused($focusedControl, equals: .answer(questionID: question.id))
        }
    }

    private var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: prompt.questions.map { question in
            if draft.usesOther.contains(question.id) || question.options.isEmpty {
                let value = UserInteractionInput.questionAnswer(
                    draft.freeform[question.id] ?? "",
                    isSecret: question.isSecret
                )
                return (question.id, value.map { [$0] } ?? [])
            }
            let value = draft.selections[question.id] ?? ""
            return (question.id, value.isEmpty ? [] : [value])
        })
    }

    private var canSubmit: Bool {
        answers.values.allSatisfy { !$0.isEmpty }
    }

    private var initialFocusTarget: FocusTarget {
        for question in prompt.questions {
            if let option = question.options.first {
                return .option(questionID: question.id, label: option.label)
            }
            if question.options.isEmpty || question.allowsOther {
                return .answer(questionID: question.id)
            }
        }
        return .submit
    }

    private func moveFocus(to target: FocusTarget) {
        Task { @MainActor in
            await Task.yield()
            focusedControl = target
        }
    }
}

private struct FormInteractionView: View {
    @ObservedObject var model: OnyxAppModel
    let interaction: RuntimeUserInteraction
    let prompt: RuntimeFormPrompt

    @State private var draft: RuntimeFormDraft
    @FocusState private var focusedControl: FocusTarget?

    private enum FocusTarget: Hashable {
        case field(String)
        case choice(fieldID: String, value: String)
        case submit
    }

    init(model: OnyxAppModel, interaction: RuntimeUserInteraction, prompt: RuntimeFormPrompt) {
        self.model = model
        self.interaction = interaction
        self.prompt = prompt

        _draft = State(initialValue: model.formDraft(for: interaction))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InteractionHeader(
                interaction: interaction,
                icon: "list.bullet.clipboard",
                tint: OnyxTheme.iris
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(prompt.fields) { field in
                        formField(field)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .scrollIndicators(.visible)

            HStack {
                Button("Decline") {
                    model.respond(to: interaction, with: .form(action: .decline, values: [:]))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isResponding(to: interaction) {
                    ProgressView().controlSize(.small)
                }
                Button("Submit") {
                    model.respond(to: interaction, with: .form(action: .accept, values: submittedValues))
                }
                .buttonStyle(.borderedProminent)
                .tint(OnyxTheme.iris)
                .foregroundStyle(OnyxTheme.canvas)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
                .focused($focusedControl, equals: .submit)
            }
        }
        .padding(12)
        .background(OnyxTheme.iris.opacity(0.045))
        .onyxPanel(radius: 12)
        .onAppear { moveFocus(to: initialFocusTarget) }
        .onChange(of: draft) { _, value in
            model.updateFormDraft(value, for: interaction)
        }
        .onDisappear {
            model.updateFormDraft(draft, for: interaction)
        }
    }

    @ViewBuilder
    private func formField(_ field: RuntimeFormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label + (field.isRequired ? " *" : ""))
                .font(.system(size: OnyxTypography.secondary, weight: .semibold))
            if let detail = field.detail, !detail.isEmpty {
                Text(detail).font(.system(size: OnyxTypography.metadata)).foregroundStyle(.secondary)
            }

            switch field.kind {
            case let .text(format):
                if UserInteractionInput.isSecretFormat(format) {
                    SecureField("", text: textBinding(field.id))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedControl, equals: .field(field.id))
                } else {
                    TextField(format == "email" ? "name@example.com" : "", text: textBinding(field.id))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedControl, equals: .field(field.id))
                }
            case let .number(integerOnly):
                TextField(integerOnly ? "0" : "0.0", text: textBinding(field.id))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedControl, equals: .field(field.id))
            case .toggle:
                Toggle("Enabled", isOn: boolBinding(field.id))
                    .toggleStyle(.switch)
                    .focused($focusedControl, equals: .field(field.id))
            case let .singleChoice(choices):
                Picker(field.label, selection: choiceBinding(field.id)) {
                    Text("Choose…").tag("")
                    ForEach(choices, id: \.self) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .focused($focusedControl, equals: .field(field.id))
            case let .multipleChoice(choices):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(choices, id: \.self) { choice in
                        Toggle(choice.label, isOn: multiBinding(field.id, value: choice.value))
                            .focused(
                                $focusedControl,
                                equals: .choice(fieldID: field.id, value: choice.value)
                            )
                    }
                }
            }
        }
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { draft.textValues[id] ?? "" }, set: { draft.textValues[id] = $0 })
    }

    private func boolBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { draft.boolValues[id] ?? false },
            set: {
                draft.boolValues[id] = $0
                draft.touchedBoolFields.insert(id)
            }
        )
    }

    private func choiceBinding(_ id: String) -> Binding<String> {
        Binding(get: { draft.choiceValues[id] ?? "" }, set: { draft.choiceValues[id] = $0 })
    }

    private func multiBinding(_ id: String, value: String) -> Binding<Bool> {
        Binding(
            get: { draft.multiValues[id, default: []].contains(value) },
            set: { selected in
                if selected { draft.multiValues[id, default: []].insert(value) }
                else { draft.multiValues[id, default: []].remove(value) }
            }
        )
    }

    private var submittedValues: [String: RuntimeFormValue] {
        var result: [String: RuntimeFormValue] = [:]
        for field in prompt.fields {
            switch field.kind {
            case let .text(format):
                if let value = UserInteractionInput.formText(draft.textValues[field.id] ?? "", format: format) {
                    result[field.id] = .string(value)
                }
            case let .number(integerOnly):
                if let value = UserInteractionInput.formNumber(
                    draft.textValues[field.id] ?? "",
                    integerOnly: integerOnly
                ) {
                    result[field.id] = value
                }
            case .toggle:
                if UserInteractionInput.shouldIncludeToggle(
                    isRequired: field.isRequired,
                    wasTouched: draft.touchedBoolFields.contains(field.id)
                ) {
                    result[field.id] = .boolean(draft.boolValues[field.id] ?? false)
                }
            case .singleChoice:
                if let value = draft.choiceValues[field.id], !value.isEmpty { result[field.id] = .string(value) }
            case .multipleChoice:
                let values = Array(draft.multiValues[field.id] ?? []).sorted()
                if !values.isEmpty { result[field.id] = .strings(values) }
            }
        }
        return result
    }

    private var canSubmit: Bool {
        prompt.fields.allSatisfy { field in
            guard field.isRequired else { return valueIsValid(field) }
            return submittedValues[field.id] != nil
        }
    }

    private func valueIsValid(_ field: RuntimeFormField) -> Bool {
        if case let .number(integerOnly) = field.kind {
            let value = (draft.textValues[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return true }
            return UserInteractionInput.formNumber(value, integerOnly: integerOnly) != nil
        }
        return true
    }

    private var initialFocusTarget: FocusTarget {
        guard let field = prompt.fields.first else { return .submit }
        if case let .multipleChoice(choices) = field.kind, let choice = choices.first {
            return .choice(fieldID: field.id, value: choice.value)
        }
        return .field(field.id)
    }

    private func moveFocus(to target: FocusTarget) {
        Task { @MainActor in
            await Task.yield()
            focusedControl = target
        }
    }
}

private struct ExternalLinkInteractionView: View {
    @ObservedObject var model: OnyxAppModel
    let interaction: RuntimeUserInteraction
    let prompt: RuntimeExternalLinkPrompt

    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case open
        case finish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InteractionHeader(
                interaction: interaction,
                icon: "link",
                tint: OnyxTheme.electric
            )
            HStack {
                Button("Cancel") {
                    model.respond(to: interaction, with: .externalLink(.cancel))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open \(prompt.sourceName ?? "link")") {
                    model.openInteractionLink(prompt.url)
                }
                .keyboardShortcut(.defaultAction)
                .focused($focusedAction, equals: .open)
                Button("I’m finished") {
                    model.respond(to: interaction, with: .externalLink(.accept))
                }
                .buttonStyle(.borderedProminent)
                .tint(OnyxTheme.electric)
                .foregroundStyle(OnyxTheme.canvas)
                .focused($focusedAction, equals: .finish)
            }
        }
        .padding(12)
        .background(OnyxTheme.electric.opacity(0.045))
        .onyxPanel(radius: 12)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedAction = .open
            }
        }
    }
}

private struct UnsupportedInteractionView: View {
    @ObservedObject var model: OnyxAppModel
    let interaction: RuntimeUserInteraction

    @FocusState private var isStopFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            InteractionHeader(
                interaction: interaction,
                icon: "exclamationmark.triangle",
                tint: OnyxTheme.destructive
            )
            Button("Stop task", role: .destructive) { model.interruptInteraction(interaction) }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .focused($isStopFocused)
        }
        .padding(12)
        .background(OnyxTheme.destructive.opacity(0.055))
        .onyxPanel(radius: 12)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                isStopFocused = true
            }
        }
    }
}

enum UserInteractionInput {
    static func questionAnswer(_ rawValue: String, isSecret: Bool) -> String? {
        nonempty(isSecret ? rawValue : rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func formText(_ rawValue: String, format: String?) -> String? {
        nonempty(isSecretFormat(format)
            ? rawValue
            : rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func formNumber(_ rawValue: String, integerOnly: Bool) -> RuntimeFormValue? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if integerOnly {
            return Int(value).map(RuntimeFormValue.integer)
        }
        guard let number = Double(value), number.isFinite else { return nil }
        return .number(number)
    }

    static func isSecretFormat(_ format: String?) -> Bool {
        guard let format else { return false }
        return format.caseInsensitiveCompare("password") == .orderedSame
            || format.caseInsensitiveCompare("secret") == .orderedSame
    }

    static func shouldIncludeToggle(isRequired: Bool, wasTouched: Bool) -> Bool {
        isRequired || wasTouched
    }

    private static func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

private extension View {
    @ViewBuilder
    func promptKeyboardShortcut(_ shortcut: KeyboardShortcut, enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
