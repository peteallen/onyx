import SwiftUI

/// Native macOS settings for app-owned OpenAI-compatible connections.
/// Codex/ChatGPT OAuth is intentionally presented by the sibling Codex
/// settings tab and never mixed with these API credentials.
struct ProviderSettingsView: View {
    @ObservedObject var model: ProviderSettingsModel
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDelete: ProviderConnectionRecord?
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            editor
        }
        .navigationSplitViewStyle(.balanced)
        .tint(OnyxTheme.iris)
        .task {
            await model.start()
        }
        .onChange(of: model.draft.baseURL) { _, _ in
            model.updateDraftDiscoveryScope()
        }
        .onChange(of: model.draft.authMode) { _, _ in
            model.updateDraftDiscoveryScope()
        }
        .onChange(of: model.draft.allowInsecureHTTP) { _, _ in
            model.updateDraftDiscoveryScope()
        }
        .onChange(of: model.draft.bearerToken) { _, _ in
            model.updateDraftBearerToken()
        }
        .onChange(of: model.draft.removeStoredCredential) { _, _ in
            model.updateDraftDiscoveryScope()
        }
        .alert(
            "Remove provider connection?",
            isPresented: $isShowingDeleteConfirmation,
            presenting: pendingDelete
        ) { connection in
            Button("Remove \(connection.displayName)", role: .destructive) {
                Task { await model.delete(connection.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { connection in
            Text("This removes \(connection.displayName) from Onyx and deletes its saved API credential from Keychain. Existing Codex sign-in is unaffected.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                Section("OpenAI-compatible") {
                    if model.connections.isEmpty {
                        Label("No connections", systemImage: "server.rack")
                            .font(.system(size: OnyxTypography.navigation))
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(model.connections) { connection in
                            ProviderConnectionRow(connection: connection)
                                .tag(connection.id)
                                .contextMenu {
                                    Button("Edit") {
                                        model.selectConnection(connection.id)
                                    }
                                    Button("Open Workspace") {
                                        openWorkspace(for: connection)
                                    }
                                    Button("Remove", role: .destructive) {
                                        pendingDelete = connection
                                        isShowingDeleteConfirmation = true
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Configured provider connections")

            Divider()
                .overlay(OnyxTheme.border)

            Button {
                model.beginAdd()
            } label: {
                Label("Add Connection", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(OnyxTheme.iris)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .accessibilityLabel("Add OpenAI-compatible connection")
            .accessibilityHint("Creates a new provider connection")
        }
        .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
    }

    private var selectionBinding: Binding<ProviderConnectionID?> {
        Binding(
            get: { model.selectedConnectionID },
            set: { value in
                guard let value else { return }
                model.selectConnection(value)
            }
        )
    }

    @ViewBuilder
    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                editorHeader

                if let errorMessage = model.errorMessage {
                    ProviderSettingsBanner(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: OnyxTheme.destructive
                    )
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                } else if let statusMessage = model.statusMessage {
                    ProviderSettingsBanner(
                        text: statusMessage,
                        systemImage: "checkmark.circle.fill",
                        tint: OnyxTheme.success
                    )
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                }

                Form {
                    Section {
                        TextField("Connection name", text: $model.draft.displayName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Connection name")
                            .accessibilityHint("A short name shown in the provider list")

                        TextField("Base URL", text: $model.draft.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.URL)
                            .accessibilityLabel("Provider base URL")
                            .accessibilityHint("For example, https://api.example.com/v1")

                        if !model.draft.trimmedBaseURL.isEmpty,
                           let message = model.draft.urlValidationMessage {
                            Label(message, systemImage: "xmark.octagon.fill")
                                .font(.system(size: OnyxTypography.navigation))
                                .foregroundStyle(OnyxTheme.destructive)
                                .accessibilityLabel("URL validation error: \(message)")
                        }
                    } header: {
                        Text("Connection")
                    } footer: {
                        Text("Use the provider's API root, usually ending in /v1. Onyx appends /models for discovery and /chat/completions for chat.")
                    }

                    securitySection
                    authenticationSection
                    modelSection
                    behaviorSection
                }
                .formStyle(.grouped)
                .padding(.horizontal, 20)
                .padding(.top, 6)

                editorActions
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(OnyxTheme.canvas)
    }

    private var editorHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: model.selectedConnectionID == nil ? "plus.circle" : "slider.horizontal.3")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(OnyxTheme.accentGradient)
                .frame(width: 42, height: 42)
                .background(
                    OnyxTheme.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedConnectionID == nil ? "Add provider connection" : "Provider connection")
                    .font(.system(size: OnyxTypography.paneTitle, weight: .semibold))
                Text(
                    model.selectedConnectionID == nil
                        ? "Connect Onyx to any OpenAI-compatible chat endpoint."
                        : model.draft.displayName.isEmpty
                            ? "Edit endpoint settings"
                            : model.draft.displayName
                )
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if model.selectedConnectionID != nil {
                if let connection = model.connections.first(where: { $0.id == model.draft.id }) {
                    Button {
                        openWorkspace(for: connection)
                    } label: {
                        Label("Open Workspace", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open workspace for \(connection.displayName)")
                }
                Button {
                    guard let connection = model.connections.first(where: { $0.id == model.draft.id }) else {
                        return
                    }
                    pendingDelete = connection
                    isShowingDeleteConfirmation = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(OnyxTheme.destructive)
                .accessibilityLabel("Remove provider connection")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 4)
    }

    private var securitySection: some View {
        Section {
            if model.draft.usesHTTP {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "This endpoint uses unencrypted HTTP",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: OnyxTypography.paneTitle, weight: .semibold))
                    .foregroundStyle(OnyxTheme.warning)

                    Text("Traffic, including prompts and responses, can be read or changed on the network. Clear-text HTTP is limited to literal loopback, private-network, or link-local IP addresses, and still requires your acknowledgement.")
                        .font(.system(size: OnyxTypography.navigation))
                        .foregroundStyle(.secondary)

                    if model.draft.hasAllowedInsecureHTTPHost {
                        Toggle(
                            "I understand the risk and allow clear-text HTTP",
                            isOn: $model.draft.allowInsecureHTTP
                        )
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Allow insecure HTTP")
                        .accessibilityHint("Required before Onyx can contact any HTTP endpoint, including a local IP")
                    } else {
                        Label(
                            "This HTTP host is not allowed. Use HTTPS or enter a literal loopback, private-network, or link-local IP address.",
                            systemImage: "nosign"
                        )
                        .font(.system(size: OnyxTypography.navigation, weight: .medium))
                        .foregroundStyle(OnyxTheme.destructive)
                    }

                    if model.draft.authMode == .bearer {
                        Label(
                            "Bearer authentication cannot be used over clear-text HTTP. Switch to HTTPS before saving.",
                            systemImage: "key.slash"
                        )
                        .font(.system(size: OnyxTypography.navigation, weight: .medium))
                        .foregroundStyle(OnyxTheme.destructive)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Label(
                    "HTTPS is required for non-local endpoints.",
                    systemImage: "lock.fill"
                )
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Transport security")
        } footer: {
            Text("Onyx never resolves hostnames to decide whether HTTP is safe. HTTPS is required for hostnames and public IP addresses; clear-text HTTP always needs an explicit acknowledgement.")
        }
    }

    private var authenticationSection: some View {
        Section {
            Picker("Authentication", selection: $model.draft.authMode) {
                Text("No authentication").tag(ProviderConnectionAuthMode.none)
                Text("API bearer token").tag(ProviderConnectionAuthMode.bearer)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Provider authentication")

            if model.draft.authMode == .bearer {
                SecureField(
                    model.draft.hasStoredCredential
                        ? "API bearer token (leave blank to keep saved key)"
                        : "API bearer token",
                    text: $model.draft.bearerToken
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("API bearer token")
                .accessibilityHint("Stored only in the macOS Keychain; never written to provider settings")

                if model.draft.hasStoredCredential {
                    HStack(spacing: 8) {
                        Image(systemName: model.draft.removeStoredCredential ? "key.slash" : "key.fill")
                            .foregroundStyle(
                                model.draft.removeStoredCredential
                                    ? OnyxTheme.warning
                                    : OnyxTheme.success
                            )
                        Text(
                            model.draft.removeStoredCredential
                                ? "The saved key will be removed when you save."
                                : "A bearer token is saved in Keychain."
                        )
                        .font(.system(size: OnyxTypography.navigation))
                        .foregroundStyle(.secondary)

                        Spacer()

                        Button(model.draft.removeStoredCredential ? "Keep Key" : "Remove Key") {
                            model.draft.removeStoredCredential.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text("No authentication is appropriate for a trusted local vLLM server. API keys are stored in Keychain and are never included in the provider-connections file.")
        }
    }

    private var modelSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField(
                    "Default model ID (optional)",
                    text: $model.draft.selectedModelID
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Default model ID")
                .accessibilityHint("The model sent with new chat requests")

                Button {
                    Task { await model.discoverModels() }
                } label: {
                    if model.isDiscovering {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18)
                    } else {
                        Label("Test & Discover", systemImage: "bolt.horizontal.circle")
                    }
                }
                .buttonStyle(.bordered)
                .tint(OnyxTheme.iris)
                .disabled(model.isDiscovering || model.draft.trimmedBaseURL.isEmpty)
                .accessibilityLabel("Test connection and discover models")
                .accessibilityHint("Calls the provider's models endpoint")
            }

            if !modelIDsForPicker.isEmpty {
                Picker("Discovered models", selection: $model.draft.selectedModelID) {
                    Text("No default model").tag("")
                    ForEach(modelIDsForPicker, id: \.self) { id in
                        HStack {
                            Text(modelDisplayName(for: id))
                            Spacer()
                            Text(modelCapabilitySummary(for: id))
                                .foregroundStyle(.secondary)
                        }
                        .tag(id)
                    }
                }
                .accessibilityLabel("Discovered models")
            }

            if let lastSucceededAt = model.draft.discovery.lastSucceededAt {
                Text(
                    "Last successful test \(lastSucceededAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.system(size: OnyxTypography.metadata))
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Onyx discovers models automatically when you save. Generic vLLM catalogs often omit capability metadata; those models remain text-safe and show capabilities as unknown until the provider advertises more. You can also enter a model ID manually or refresh with Test & Discover.")
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle(
                "Send enable_thinking=false",
                isOn: Binding(
                    get: { model.draft.enableThinking },
                    set: { model.draft.enableThinking = $0 }
                )
            )
            .toggleStyle(.checkbox)
            .accessibilityLabel("Disable Qwen thinking")
            .accessibilityHint("Adds chat_template_kwargs.enable_thinking=false for compatible Qwen and vLLM servers")
        } header: {
            Text("Request behavior")
        } footer: {
            Text("Useful for Qwen-compatible vLLM deployments when you want a direct answer without a hidden reasoning section.")
        }
    }

    private var modelIDsForPicker: [String] {
        var values = model.currentDraftDiscoveredModelIDs
        if let selected = model.draft.trimmedModelID, !values.contains(selected) {
            values.append(selected)
        }
        return values
    }

    private func modelDescriptor(for id: String) -> ProviderModelDescriptor? {
        model.currentDraftDiscoveredModels.first { $0.id == id }
    }

    private func modelDisplayName(for id: String) -> String {
        modelDescriptor(for: id)?.displayName ?? id
    }

    private func modelCapabilitySummary(for id: String) -> String {
        modelDescriptor(for: id)?.pickerCapabilitySummary ?? "Capabilities unknown"
    }

    private var editorActions: some View {
        HStack {
            Button("Save Connection") {
                Task { await model.saveDraft() }
            }
            .buttonStyle(.borderedProminent)
            .tint(OnyxTheme.iris)
            .foregroundStyle(OnyxTheme.canvas)
            .disabled(
                model.isSaving
                    || model.isDiscovering
                    || model.draft.trimmedDisplayName.isEmpty
                    || model.draft.trimmedBaseURL.isEmpty
            )
            .accessibilityLabel("Save provider connection")

            if model.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving provider connection")
            }

            Spacer()

            if model.selectedConnectionID != nil {
                Button("Revert Changes") {
                    if let connection = model.connections.first(where: { $0.id == model.draft.id }) {
                        model.selectConnection(connection.id)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Revert provider changes")
            }
        }
    }

    private func openWorkspace(for connection: ProviderConnectionRecord) {
        openWindow(value: WorkspaceWindowID(providerConnectionID: connection.id))
    }
}

private struct ProviderConnectionRow: View {
    let connection: ProviderConnectionRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: connection.authMode == .bearer ? "key.fill" : "server.rack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    connection.authMode == .bearer
                        ? OnyxTheme.iris
                        : OnyxTheme.electric
                )
                .frame(width: 24, height: 24)
                .background(
                    OnyxTheme.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .lineLimit(1)
                Text(
                    connection.selectedModelID
                        ?? connection.baseURL.host
                        ?? connection.baseURL.absoluteString
                )
                .font(.system(size: OnyxTypography.metadata))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(connection.displayName)
        .accessibilityValue(
            "\(connection.authMode == .bearer ? "API bearer authentication" : "No authentication"), \(connection.selectedModelID ?? "no default model")"
        )
        .accessibilityHint("Selects this provider connection for editing")
    }
}

private struct ProviderSettingsBanner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: OnyxTypography.navigation))
                .foregroundStyle(OnyxTheme.readingText)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            tint.opacity(0.11),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
