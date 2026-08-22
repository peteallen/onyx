import SwiftUI

struct ConversationWorkspaceView: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeaderView(model: model)
            Divider().overlay(OnyxTheme.border)

            ZStack {
                NativeTranscriptView(items: model.timeline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.isLoadingThread {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading task history…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .onyxPanel(radius: 12)
                } else if model.timeline.isEmpty {
                    EmptyTranscriptView(isArchive: model.isShowingArchivedThreads)
                }
            }

            VStack(spacing: 8) {
                if let interaction = model.activeUserInteraction {
                    UserInteractionView(model: model, interaction: interaction)
                        .id(interaction)
                }

                if model.session != nil,
                   (model.loginAttempt != nil
                    || (model.authState.requiresAuthentication && !model.authState.isSignedIn)) {
                    AccountAccessStrip(model: model)
                }

                RuntimeStatusStrip(model: model)
                if model.isShowingArchivedThreads {
                    ArchivedThreadStrip(model: model)
                } else {
                    ComposerView(model: model)
                }
            }
            .frame(maxWidth: 808)
            .padding(.horizontal, 24)
            .padding(.bottom, 17)
        }
        .background(OnyxTheme.canvas)
    }
}

private struct ConversationHeaderView: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation

    var body: some View {
        HStack(spacing: 10) {
            if !model.isSidebarVisible {
                Button {
                    model.isSidebarVisible = true
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.borderless)
                .help("Show sidebar")
                .accessibilityLabel("Show task sidebar")
                .accessibilityHint("Reveals the task list")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedThread?.title ?? (model.isShowingArchivedThreads ? "Archived tasks" : "New task"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(model.projectName)
                    if let branch = model.selectedThread?.branch {
                        Text("/")
                        Text(branch)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if model.isShowingArchivedThreads {
                Label("Archived", systemImage: "archivebox")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Task status")
                    .accessibilityValue("Archived")
            } else if model.isSelectedReviewStarting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Starting review")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OnyxTheme.electric)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(OnyxTheme.electric.opacity(0.08))
                .clipShape(Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Task status")
                .accessibilityValue("Starting review")
            } else if model.isTurnRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.isReviewRunning ? "Reviewing" : "Working")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OnyxTheme.electric)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(OnyxTheme.electric.opacity(0.08))
                .clipShape(Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Task status")
                .accessibilityValue(model.isReviewRunning ? "Reviewing" : "Working")
            }

            if !model.isShowingArchivedThreads,
               let id = model.selectedThreadID,
               id != "onyx:welcome" {
                Button {
                    model.togglePin(id)
                } label: {
                    Image(systemName: model.selectedThread?.isPinned == true ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(pinActionLabel)
                .accessibilityLabel(pinActionLabel)
                .accessibilityHint("Updates this task's pinned state")
            }

            Button {
                model.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(model.isInspectorVisible ? OnyxTheme.iris : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Toggle context panel (⌘⌥B)")
            .accessibilityLabel(model.isInspectorVisible ? "Hide context panel" : "Show context panel")
            .accessibilityHint("Keyboard shortcut Command-Option-B")

            Menu {
                if let id = model.selectedThreadID, id != "onyx:welcome" {
                    if model.isShowingArchivedThreads {
                        Button("Restore Task") { model.restore(id) }
                        if model.supports(.threadDeletion) {
                            Divider()
                            Button("Delete Permanently…", role: .destructive) {
                                model.beginDelete(id, window: windowPresentation.window)
                            }
                        }
                    } else {
                        Button("Rename…") { model.beginRename(id, window: windowPresentation.window) }
                        Button(model.selectedThread?.isPinned == true ? "Unpin" : "Pin") { model.togglePin(id) }
                        if model.supports(.threadForking) {
                            Button("Fork Task") { model.fork(id) }
                                .disabled(model.selectedThread.map(model.canForkThread) != true)
                        }
                        Divider()
                        if model.supports(.threadCompaction) {
                            Button("Compact Context") { model.compact(id) }
                                .disabled(model.selectedThread.map(model.canCompactThread) != true)
                        }
                        Button("Archive") { model.archive(id) }
                            .disabled(model.selectedThread.map(model.canArchiveThread) != true)
                        if model.supports(.threadDeletion) {
                            Divider()
                            Button("Delete Permanently…", role: .destructive) {
                                model.beginDelete(id, window: windowPresentation.window)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Task actions")
            .accessibilityLabel("Task actions")
        }
        .padding(.horizontal, 14)
        .padding(.top, 3)
        .frame(height: 50)
        .background(.bar)
    }

    private var pinActionLabel: String {
        model.selectedThread?.isPinned == true ? "Unpin task" : "Pin task"
    }
}

private struct EmptyTranscriptView: View {
    let isArchive: Bool

    var body: some View {
        VStack(spacing: 11) {
            if isArchive {
                Image(systemName: "archivebox")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.tertiary)
            } else {
                OnyxMark(size: 38)
            }
            Text(isArchive ? "No archived tasks" : "Start with an outcome")
                .font(.system(size: 17, weight: .semibold))
            Text(isArchive
                ? "Tasks you archive will remain available here and can be restored at any time."
                : "Onyx will inspect the workspace, work through the task, and keep the live result here.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(.bottom, 60)
    }
}

private struct ArchivedThreadStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.11))
                Image(systemName: "archivebox")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedThread == nil ? "Archived tasks" : "This task is archived")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(model.selectedThread == nil
                    ? "Select a task to review its history."
                    : "Restore it to continue the conversation or run more work.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if let id = model.selectedThreadID {
                Button("Restore Task") { model.restore(id) }
                    .buttonStyle(.borderedProminent)
                    .tint(OnyxTheme.iris)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
        .background(OnyxTheme.raisedSurface.opacity(0.72))
        .onyxPanel(radius: 12)
    }
}

private struct RuntimeStatusStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        switch model.connectionState {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(model.session == nil ? "Connecting to Codex…" : "Reconnecting to Codex…")
            }
                .foregroundStyle(.secondary)
                .font(.system(size: 10.5))
        case let .failed(message):
            reconnectRow(
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                color: OnyxTheme.destructive
            )
        case .disconnected:
            reconnectRow(
                message: "Codex disconnected",
                systemImage: "bolt.slash",
                color: .secondary
            )
        case .connected:
            EmptyView()
        }
    }

    private func reconnectRow(message: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(color)
                .font(.system(size: 10.5))
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.canReconnect {
                Button("Reconnect", action: model.reconnect)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .semibold))
                    .accessibilityHint("Restarts Codex and refreshes the open task")
            }
        }
    }
}

private struct AccountAccessStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(OnyxTheme.iris.opacity(0.13))
                Image(systemName: model.loginAttempt == nil ? "person.crop.circle.badge.plus" : "person.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnyxTheme.iris)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                if let code = model.loginAttempt?.userCode {
                    Text(code)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let attempt = model.loginAttempt {
                if attempt.userCode != nil {
                    Button("Copy Code", action: model.copyDeviceCode)
                        .buttonStyle(.borderless)
                }
                Button("Open Sign In", action: model.reopenLoginPage)
                    .buttonStyle(.borderedProminent)
                    .tint(OnyxTheme.iris)
                    .controlSize(.small)
                Button("Cancel", action: model.cancelLogin)
                    .buttonStyle(.borderless)
                    .disabled(model.isAuthenticating)
            } else if model.isAuthenticating {
                ProgressView().controlSize(.small)
            } else {
                if let deviceMethod = model.deviceCodeLoginMethod {
                    Menu {
                        Button(deviceMethod.displayName) { model.startLogin(deviceMethod) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More sign-in options")
                }
                if let method = model.primaryLoginMethod {
                    Button(method.displayName) { model.startLogin(method) }
                        .buttonStyle(.borderedProminent)
                        .tint(OnyxTheme.iris)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(OnyxTheme.iris.opacity(0.045))
        .onyxPanel(radius: 12)
    }

    private var title: String {
        guard let attempt = model.loginAttempt else { return "Sign in to run Codex" }
        return attempt.method.ceremony == .deviceCode ? "Enter this one-time code" : "Finish signing in in your browser"
    }

    private var detail: String {
        model.loginAttempt?.method.detail
            ?? "Your credentials stay with Codex and are never copied into Onyx."
    }
}

private struct ComposerView: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation
    @State private var textHeight: CGFloat = 46

    private var interactionBlocksComposer: Bool {
        model.activeUserInteraction?.isBlocking == true
    }

    private var canSend: Bool {
        model.canRunAgent
            && !interactionBlocksComposer
            && !model.isReviewBlockingComposer
            && (!model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.composerImages.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.composerImages.isEmpty {
                ComposerImagePreviewRow(
                    images: model.composerImages,
                    onRemove: model.removeComposerImage
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            NativeComposerTextView(
                text: $model.composerText,
                measuredHeight: $textHeight,
                isEnabled: model.canRunAgent
                    && !interactionBlocksComposer
                    && !model.isReviewBlockingComposer,
                onSubmit: {
                    if canSend { model.sendComposer() }
                },
                onPasteImages: { images in
                    model.addPastedComposerImages(images)
                }
            )
            .frame(height: textHeight)
            .padding(.horizontal, 12)
            .padding(.top, 4)

            HStack(spacing: 10) {
                Button(action: { model.chooseComposerImages(window: windowPresentation.window) }) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAttachImages)
                .help(model.canAttachImages ? "Attach images" : "This runtime does not support image input")
                .accessibilityLabel("Attach images")
                .accessibilityHint("Choose one or more images to include with this message")

                Menu {
                    if let models = model.session?.availableModels, !models.isEmpty {
                        ForEach(models) { runtimeModel in
                            Button {
                                model.selectModel(runtimeModel.id)
                            } label: {
                                if runtimeModel.id == model.selectedModelID {
                                    Label(runtimeModel.displayName, systemImage: "checkmark")
                                } else {
                                    Text(runtimeModel.displayName)
                                }
                            }
                        }
                    } else {
                        Text("Models load after connection")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.selectedModelName)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if !model.availableReasoningEfforts.isEmpty {
                    Menu {
                        ForEach(model.availableReasoningEfforts, id: \.self) { effort in
                            Button {
                                model.selectReasoningEffort(effort)
                            } label: {
                                if effort == model.selectedReasoningEffort {
                                    Label(effort.capitalized, systemImage: "checkmark")
                                } else {
                                    Text(effort.capitalized)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                            Text(model.selectedReasoningEffortName)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Menu {
                    Button("Read only") { model.permissionLabel = "Read only" }
                    Button("Workspace") { model.permissionLabel = "Workspace" }
                    Button("Full access") { model.permissionLabel = "Full access" }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shield")
                        Text(model.permissionLabel)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if model.isSelectedReviewStarting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 29, height: 29)
                        .help("Starting code review")
                } else if model.isTurnRunning {
                    Button(action: model.interrupt) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Color.primary)
                            .foregroundStyle(OnyxTheme.canvas)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else {
                    Button(action: model.sendComposer) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 29, height: 29)
                            .background(canSend ? AnyShapeStyle(OnyxTheme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.16)))
                            .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.58))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (Return)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(.regularMaterial)
        .background(OnyxTheme.raisedSurface.opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 16, y: 6)
    }

}

private struct ComposerImagePreviewRow: View {
    let images: [ComposerImageDraft]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { draft in
                    ZStack(alignment: .topTrailing) {
                        ComposerDraftThumbnail(draft: draft)
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
                            }
                            .accessibilityLabel("Attached image: \(draft.displayName)")

                        Button {
                            onRemove(draft.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.72))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove \(draft.displayName)")
                        .accessibilityHint("Removes this image from the message")
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                }
            }
        }
        .frame(height: 78)
        .accessibilityLabel("Message attachments")
    }
}

private struct ComposerDraftThumbnail: View {
    let draft: ComposerImageDraft

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var thumbnail: NSImage? {
        switch draft.input {
        case let .localImagePath(path):
            return NSImage(contentsOfFile: path)
        case let .imageURL(raw):
            guard raw.lowercased().hasPrefix("data:"),
                  let comma = raw.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])) else {
                return nil
            }
            return NSImage(data: data)
        case .text:
            return nil
        }
    }
}
